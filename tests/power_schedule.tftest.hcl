# SPDX-License-Identifier: Apache-2.0

mock_provider "aws" {
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/kube-compute-bharat-stop" }
  }
  mock_data "aws_ec2_instance_type" {
    defaults = {
      supported_architectures = ["x86_64"]
      default_vcpus           = 2
      memory_size             = 8192
    }
  }
}

variables {
  cluster_name          = "bharat"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
  os_image_ami_id       = "ami-0123456789abcdef0"
}

run "off_by_default_stops_nothing" {
  command = plan

  variables {
    autoscaled_nodes = { workers = { instance_types = ["t3a.large"], max_cpu_cores = 8, max_memory_gib = 32 } }
  }

  assert {
    condition     = length(aws_scheduler_schedule.stop) == 0 && length(aws_scheduler_schedule.scale_to_zero) == 0
    error_message = "without power_schedule nothing may stop the nodes or scale the groups"
  }
}

run "a_cluster_without_autoscaling_only_stops_its_nodes" {
  command = apply

  variables {
    power_schedule = { stop_time = "20:00", timezone = "Australia/Sydney" }
  }

  assert {
    condition     = aws_scheduler_schedule.stop[0].schedule_expression == "cron(0 20 * * ? *)"
    error_message = "the stop must fire at power_schedule.stop_time"
  }
  assert {
    condition     = length(aws_scheduler_schedule.scale_to_zero) == 0 && length(jsondecode(aws_iam_role_policy.power_schedule[0].policy).Statement) == 1
    error_message = "a cluster without autoscaled nodes must only be allowed to stop its instances"
  }
  assert {
    condition     = length(aws_scheduler_schedule.start) == 0
    error_message = "without start_time nothing may start the cluster"
  }
}

run "an_autoscaled_cluster_scales_every_group_to_zero_as_it_stops" {
  command = apply

  variables {
    power_schedule   = { stop_time = "00:02", timezone = "Europe/London" }
    autoscaled_nodes = { workers = { instance_types = ["t3a.large", "t3a.xlarge"], max_cpu_cores = 8, max_memory_gib = 32 } }
  }

  assert {
    condition     = keys(aws_scheduler_schedule.scale_to_zero) == ["workers-t3a-large", "workers-t3a-xlarge"]
    error_message = "every instance type's group needs its own scale-to-zero schedule"
  }
  assert {
    condition = alltrue([
      for schedule in aws_scheduler_schedule.scale_to_zero :
      schedule.schedule_expression == aws_scheduler_schedule.stop[0].schedule_expression &&
      schedule.schedule_expression_timezone == "Europe/London" &&
      schedule.group_name == "bharat-to-zero"
    ])
    error_message = "a group must go to zero at the moment the nodes stop, when nothing is left to scale it back up"
  }
  assert {
    condition = jsondecode(aws_scheduler_schedule.scale_to_zero["workers-t3a-xlarge"].target[0].input) == {
      AutoScalingGroupName = module.autoscaled_nodes["workers"].autoscaling_groups["t3a.xlarge"].name
      DesiredCapacity      = 0
    }
    error_message = "the schedule must set its group's desired capacity to zero"
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.power_schedule[0].policy).Statement[1].Resource == local.autoscaling_group_arns
    error_message = "the schedule's role must be allowed to scale exactly this cluster's groups"
  }
}

run "a_working_week_starts_and_stops_on_its_days" {
  command = apply

  variables {
    power_schedule   = { days = "MON-FRI", start_time = "00:40", stop_time = "20:10", timezone = "Asia/Muscat" }
    autoscaled_nodes = { workers = { instance_types = ["t3a.large"], max_cpu_cores = 8, max_memory_gib = 32 } }
  }

  assert {
    condition     = aws_scheduler_schedule.stop[0].schedule_expression == "cron(10 20 ? * MON-FRI *)"
    error_message = "the stop must fire at stop_time on each day the cluster runs"
  }
  assert {
    condition     = aws_scheduler_schedule.scale_to_zero["workers-t3a-large"].schedule_expression == aws_scheduler_schedule.stop[0].schedule_expression
    error_message = "the groups must go to zero with the stop, on the same days"
  }
  assert {
    condition = (
      aws_scheduler_schedule.start[0].schedule_expression == "cron(40 0 ? * MON-FRI *)" &&
      aws_scheduler_schedule.start[0].schedule_expression_timezone == "Asia/Muscat"
    )
    error_message = "hours within one day must start on the days the cluster runs"
  }
  assert {
    condition = (
      aws_scheduler_schedule.start[0].target[0].arn == "arn:aws:scheduler:::aws-sdk:ec2:startInstances" &&
      jsondecode(aws_scheduler_schedule.start[0].target[0].input).InstanceIds == local.all_instance_ids
    )
    error_message = "the start must start every instance the stop stops"
  }
  assert {
    condition     = contains([for statement in jsondecode(aws_iam_role_policy.power_schedule[0].policy).Statement : statement.Action], "ec2:StartInstances")
    error_message = "the schedule's role must be allowed to start the instances"
  }
}

