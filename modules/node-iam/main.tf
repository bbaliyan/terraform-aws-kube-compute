# SPDX-License-Identifier: Apache-2.0

# Inline JSON: mock_provider cannot evaluate data.aws_iam_policy_document.
resource "aws_iam_role" "node" {
  name_prefix = var.name_prefix
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count      = var.attach_ebs_csi_policy ? 1 : 0
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role_policy" "agent_token" {
  count = var.agent_token == null ? 0 : 1
  name  = var.agent_token.policy_name
  role  = aws_iam_role.node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.agent_token.ssm_parameter}"
      },
      {
        Effect = "Allow"
        Action = "kms:Decrypt"
        # By condition, not resource: alias/aws/ssm has no ARN to name here.
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_instance_profile" "node" {
  name_prefix = var.name_prefix
  role        = aws_iam_role.node.name
  tags        = var.tags
}
