# SPDX-License-Identifier: Apache-2.0
# The boot steps that only an AWS node needs. They are cloud-init commands for
# node-bootstrap's provider_steps input. This module renders text and creates nothing.
locals {
  # AlmaLinux AMIs likely ship SSM Agent but do not always start it. SSM is the
  # operator's access path to an AWS node, not only a bootstrap transport.
  ssm_agent_script = "systemctl enable --now amazon-ssm-agent 2>/dev/null || true"

  # A config.yaml.d drop-in, because only the node itself knows its instance.
  provider_id_script = <<-EOT
    set -eu
    TOKEN=$(curl -sSf --retry 5 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' http://169.254.169.254/latest/api/token)
    ZONE=$(curl -sSf --retry 5 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
    INSTANCE_ID=$(curl -sSf --retry 5 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
    INSTANCE_TYPE=$(curl -sSf --retry 5 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
    install -d -m 0755 /etc/rancher/rke2/config.yaml.d
    printf 'kubelet-arg+:\n  - "provider-id=aws:///%s/%s"\nnode-label+:\n  - "node.kubernetes.io/instance-type=%s"\n' "$ZONE" "$INSTANCE_ID" "$INSTANCE_TYPE" >/etc/rancher/rke2/config.yaml.d/50-aws-instance.yaml
  EOT

  steps = concat(
    [{ name = "ssm-agent", commands = [["/bin/sh", "-c", local.ssm_agent_script]] }],
    var.aws_provider_id ? [{ name = "aws-provider-id", commands = [["/bin/sh", "-c", local.provider_id_script]] }] : [],
  )
}
