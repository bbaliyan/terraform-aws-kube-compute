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
    condition     = length(aws_scheduler_schedule.nightly_stop) == 0 && length(aws_scheduler_schedule.nightly_scale_to_zero) == 0
    error_message = "without nightly_stop nothing may stop the nodes or scale the groups"
  }
}

run "a_cluster_without_autoscaling_only_stops_its_nodes" {
  command = apply

  variables {
    nightly_stop = { time = "20:00", timezone = "Australia/Sydney" }
  }

  assert {
    condition     = aws_scheduler_schedule.nightly_stop[0].schedule_expression == "cron(0 20 * * ? *)"
    error_message = "the stop must fire at nightly_stop.time"
  }
  assert {
    condition     = length(aws_scheduler_schedule.nightly_scale_to_zero) == 0 && length(jsondecode(aws_iam_role_policy.nightly_stop[0].policy).Statement) == 1
    error_message = "a cluster without autoscaled nodes must only be allowed to stop its instances"
  }
  assert {
    condition     = length(aws_scheduler_schedule.nightly_start) == 0
    error_message = "without start_time nothing may start the cluster"
  }
}

run "an_autoscaled_cluster_scales_every_group_to_zero_as_it_stops" {
  command = apply

  variables {
    nightly_stop     = { time = "00:02", timezone = "Europe/London" }
    autoscaled_nodes = { workers = { instance_types = ["t3a.large", "t3a.xlarge"], max_cpu_cores = 8, max_memory_gib = 32 } }
  }

  assert {
    condition     = keys(aws_scheduler_schedule.nightly_scale_to_zero) == ["workers-t3a-large", "workers-t3a-xlarge"]
    error_message = "every instance type's group needs its own scale-to-zero schedule"
  }
  assert {
    condition = alltrue([
      for schedule in aws_scheduler_schedule.nightly_scale_to_zero :
      schedule.schedule_expression == aws_scheduler_schedule.nightly_stop[0].schedule_expression &&
      schedule.schedule_expression_timezone == "Europe/London" &&
      schedule.group_name == "bharat-to-zero"
    ])
    error_message = "a group must go to zero at the moment the nodes stop, when nothing is left to scale it back up"
  }
  assert {
    condition = jsondecode(aws_scheduler_schedule.nightly_scale_to_zero["workers-t3a-xlarge"].target[0].input) == {
      AutoScalingGroupName = module.autoscaled_nodes["workers"].autoscaling_groups["t3a.xlarge"].name
      DesiredCapacity      = 0
    }
    error_message = "the schedule must set its group's desired capacity to zero"
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.nightly_stop[0].policy).Statement[1].Resource == local.autoscaling_group_arns
    error_message = "the schedule's role must be allowed to scale exactly this cluster's groups"
  }
}

run "a_working_week_schedule_starts_and_stops_on_its_days" {
  command = apply

  variables {
    nightly_stop     = { time = "20:10", start_time = "00:40", days = "MON-FRI", timezone = "Asia/Muscat" }
    autoscaled_nodes = { workers = { instance_types = ["t3a.large"], max_cpu_cores = 8, max_memory_gib = 32 } }
  }

  assert {
    condition     = aws_scheduler_schedule.nightly_stop[0].schedule_expression == "cron(10 20 ? * MON-FRI *)"
    error_message = "the stop must fire at nightly_stop.time on nightly_stop.days"
  }
  assert {
    condition     = aws_scheduler_schedule.nightly_scale_to_zero["workers-t3a-large"].schedule_expression == aws_scheduler_schedule.nightly_stop[0].schedule_expression
    error_message = "the groups must go to zero with the stop, on the same days"
  }
  assert {
    condition = (
      aws_scheduler_schedule.nightly_start[0].schedule_expression == "cron(40 0 ? * MON-FRI *)" &&
      aws_scheduler_schedule.nightly_start[0].schedule_expression_timezone == "Asia/Muscat"
    )
    error_message = "the start must fire at nightly_stop.start_time on nightly_stop.days"
  }
  assert {
    condition = (
      aws_scheduler_schedule.nightly_start[0].target[0].arn == "arn:aws:scheduler:::aws-sdk:ec2:startInstances" &&
      jsondecode(aws_scheduler_schedule.nightly_start[0].target[0].input).InstanceIds == local.all_instance_ids
    )
    error_message = "the start must start every instance the stop stops"
  }
  assert {
    condition     = contains([for statement in jsondecode(aws_iam_role_policy.nightly_stop[0].policy).Statement : statement.Action], "ec2:StartInstances")
    error_message = "the schedule's role must be allowed to start the instances"
  }
}

run "hours_across_midnight_start_on_their_own_days" {
  command = apply

  variables {
    nightly_stop = { time = "16:10", days = "MON-FRI", start_time = "20:40", start_days = "SUN-THU", timezone = "UTC" }
  }

  assert {
    condition = (
      aws_scheduler_schedule.nightly_stop[0].schedule_expression == "cron(10 16 ? * MON-FRI *)" &&
      aws_scheduler_schedule.nightly_start[0].schedule_expression == "cron(40 20 ? * SUN-THU *)"
    )
    error_message = "the start must fire on nightly_stop.start_days, and the stop on nightly_stop.days"
  }
}

run "start_days_needs_a_start_time" {
  command = plan

  variables {
    nightly_stop = { time = "16:10", start_days = "SUN-THU", timezone = "UTC" }
  }

  expect_failures = [var.nightly_stop]
}

run "the_stop_time_must_be_a_clock_time" {
  command = plan

  variables {
    nightly_stop = { time = "8pm", timezone = "Australia/Sydney" }
  }

  expect_failures = [var.nightly_stop]
}

run "the_start_time_must_be_a_clock_time" {
  command = plan

  variables {
    nightly_stop = { time = "20:00", start_time = "12:40am", timezone = "Asia/Muscat" }
  }

  expect_failures = [var.nightly_stop]
}

run "the_days_must_be_days_of_the_week" {
  command = plan

  variables {
    nightly_stop = { time = "20:00", days = "WEEKDAYS", timezone = "Asia/Muscat" }
  }

  expect_failures = [var.nightly_stop]
}
