# SPDX-License-Identifier: Apache-2.0

data "aws_subnet" "selected" {
  id = var.subnet_id
}

data "aws_caller_identity" "current" {}

data "aws_ec2_instance_type" "selected" {
  for_each      = var.instance_type_max_sizes
  instance_type = each.key
}

data "aws_ami" "by_name" {
  for_each = var.os_image_ami_id == null && var.os_image_name != null ? var.instance_type_max_sizes : {}

  most_recent = true
  owners      = ["self"]
  filter {
    name   = "name"
    values = [var.os_image_name]
  }
  filter {
    name   = "architecture"
    values = [local.ami_arch[each.key]]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# The image's own root device name, which a launch template must map to resize the root disk.
data "aws_ami" "selected" {
  for_each = var.instance_type_max_sizes

  filter {
    name   = "image-id"
    values = [local.effective_ami_id[each.key]]
  }
}

# Owner 764336703387 is the AlmaLinux OS Foundation.
data "aws_ami" "almalinux10" {
  for_each = var.os_image_ami_id == null && var.os_image_name == null ? var.instance_type_max_sizes : {}

  most_recent = true
  owners      = ["764336703387"]
  filter {
    name   = "name"
    values = ["AlmaLinux OS 10*"]
  }
  filter {
    name   = "architecture"
    values = [local.ami_arch[each.key]]
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
