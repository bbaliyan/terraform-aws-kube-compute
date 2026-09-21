# SPDX-License-Identifier: Apache-2.0
# Read-only AWS lookups. No fabric-creating resource belongs in this file, ever.

data "aws_subnet" "selected" {
  id = var.subnet_id
}

data "aws_caller_identity" "current" {}

# AWS's own API reports supported_architectures for any instance type, so no
# per-family lookup table has to be maintained here.
data "aws_ec2_instance_type" "selected" {
  instance_type = var.instance_type
}

# The architecture filter is what lets one os_image_name with a wildcard
# architecture segment serve both an arm64 and an x86_64 node in the same
# cluster, without either build satisfying the other's node.
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

# Fallback when neither an ID nor a name is given. Owner 764336703387 is the
# AlmaLinux OS Foundation's own AWS account.
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
