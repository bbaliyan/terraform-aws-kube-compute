# SPDX-License-Identifier: Apache-2.0
# The runs share one state, as successive applies of one cluster do. Only the
# candidate subnets are overridden: the subnet a placed cluster keeps comes
# from state, not from a lookup.
#
# override_data targets a whole data source, never one for_each instance, so
# within a run every candidate mocks to the same id and free-IP count. Each run
# gives the candidates a new id, so a cluster that moved would show it.
mock_provider "aws" {
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"] }
  }
}

variables {
  os_image_ami_id       = "ami-0123456789abcdef0"
  cluster_name          = "pool"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_names          = ["private-az1", "private-az2"]
}

run "a_new_cluster_takes_a_candidate_with_room" {
  command = apply

  override_data {
    target = data.aws_subnet.by_name
    values = { id = "subnet-first", available_ip_address_count = 250 }
  }

  assert {
    condition     = output.subnet_id == "subnet-first"
    error_message = "a new cluster must be placed in a candidate with room"
  }
  assert {
    condition     = aws_instance.control_plane["0"].subnet_id == "subnet-first"
    error_message = "the control plane must launch into the chosen subnet"
  }
}

run "the_cluster_stays_when_the_first_candidate_is_full" {
  command = apply

  override_data {
    target = data.aws_subnet.by_name
    values = { id = "subnet-elsewhere", available_ip_address_count = 0 }
  }

  assert {
    condition     = output.subnet_id == "subnet-first"
    error_message = "a placed cluster must stay in its subnet when the first candidate has no room"
  }
  assert {
    condition     = aws_instance.control_plane["0"].subnet_id == "subnet-first"
    error_message = "the control plane must not move to another subnet"
  }
}

run "the_cluster_stays_when_the_candidates_are_reordered" {
  command = apply

  override_data {
    target = data.aws_subnet.by_name
    values = { id = "subnet-roomier", available_ip_address_count = 250 }
  }

  variables {
    subnet_names = ["private-az2", "private-az1"]
  }

  assert {
    condition     = output.subnet_id == "subnet-first"
    error_message = "a roomier first candidate must not pull a placed cluster out of its subnet"
  }
  assert {
    condition     = aws_instance.control_plane["0"].subnet_id == "subnet-first"
    error_message = "the control plane must not move to another subnet"
  }
}

# The security groups must not wait on the choice. data.aws_subnet.selected reads the choice
# resource, so on the plan of an upgrade (no choice in state yet) it is unknown until apply.
# The VPC therefore comes from the candidate that was chosen.
run "the_vpc_comes_from_the_chosen_candidate" {
  command = plan

  override_data {
    target = data.aws_subnet.by_name
    values = { id = "subnet-first", vpc_id = "vpc-of-candidate", available_ip_address_count = 250 }
  }

  override_data {
    target = data.aws_subnet.selected
    values = { vpc_id = "vpc-of-selected" }
  }

  assert {
    condition     = output.vpc_id == "vpc-of-candidate"
    error_message = "the VPC of a subnet_names cluster must come from the chosen candidate, not from the lookup that waits for the choice"
  }
}

# The node name must not wait on the choice either. {zone} in the name template reads the
# zone, so the zone comes from the chosen candidate, not from data.aws_subnet.selected.
run "the_zone_comes_from_the_chosen_candidate" {
  command = plan

  override_data {
    target = data.aws_subnet.by_name
    values = { id = "subnet-first", availability_zone = "eu-west-1b", available_ip_address_count = 250 }
  }

  override_data {
    target = data.aws_subnet.selected
    values = { availability_zone = "eu-west-1c" }
  }

  variables {
    node_name_template = "demo-{zone}-cp{number}"
  }

  assert {
    condition     = aws_instance.control_plane["0"].tags["Name"] == "demo-b-cp01"
    error_message = "the node name must take its zone from the chosen candidate, not from the lookup that waits for the choice"
  }
}
