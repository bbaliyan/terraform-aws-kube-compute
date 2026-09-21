# SPDX-License-Identifier: Apache-2.0
# Named worker instances rather than an autoscaling group. See README.md for why
# that is the right way round for a cluster that stops every evening.
locals {
  ami_arch = contains(data.aws_ec2_instance_type.selected.supported_architectures, "arm64") ? "arm64" : "x86_64"

  # An IAM name_prefix caps at 38 characters, and this one carries two variable
  # parts. Capping the whole string can cost the trailing hyphen, which is only
  # cosmetic -- AWS appends its own unique suffix regardless. substr is a no-op
  # below the limit, so no existing role's prefix changes.
  node_iam_name_prefix = substr(format("kube-compute-%s-%s-", var.cluster_name, var.group_name), 0, 38)

  effective_ami_id = coalesce(
    var.os_image_ami_id,
    try(one(data.aws_ami.by_name[*].id), null),
    try(one(data.aws_ami.almalinux10[*].id), null),
  )

  availability_zone = data.aws_subnet.selected.availability_zone

  # Keys start at 1, matching aws-control-plane's own cp-1/cp-2 naming.
  node_keys  = { for i in range(var.node_count) : tostring(i + 1) => i + 1 }
  node_names = { for k, _ in local.node_keys : k => "${var.group_name}-${var.cluster_name}-${k}" }

  # AlmaLinux community AMIs "likely" ship SSM Agent but not guaranteed running.
  connectivity_user_data = <<-EOT
    #!/bin/bash
    systemctl enable --now amazon-ssm-agent 2>/dev/null || true
  EOT

  # AWS accepts one user_data string per instance, so MIME multipart/mixed joins
  # the SSM-enable script to node-bootstrap's #cloud-config without re-merging
  # the YAML. Keyed per node: unlike an ASG, each has its own payload.
  mime_boundary = "MIMEBOUNDARY"

  combined_user_data = {
    for k, m in module.node_bootstrap : k => join("\n", [
      "Content-Type: multipart/mixed; boundary=\"${local.mime_boundary}\"",
      "MIME-Version: 1.0",
      "",
      "--${local.mime_boundary}",
      "Content-Type: text/x-shellscript; charset=\"us-ascii\"",
      "",
      local.connectivity_user_data,
      "--${local.mime_boundary}",
      "Content-Type: text/cloud-config; charset=\"us-ascii\"",
      "",
      m.cloud_init_user_data,
      "--${local.mime_boundary}--",
      "",
    ])
  }

  # Run on the node at join time, so the token is never in user_data.
  agent_token_fetch_command = "aws ssm get-parameter --name '${var.agent_token_ssm_parameter}' --with-decryption --query Parameter.Value --output text --region ${var.aws_region}"

  # node-group is derived from group_name so a nodeSelector needs no separately
  # passed label duplicating a name the caller already gave.
  node_labels = merge(
    {
      "topology.kubernetes.io/zone" = local.availability_zone
      "kube-compute.io/node-group"  = var.group_name
    },
    var.node_labels,
  )

  common_tags = merge(var.extra_tags, {
    ClusterName = var.cluster_name
    NodeGroup   = var.group_name
    ManagedBy   = "kube-compute"
  })
}

# One role per group, not per node: every node reads the same SSM parameter.
resource "aws_iam_role" "node" {
  name_prefix = local.node_iam_name_prefix
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
  tags = local.common_tags
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

# Inline JSON: mock_provider cannot evaluate data.aws_iam_policy_document.
resource "aws_iam_role_policy" "agent_token" {
  name = "kube-compute-${var.cluster_name}-${var.group_name}-agent-token-read"
  role = aws_iam_role.node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.agent_token_ssm_parameter}"
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
  name_prefix = local.node_iam_name_prefix
  role        = aws_iam_role.node.name
  tags        = local.common_tags
}

# One render per node, which is what lets set_hostname stay true here: an ASG's
# members share a single render and so cannot each carry a distinct hostname.
module "node_bootstrap" {
  source   = "../node-bootstrap"
  for_each = local.node_keys

  cluster_name              = var.cluster_name
  node_name                 = local.node_names[each.key]
  node_fqdn_label           = "${var.group_name}-${each.key}"
  cluster_fqdn_suffix       = var.cluster_fqdn_suffix
  node_role                 = "worker"
  registration_address      = var.registration_address
  agent_token_fetch_command = local.agent_token_fetch_command
  node_labels               = local.node_labels
  node_taints               = var.node_taints
  trusted_ca_pem            = var.trusted_ca_pem
  trusted_ca_in_image       = var.trusted_ca_in_image
  registry_mirror_url       = var.registry_mirror_url
  dns_servers               = var.dns_servers
  aws_provider_id           = var.aws_provider_id
}

# No depends_on: RKE2's agent retries its join indefinitely, so a worker booting
# alongside genesis simply waits.
resource "aws_instance" "node" {
  for_each = local.node_keys

  ami                    = local.effective_ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = aws_iam_instance_profile.node.name

  # hop_limit 3, not AWS's documented 2. Confirmed live that 2 is one hop short
  # of a pod's IMDSv2 token PUT getting its response back: IMDSv2 caps that
  # response's TTL to hop_limit, and Cilium's pod-netns routing costs 2 hops.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 3
  }

  root_block_device {
    volume_type           = var.root_volume_type
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
    tags                  = merge(local.common_tags, { Name = "${local.node_names[each.key]}-root" })
  }

  user_data_base64            = base64gzip(local.combined_user_data[each.key])
  user_data_replace_on_change = true

  tags = merge(local.common_tags, { Name = local.node_names[each.key] })

  lifecycle {
    # Don't replace on AMI patch drift; remove to deliberately upgrade.
    ignore_changes = [ami]
  }
}