# The same working week in UTC: Sunday 20:40 to Monday 16:10, up to Thursday
# 20:40 to Friday 16:10, and off from Friday afternoon to Sunday evening.
run "hours_across_midnight_start_the_evening_before" {
  command = apply

  variables {
    power_schedule = { days = "MON-FRI", start_time = "20:40", stop_time = "16:10", timezone = "UTC" }
  }

  assert {
    condition = (
      aws_scheduler_schedule.stop[0].schedule_expression == "cron(10 16 ? * MON-FRI *)" &&
      aws_scheduler_schedule.start[0].schedule_expression == "cron(40 20 ? * SUN-THU *)"
    )
    error_message = "a start later than the stop must fire the evening before each day the cluster runs"
  }
}

run "separate_days_start_the_evening_before_each" {
  command = plan

  variables {
    power_schedule = { days = "MON,WED,FRI", start_time = "22:00", stop_time = "06:00", timezone = "UTC" }
  }

  assert {
    condition = (
      local.power_stop_expression == "cron(0 6 ? * MON,WED,FRI *)" &&
      local.power_start_expression == "cron(0 22 ? * SUN,TUE,THU *)"
    )
    error_message = "got stop ${local.power_stop_expression}, start ${local.power_start_expression}"
  }
}

# Sunday's evening before is Saturday: the week wraps.
run "a_sunday_run_starts_on_saturday" {
  command = plan

  variables {
    power_schedule = { days = "SUN", start_time = "22:00", stop_time = "06:00", timezone = "UTC" }
  }

  assert {
    condition     = local.power_stop_expression == "cron(0 6 ? * SUN *)" && local.power_start_expression == "cron(0 22 ? * SAT *)"
    error_message = "got stop ${local.power_stop_expression}, start ${local.power_start_expression}"
  }
}

# A range may run past Saturday; it is written back without wrapping, which
# EventBridge's cron does not promise to accept.
run "a_range_across_the_weekend" {
  command = plan

  variables {
    power_schedule = { days = "FRI-MON", stop_time = "20:00", timezone = "UTC" }
  }

  assert {
    condition     = local.power_stop_expression == "cron(0 20 ? * SUN-MON,FRI-SAT *)"
    error_message = "got ${local.power_stop_expression}"
  }
}

run "every_day_across_midnight" {
  command = plan

  variables {
    power_schedule = { start_time = "20:00", stop_time = "08:00", timezone = "UTC" }
  }

  assert {
    condition     = local.power_stop_expression == "cron(0 8 * * ? *)" && local.power_start_expression == "cron(0 20 * * ? *)"
    error_message = "got stop ${local.power_stop_expression}, start ${local.power_start_expression}"
  }
}

run "the_start_time_must_differ_from_the_stop_time" {
  command = plan

  variables {
    power_schedule = { start_time = "16:10", stop_time = "16:10", timezone = "UTC" }
  }

  expect_failures = [var.power_schedule]
}

run "the_stop_time_must_be_a_clock_time" {
  command = plan

  variables {
    power_schedule = { stop_time = "8pm", timezone = "Australia/Sydney" }
  }

  expect_failures = [var.power_schedule]
}

run "the_start_time_must_be_a_clock_time" {
  command = plan

  variables {
    power_schedule = { stop_time = "20:00", start_time = "12:40am", timezone = "Asia/Muscat" }
  }

  expect_failures = [var.power_schedule]
}

run "the_days_must_be_days_of_the_week" {
  command = plan

  variables {
    power_schedule = { stop_time = "20:00", days = "WEEKDAYS", timezone = "Asia/Muscat" }
  }

  expect_failures = [var.power_schedule]
}
