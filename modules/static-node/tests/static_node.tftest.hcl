# SPDX-License-Identifier: Apache-2.0
# Guards what this module has that an ASG does not: individually-tracked
# instances, a Terraform-assigned hostname each, and taints reaching config.yaml.

mock_provider "aws" {
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"] }
  }
}

variables {
  cluster_name              = "bharat"
  aws_region                = "eu-west-1"
  registration_address      = "10.0.1.5"
  agent_token_ssm_parameter = "/kube-compute/bharat/agent-token"
  security_group_ids        = ["sg-cluster123"]
  subnet_id                 = "subnet-cp-a"
}

run "named_instances_not_a_group" {
  command = plan

  override_data {
    target = data.aws_subnet.selected
    values = { availability_zone = "eu-west-1a", vpc_id = "vpc-mock" }
  }

  variables {
    group_name    = "platform"
    node_count    = 2
    instance_type = "t4g.large"
  }

  assert {
    condition     = length(aws_instance.node) == 2
    error_message = "node_count must produce that many separately-tracked aws_instance resources -- one Terraform-visible instance per node is the entire point of this module"
  }
  assert {
    condition     = length(output.instance_ids) == 2
    error_message = "instance_ids must list every node, since a stop schedule's IAM policy is written against instance ARNs"
  }
  assert {
    condition = alltrue([
      for name, _ in output.node_refs : contains(["bharat-platform-1", "bharat-platform-2"], name)
    ])
    error_message = "node names must be <cluster>-<group>-<n>, numbered from 1 like the control plane's own cp-1/cp-2"
  }
  assert {
    condition     = alltrue([for k, i in aws_instance.node : contains(i.vpc_security_group_ids, "sg-cluster123")])
    error_message = "every node must attach the cluster security group or it cannot reach the control plane to join"
  }
  assert {
    condition     = alltrue([for k, i in aws_instance.node : i.subnet_id == "subnet-cp-a"])
    error_message = "every node must land in the subnet passed in -- the caller passes the control plane's own so the cluster stays in one availability zone"
  }
  assert {
    condition     = alltrue([for k, i in aws_instance.node : i.metadata_options[0].http_tokens == "required"])
    error_message = "IMDSv2 must be enforced"
  }
  assert {
    condition     = alltrue([for k, i in aws_instance.node : i.metadata_options[0].http_put_response_hop_limit == 3])
    error_message = "hop_limit must be 3, not AWS's documented 2 -- Cilium's pod-netns routing costs one hop more than the generic guidance assumes"
  }
  assert {
    condition     = alltrue([for k, i in aws_instance.node : i.root_block_device[0].encrypted])
    error_message = "root volumes must be encrypted"
  }
  assert {
    condition     = output.node_arch == "arm64"
    error_message = "a Graviton instance type must resolve arm64 from AWS's own instance-type metadata, not from a hardcoded family list"
  }
  assert {
    condition     = output.availability_zone == "eu-west-1a"
    error_message = "availability_zone must come from the subnet, not be passed in separately"
  }
  assert {
    condition     = length(aws_iam_role_policy_attachment.ebs_csi) == 1
    error_message = "the EBS CSI policy must be attached by default -- the CSI controller is an ordinary Deployment the scheduler can place on any node in this group"
  }
}

run "each_node_gets_its_own_hostname_and_the_groups_taints" {
  command = plan

  override_data {
    target = data.aws_subnet.selected
    values = { availability_zone = "eu-west-1a", vpc_id = "vpc-mock" }
  }

  variables {
    group_name          = "dedicated"
    node_count          = 1
    instance_type       = "r5a.large"
    cluster_fqdn_suffix = "cluster-x.eu-west-1.example.net"
    node_labels         = { "workload" = "reserved" }
    node_taints         = ["dedicated=true:NoSchedule"]
  }

  assert {
    condition     = yamldecode(module.node_bootstrap["1"].cloud_init_user_data).hostname == "bharat-dedicated-1"
    error_message = "each node's cloud-init must set its own hostname -- RKE2 registers the Kubernetes node name from it, and a name Terraform chose is the reason this module exists"
  }
  assert {
    condition     = yamldecode(module.node_bootstrap["1"].cloud_init_user_data).fqdn == "dedicated-1.cluster-x.eu-west-1.example.net"
    error_message = "the fqdn label must drop the cluster prefix, since cluster_fqdn_suffix already carries the cluster identity"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(module.node_bootstrap["1"].cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "node-taint:") &&
      strcontains(base64decode(f.content), "dedicated=true:NoSchedule")
      if f.path == "/opt/kube-compute/rke2-config-static.yaml"
    ])
    error_message = "node_taints must reach the node's config.yaml -- without the taint a dedicated node is merely preferred and anything else can still land on it"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(module.node_bootstrap["1"].cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "kube-compute.io/node-group=dedicated") &&
      strcontains(base64decode(f.content), "topology.kubernetes.io/zone=eu-west-1a") &&
      strcontains(base64decode(f.content), "workload=reserved")
      if f.path == "/opt/kube-compute/rke2-config-static.yaml"
    ])
    error_message = "the group label, the AZ label and the caller's own labels must all reach config.yaml -- a workload selects the node by one of them"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(module.node_bootstrap["1"].cloud_init_user_data).write_files :
      !strcontains(base64decode(f.content), "/kube-compute/bharat/agent-token'\nAGENT")
      if f.path == "/opt/kube-compute/secrets.env"
    ])
    error_message = "the join token itself must never be in user_data -- only the SSM fetch command that retrieves it at boot"
  }
  assert {
    condition     = length(output.node_taints) == 1 && output.node_taints[0] == "dedicated=true:NoSchedule"
    error_message = "the taints must be exposed so a consumer can build a matching toleration without restating them"
  }
}

run "x86_instance_type_resolves_x86_images" {
  command = plan

  override_data {
    target = data.aws_subnet.selected
    values = { availability_zone = "eu-west-1a", vpc_id = "vpc-mock" }
  }
  override_data {
    target = data.aws_ec2_instance_type.selected
    values = { supported_architectures = ["x86_64"] }
  }

  variables {
    group_name    = "dedicated"
    instance_type = "r5a.large"
    os_image_name = "almalinux10-*-kube-image-v1.36.2-*"
  }

  assert {
    condition     = output.node_arch == "x86_64"
    error_message = "a non-Graviton instance type must resolve x86_64"
  }
  assert {
    condition     = contains(data.aws_ami.by_name[0].filter[*].name, "architecture")
    error_message = "the AMI lookup must filter on architecture as well as name, or a wildcard architecture segment in os_image_name lets an arm64 build satisfy an x86_64 node"
  }
}

run "a_long_cluster_and_group_name_still_fit_the_iam_name_prefix_cap" {
  command = plan

  variables {
    cluster_name = "long-multinode-cluster-abcdefgh"
    group_name   = "observability"
  }

  assert {
    condition     = length(local.node_iam_name_prefix) <= 38
    error_message = "an IAM name_prefix over 38 characters is rejected by AWS at apply time, after the rest of the plan has already been created"
  }
}
