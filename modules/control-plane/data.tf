# SPDX-License-Identifier: Apache-2.0
# Read-only AWS lookups. No resource blocks belong in this file, ever.
# The module NEVER creates network fabric — it only reads a subnet (given or default-VPC).

data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  count   = local.has_explicit_subnet ? 0 : 1
  default = true
}

data "aws_subnets" "default" {
  count = local.has_explicit_subnet ? 0 : 1
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }
}

data "aws_vpc" "named" {
  count = (length(local.subnet_name_candidates) > 0 && var.vpc_name != null) ? 1 : 0
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

# One lookup per candidate name, so available_ip_address_count can be compared across them.
# When vpc_name is also provided, a VPC filter narrows the search to avoid ambiguity.
data "aws_subnet" "by_name" {
  for_each = toset(local.subnet_name_candidates)

  filter {
    name   = "tag:Name"
    values = [each.value]
  }

  dynamic "filter" {
    for_each = local.named_vpc_id != null ? [local.named_vpc_id] : []
    iterator = vpc_id
    content {
      name   = "vpc-id"
      values = [vpc_id.value]
    }
  }
}

data "aws_route53_zone" "private" {
  count        = var.hosted_zone_name != null ? 1 : 0
  name         = var.hosted_zone_name
  private_zone = true
}

# The subnet the node launches into. Also yields the VPC ID for the module-owned security group.
data "aws_subnet" "selected" {
  id = local.effective_subnet_id

  lifecycle {
    precondition {
      condition     = length(local.subnet_name_candidates) == 0 || local.named_subnet_id != null
      error_message = "None of the candidate subnets has a free IP address: ${join(", ", local.subnet_name_candidates)}. Free addresses in one of them, or add another subnet to subnet_names."
    }

    precondition {
      condition     = local.effective_subnet_id != null
      error_message = "No subnet could be resolved. Pass subnet_id, subnet_name or subnet_names, or run in an account that still has a default VPC."
    }
  }
}

# Authoritative arch lookup: AWS's own API returns supported_architectures for any instance type,
# past or future. This replaces pattern-matching on the instance type string.
data "aws_ec2_instance_type" "selected" {
  instance_type = var.instance_type
}

# Self-owned AMI resolved by name (e.g. kube-image's own naming convention) — only when an
# explicit ID isn't given but a name/pattern is. Scoped to this account (owners = ["self"])
# and the derived architecture so an x86_64/arm64 pair sharing a version prefix can't collide.
data "aws_ami" "by_name" {
  count       = (var.os_image_ami_id == null && var.os_image_name != null) ? 1 : 0
  most_recent = true
  owners      = ["self"]
  filter {
    name   = "name"
    values = [var.os_image_name]
  }
  filter {
    name   = "architecture"
    values = [local.ami_arch]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# Latest AlmaLinux 10 for the derived arch — only when neither an explicit ID nor a name is given.
# Owner 764336703387 is the AlmaLinux OS Foundation's AWS account (verified against the
# AlmaLinux bug tracker and AlmaLinux/cloud-images repo); architecture isn't embedded in
# the name (unlike AL2023's), so it's filtered separately below.
data "aws_ami" "almalinux10" {
  count       = (var.os_image_ami_id == null && var.os_image_name == null) ? 1 : 0
  most_recent = true
  owners      = ["764336703387"]
  filter {
    name   = "name"
    values = ["AlmaLinux OS 10*"]
  }
  filter {
    name   = "architecture"
    values = [local.ami_arch]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# ---- HA mode: derive the module's VPC from the genesis node's own subnet, not the single-node
# fallback (which is otherwise unused once control_plane_count > 1) ----
data "aws_subnet" "control_plane_genesis" {
  count = var.control_plane_count > 1 ? 1 : 0
  id    = local.genesis_subnet_id
}
