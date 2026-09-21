# SPDX-License-Identifier: Apache-2.0

locals {
  nightly_stop_clock    = try(split(":", var.nightly_stop.time), ["0", "0"])
  nightly_start_clock   = try(split(":", var.nightly_stop.start_time), ["0", "0"])
  nightly_start_enabled = try(var.nightly_stop.start_time, null) != null

  # EventBridge Scheduler's cron takes a day of the month or a day of the week, with ? in the other.
  nightly_days             = try(var.nightly_stop.days, null)
  nightly_start_days       = try(coalesce(var.nightly_stop.start_days, var.nightly_stop.days), null)
  nightly_day_fields       = local.nightly_days == null ? "* * ? *" : "? * ${local.nightly_days} *"
  nightly_start_day_fields = local.nightly_start_days == null ? "* * ? *" : "? * ${local.nightly_start_days} *"

  nightly_stop_expression  = format("cron(%d %d %s)", tonumber(local.nightly_stop_clock[1]), tonumber(local.nightly_stop_clock[0]), local.nightly_day_fields)
  nightly_start_expression = format("cron(%d %d %s)", tonumber(local.nightly_start_clock[1]), tonumber(local.nightly_start_clock[0]), local.nightly_start_day_fields)

  nightly_instance_arns = [for id in local.all_instance_ids : "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.kube_compute.account_id}:instance/${id}"]

  nightly_scale_to_zero_groups = var.nightly_stop == null ? {} : merge({}, [
    for role, config in var.autoscaled_nodes : {
      for type in config.instance_types : "${role}-${replace(type, ".", "-")}" => { role = role, type = type }
    }
  ]...)
}

resource "aws_iam_role" "nightly_stop" {
  count       = var.nightly_stop == null ? 0 : 1
  name_prefix = format("kube-compute-%s-stop-", substr(var.cluster_name, 0, 19))

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.extra_tags, { ClusterName = var.cluster_name, ManagedBy = "kube-compute" })
}

resource "aws_iam_role_policy" "nightly_stop" {
  count = var.nightly_stop == null ? 0 : 1
  name  = "stop-instances"
  role  = aws_iam_role.nightly_stop[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Effect   = "Allow"
        Action   = "ec2:StopInstances"
        Resource = local.nightly_instance_arns
      }],
      local.autoscaling_enabled ? [{
        Effect   = "Allow"
        Action   = "autoscaling:SetDesiredCapacity"
        Resource = local.autoscaling_group_arns
      }] : [],
      local.nightly_start_enabled ? [{
        Effect   = "Allow"
        Action   = "ec2:StartInstances"
        Resource = local.nightly_instance_arns
      }] : [],
    )
  })
}

resource "aws_scheduler_schedule" "nightly_stop" {
  count = var.nightly_stop == null ? 0 : 1
  name  = "${var.cluster_name}-node-stop"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = local.nightly_stop_expression
  schedule_expression_timezone = var.nightly_stop.timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.nightly_stop[0].arn

    input = jsonencode({
      InstanceIds = local.all_instance_ids
    })
  }
}

# Only the instances Terraform owns. The autoscaled groups stay at zero until pods need
# nodes, and the autoscaler scales them up once the platform node is back.
resource "aws_scheduler_schedule" "nightly_start" {
  count = local.nightly_start_enabled ? 1 : 0
  name  = "${var.cluster_name}-node-start"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = local.nightly_start_expression
  schedule_expression_timezone = var.nightly_stop.timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.nightly_stop[0].arn

    input = jsonencode({
      InstanceIds = local.all_instance_ids
    })
  }
}

resource "aws_scheduler_schedule_group" "nightly_scale_to_zero" {
  count = length(local.nightly_scale_to_zero_groups) > 0 ? 1 : 0
  name  = "${var.cluster_name}-to-zero"
  tags  = merge(var.extra_tags, { ClusterName = var.cluster_name, ManagedBy = "kube-compute" })
}

# Autoscaled nodes cannot be stopped, only removed. With the control plane stopping at
# the same moment, nothing is left running to scale them back up.
resource "aws_scheduler_schedule" "nightly_scale_to_zero" {
  for_each   = local.nightly_scale_to_zero_groups
  name       = each.key
  group_name = aws_scheduler_schedule_group.nightly_scale_to_zero[0].name

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = local.nightly_stop_expression
  schedule_expression_timezone = var.nightly_stop.timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:autoscaling:setDesiredCapacity"
    role_arn = aws_iam_role.nightly_stop[0].arn

    input = jsonencode({
      AutoScalingGroupName = module.autoscaled_nodes[each.value.role].autoscaling_groups[each.value.type].name
      DesiredCapacity      = 0
    })
  }
}
