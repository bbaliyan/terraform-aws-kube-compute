# SPDX-License-Identifier: Apache-2.0
# aws_lb/aws_lb_target_group's arn attribute feeds back into other resources' load_balancer_arn/
# target_group_arn arguments, which the AWS provider's schema validates as ARN-shaped — the mock
# provider's default random string for a computed "arn" attribute fails that validation. Static,
# valid-looking ARNs sidestep it (same fix already applied in ha_control_plane.tftest.hcl, needed
# here too since the loadbalancer_is_the_default run exercises the same NLB resource chain).
mock_provider "aws" {
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:loadbalancer/net/cp-lb-mock/1234567890123456" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/cp-tg-mock/1234567890123456" }
  }
}

variables {
  cluster_name          = "bharat"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
  control_plane_count   = 3
  control_plane_subnets = {
    "eu-west-1a" = "subnet-az-a"
    "eu-west-1b" = "subnet-az-b"
    "eu-west-1c" = "subnet-az-c"
  }
}

run "loadbalancer_is_the_default" {
  command = plan
  assert {
    condition     = length(aws_lb.control_plane) == 1
    error_message = "endpoint_mode defaults to loadbalancer, which must plan the NLB"
  }
  assert {
    condition     = length(aws_route53_record.control_plane_dns) == 0
    error_message = "loadbalancer mode must create no DNS records"
  }
}

run "dns_mode_plans_multivalue_records_and_health_checks" {
  command = plan
  variables {
    endpoint_mode  = "dns"
    cluster_domain = "example.internal"
    hosted_zone_id = "Z0123456789"
  }
  assert {
    condition     = length(aws_lb.control_plane) == 0
    error_message = "dns mode must create no load balancer"
  }
  assert {
    condition     = length(aws_route53_record.control_plane_dns) == 3
    error_message = "dns mode must create one A record per control-plane node"
  }
  assert {
    condition     = alltrue([for r in aws_route53_record.control_plane_dns : r.multivalue_answer_routing_policy == true])
    error_message = "every control-plane DNS record must use multivalue-answer routing"
  }
  assert {
    condition     = length(aws_route53_health_check.control_plane) == 3
    error_message = "dns mode must create one health check per control-plane node"
  }
  assert {
    condition     = alltrue([for hc in aws_route53_health_check.control_plane : hc.type == "CLOUDWATCH_METRIC"])
    error_message = "health checks must be CLOUDWATCH_METRIC type (Route53's public health checkers cannot reach a private VPC IP directly)"
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.control_plane_health) == 3
    error_message = "each health check must be backed by its own EC2 status-check alarm"
  }
  assert {
    condition     = output.registration_address == "cp.bharat.example.internal"
    error_message = "dns mode's registration_address must be the shared record name (cp.<cluster>.<domain>)"
  }
}

run "dns_mode_requires_domain_and_zone" {
  command = plan
  variables {
    endpoint_mode  = "dns"
    cluster_domain = "example.internal"
    # hosted_zone_id/hosted_zone_name omitted on purpose: cluster_domain alone is not enough,
    # dns mode also needs a resolvable zone. (cluster_domain is deliberately still set here,
    # unlike a fully domain-less scenario, so that local.registration_address — passed to the
    # server-join nodes' node-bootstrap module — resolves to a non-null string; node-bootstrap's
    # server-join cloud-init branch interpolates ${registration_address} unconditionally, unlike
    # its server-init branch, and a genuinely null value there is a pre-existing node-bootstrap
    # gap out of scope for this task. The zone-missing half of the AND is sufficient to prove the
    # precondition below rejects an unresolvable dns configuration.)
  }
  expect_failures = [aws_instance.control_plane]
}

run "static_mode_creates_nothing_and_uses_the_supplied_address" {
  command = plan
  variables {
    endpoint_mode               = "static"
    static_registration_address = "my-own-lb.internal.example.test"
  }
  assert {
    condition     = length(aws_lb.control_plane) == 0
    error_message = "static mode must create no load balancer"
  }
  assert {
    condition     = length(aws_route53_record.control_plane_dns) == 0
    error_message = "static mode must create no DNS record"
  }
  assert {
    condition     = output.registration_address == "my-own-lb.internal.example.test"
    error_message = "static mode's registration_address must be the literal static_registration_address"
  }
}

run "static_mode_requires_the_address" {
  command = plan
  variables {
    endpoint_mode = "static"
    # static_registration_address omitted on purpose
  }
  expect_failures = [var.static_registration_address]
}

run "endpoint_mode_rejects_invalid" {
  command = plan
  variables {
    endpoint_mode = "vip"
  }
  expect_failures = [var.endpoint_mode]
}
