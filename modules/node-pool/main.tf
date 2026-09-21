# SPDX-License-Identifier: Apache-2.0
locals {
  node_name     = "${var.group_name}-${var.cluster_name}"
  resource_name = "kube-compute-${var.cluster_name}-${var.group_name}"

  # An IAM name_prefix caps at 38 characters.
  iam_name_prefix = substr(format("kube-compute-%s-%s-", var.cluster_name, var.group_name), 0, 38)

  ami_arch = {
    for type, info in data.aws_ec2_instance_type.selected :
    type => contains(info.supported_architectures, "arm64") ? "arm64" : "x86_64"
  }

  effective_ami_id = {
    for type in keys(var.instance_type_max_sizes) : type => coalesce(
      var.os_image_ami_id,
      try(data.aws_ami.by_name[type].id, null),
      try(data.aws_ami.almalinux10[type].id, null),
    )
  }

  availability_zone = data.aws_subnet.selected.availability_zone

  connectivity_user_data = <<-EOT
    #!/bin/bash
    systemctl enable --now amazon-ssm-agent 2>/dev/null || true
  EOT

  mime_boundary = "MIMEBOUNDARY"

  combined_user_data = {
    for type, bootstrap in module.node_bootstrap : type => join("\n", [
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
      bootstrap.cloud_init_user_data,
      "--${local.mime_boundary}--",
      "",
    ])
  }

  agent_token_fetch_command = "aws ssm get-parameter --name '${var.agent_token_ssm_parameter}' --with-decryption --query Parameter.Value --output text --region ${var.aws_region}"

  node_labels = merge(
    {
      "topology.kubernetes.io/zone" = local.availability_zone
      "kube-compute.io/node-group"  = var.group_name
    },
    var.node_labels,
  )

  node_labels_by_type = {
    for type in keys(var.instance_type_max_sizes) :
    type => merge(local.node_labels, { "node.kubernetes.io/instance-type" = type })
  }

  common_tags = merge(var.extra_tags, {
    ClusterName = var.cluster_name
    NodeGroup   = var.group_name
    ManagedBy   = "kube-compute"
  })

  # cluster-autoscaler discovers a group by the first two, and reads the labels
  # and taints of a node it has not launched yet from the rest.
  cluster_autoscaler_tags = {
    for type, labels in local.node_labels_by_type : type => merge(
      {
        "k8s.io/cluster-autoscaler/enabled"             = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      },
      { for k, v in labels : "k8s.io/cluster-autoscaler/node-template/label/${k}" => v },
      { for t in var.node_taints : "k8s.io/cluster-autoscaler/node-template/taint/${split("=", t)[0]}" => split("=", t)[1] },
    )
  }
}

resource "aws_iam_role" "node" {
  name_prefix = local.iam_name_prefix
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
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role_policy" "agent_token" {
  name = "${local.resource_name}-agent-token-read"
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
        Effect   = "Allow"
        Action   = "kms:Decrypt"
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
  name_prefix = local.iam_name_prefix
  role        = aws_iam_role.node.name
  tags        = local.common_tags
}

# Every instance of a type boots the same render, so EC2 names the host rather than cloud-init.
module "node_bootstrap" {
  source   = "../node-bootstrap"
  for_each = var.instance_type_max_sizes

  cluster_name              = var.cluster_name
  node_name                 = local.node_name
  set_hostname              = false
  node_role                 = "worker"
  registration_address      = var.registration_address
  agent_token_fetch_command = local.agent_token_fetch_command
  node_labels               = local.node_labels
  node_taints               = var.node_taints
  trusted_ca_pem            = var.trusted_ca_pem
  trusted_ca_in_image       = var.trusted_ca_in_image
  registry_mirror_url       = var.registry_mirror_url
  dns_servers               = var.dns_servers
  aws_provider_id           = true
}

resource "aws_launch_template" "node" {
  for_each = var.instance_type_max_sizes

  name_prefix   = "${local.resource_name}-${replace(each.key, ".", "-")}-"
  image_id      = local.effective_ami_id[each.key]
  instance_type = each.key

  iam_instance_profile {
    name = aws_iam_instance_profile.node.name
  }

  vpc_security_group_ids = [var.cluster_security_group_id]

  # hop_limit 3: a pod's IMDSv2 response crosses Cilium's two pod-network hops.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 3
  }

  block_device_mappings {
    device_name = data.aws_ami.selected[each.key].root_device_name
    ebs {
      volume_type           = var.root_volume_type
      volume_size           = var.root_volume_size_gb
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64gzip(local.combined_user_data[each.key])

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.common_tags, { Name = "${local.node_name}-root" })
  }

  tags = local.common_tags
}

# cluster-autoscaler owns the desired capacity, so Terraform never sets it.
resource "aws_autoscaling_group" "node" {
  for_each = var.instance_type_max_sizes

  name                = "${local.resource_name}-${replace(each.key, ".", "-")}"
  min_size            = 0
  max_size            = each.value
  vpc_zone_identifier = [var.subnet_id]

  launch_template {
    id      = aws_launch_template.node[each.key].id
    version = aws_launch_template.node[each.key].latest_version
  }

  dynamic "tag" {
    for_each = merge(local.common_tags, { Name = local.node_name })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  dynamic "tag" {
    for_each = local.cluster_autoscaler_tags[each.key]
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false
    }
  }
}
