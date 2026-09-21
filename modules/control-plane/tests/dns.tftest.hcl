# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {}

variables {
  cluster_name          = "bharat"
  aws_region            = "eu-west-1"
  instance_type         = "m7g.large"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-x"
}

run "record_when_zone_and_domain_set" {
  command = plan
  variables {
    cluster_domain = "example.internal"
    hosted_zone_id = "Z0123456789"
  }
  assert {
    condition     = length(aws_route53_record.wildcard) == 1
    error_message = "wildcard record must be created when cluster_domain AND hosted_zone_id are set"
  }
  assert {
    condition     = aws_route53_record.wildcard[0].name == "*.bharat.example.internal"
    error_message = "record must be the wildcard for the cluster FQDN suffix"
  }
  assert {
    condition     = output.cluster_fqdn == "api.bharat.example.internal"
    error_message = "cluster_fqdn must be api.<cluster>.<domain> when a domain is set"
  }
  assert {
    condition     = output.wildcard_dns_name == "*.bharat.example.internal"
    error_message = "wildcard_dns_name output must expose the wildcard for client DNS registration"
  }
}

run "no_record_without_zone_but_name_still_output" {
  command = plan
  variables {
    cluster_domain = "example.internal"
    # hosted_zone_id omitted -> the module creates no record; the client registers DNS themselves
  }
  assert {
    condition     = length(aws_route53_record.wildcard) == 0
    error_message = "no record when hosted_zone_id is null"
  }
  assert {
    condition     = output.wildcard_dns_name == "*.bharat.example.internal"
    error_message = "wildcard_dns_name must still be output so the client can register it elsewhere"
  }
}

run "no_domain_is_ip_only" {
  command = plan
  variables {
    # no cluster_domain -> IP only
  }
  assert {
    condition     = length(aws_route53_record.wildcard) == 0
    error_message = "no record when there is no cluster_domain"
  }
  assert {
    condition     = output.cluster_fqdn == null
    error_message = "cluster_fqdn must be null when no domain is given (IP-only)"
  }
  assert {
    condition     = output.wildcard_dns_name == null
    error_message = "wildcard_dns_name must be null when no domain is given"
  }
}
