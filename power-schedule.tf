# SPDX-License-Identifier: Apache-2.0

locals {
  power_stop_clock    = try(split(":", var.power_schedule.stop_time), ["0", "0"])
  power_start_clock   = try(split(":", var.power_schedule.start_time), ["0", "0"])
  power_start_enabled = try(var.power_schedule.start_time, null) != null

  # power_schedule.days names the days the cluster runs. The stop fires on each of them. So does
  # the start, unless the hours cross midnight (start_time later than stop_time): then a day's
  # run begins the evening before, and the start fires on the day before each.
  power_week      = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
  power_day_index = { for i, day in local.power_week : day => i }
  power_run_days = try(var.power_schedule.days, null) == null ? range(7) : distinct(flatten([
    for part in split(",", var.power_schedule.days) : (
      length(split("-", part)) == 1 ? [local.power_day_index[part]] : (
        local.power_day_index[split("-", part)[0]] <= local.power_day_index[split("-", part)[1]]
        ? range(local.power_day_index[split("-", part)[0]], local.power_day_index[split("-", part)[1]] + 1)
        : concat(range(local.power_day_index[split("-", part)[0]], 7), range(0, local.power_day_index[split("-", part)[1]] + 1))
      )
    )
  ]))
  power_crosses_midnight = local.power_start_enabled && try(tonumber(replace(var.power_schedule.start_time, ":", "")) > tonumber(replace(var.power_schedule.stop_time, ":", "")), false)

  # Sorted, since sort() orders strings, and a single digit sorts the same either way.
  power_fire_days = {
    stop  = [for d in sort([for i in local.power_run_days : tostring(i)]) : tonumber(d)]
    start = [for d in sort([for i in local.power_run_days : tostring(local.power_crosses_midnight ? (i + 6) % 7 : i)]) : tonumber(d)]
  }

  # EventBridge Scheduler's cron takes a day of the month or a day of the week, with ? in the
  # other. Consecutive days are written as a range (MON-FRI), the form a person would write.
  power_day_fields = {
    for event, days in local.power_fire_days : event => length(days) == 7 ? "* * ? *" : format("? * %s *", join(",", [
      for first in days : (
        first == min([for d in days : d if d >= first && !contains(days, d + 1)]...)
        ? local.power_week[first]
        : "${local.power_week[first]}-${local.power_week[min([for d in days : d if d >= first && !contains(days, d + 1)]...)]}"
      ) if !contains(days, first - 1)
    ]))
  }

  power_stop_expression  = format("cron(%d %d %s)", tonumber(local.power_stop_clock[1]), tonumber(local.power_stop_clock[0]), local.power_day_fields["stop"])
  power_start_expression = format("cron(%d %d %s)", tonumber(local.power_start_clock[1]), tonumber(local.power_start_clock[0]), local.power_day_fields["start"])

  power_instance_arns = [for id in local.all_instance_ids : "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.kube_compute.account_id}:instance/${id}"]

  power_scale_to_zero_groups = var.power_schedule == null ? {} : merge({}, [
    for role, config in var.autoscaled_nodes : {
      for type in config.instance_types : "${role}-${replace(type, ".", "-")}" => { role = role, type = type }
    }
  ]...)
}

# The AWS-side names below predate the power_schedule name and are kept, so renaming the
# input neither replaces nor renames anything in AWS.

resource "aws_iam_role" "power_schedule" {
  count       = var.power_schedule == null ? 0 : 1
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

resource "aws_iam_role_policy" "power_schedule" {
  count = var.power_schedule == null ? 0 : 1
  name  = "stop-instances"
  role  = aws_iam_role.power_schedule[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Effect   = "Allow"
        Action   = "ec2:StopInstances"
        Resource = local.power_instance_arns
      }],
      local.autoscaling_enabled ? [{
        Effect   = "Allow"
        Action   = "autoscaling:SetDesiredCapacity"
        Resource = local.autoscaling_group_arns
      }] : [],
      local.power_start_enabled ? [{
        Effect   = "Allow"
        Action   = "ec2:StartInstances"
        Resource = local.power_instance_arns
      }] : [],
    )
  })
}

resource "aws_scheduler_schedule" "stop" {
  count = var.power_schedule == null ? 0 : 1
  name  = "${var.cluster_name}-node-stop"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = local.power_stop_expression
  schedule_expression_timezone = var.power_schedule.timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.power_schedule[0].arn

    input = jsonencode({
      InstanceIds = local.all_instance_ids
    })
  }
}

# Only the instances Terraform owns. The autoscaled groups stay at zero until pods need
# nodes, and the autoscaler scales them up once the platform node is back.
resource "aws_scheduler_schedule" "start" {
  count = local.power_start_enabled ? 1 : 0
  name  = "${var.cluster_name}-node-start"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = local.power_start_expression
  schedule_expression_timezone = var.power_schedule.timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.power_schedule[0].arn

    input = jsonencode({
      InstanceIds = local.all_instance_ids
    })
  }
}

resource "aws_scheduler_schedule_group" "scale_to_zero" {
  count = length(local.power_scale_to_zero_groups) > 0 ? 1 : 0
  name  = "${var.cluster_name}-to-zero"
  tags  = merge(var.extra_tags, { ClusterName = var.cluster_name, ManagedBy = "kube-compute" })
}

# Autoscaled nodes cannot be stopped, only removed. With the control plane stopping at
# the same moment, nothing is left running to scale them back up.
resource "aws_scheduler_schedule" "scale_to_zero" {
  for_each   = local.power_scale_to_zero_groups
  name       = each.key
  group_name = aws_scheduler_schedule_group.scale_to_zero[0].name

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = local.power_stop_expression
  schedule_expression_timezone = var.power_schedule.timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:autoscaling:setDesiredCapacity"
    role_arn = aws_iam_role.power_schedule[0].arn

    input = jsonencode({
      AutoScalingGroupName = module.autoscaled_nodes[each.value.role].autoscaling_groups[each.value.type].name
      DesiredCapacity      = 0
    })
  }
}

# From when the input was nightly_stop.

moved {
  from = aws_iam_role.nightly_stop
  to   = aws_iam_role.power_schedule
}

moved {
  from = aws_iam_role_policy.nightly_stop
  to   = aws_iam_role_policy.power_schedule
}

moved {
  from = aws_scheduler_schedule.nightly_stop
  to   = aws_scheduler_schedule.stop
}

moved {
  from = aws_scheduler_schedule.nightly_start
  to   = aws_scheduler_schedule.start
}

moved {
  from = aws_scheduler_schedule_group.nightly_scale_to_zero
  to   = aws_scheduler_schedule_group.scale_to_zero
}

moved {
  from = aws_scheduler_schedule.nightly_scale_to_zero
  to   = aws_scheduler_schedule.scale_to_zero
}
