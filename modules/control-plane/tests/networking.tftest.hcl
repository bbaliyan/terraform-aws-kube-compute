# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {
  # Deterministic default-VPC subnets for the fallback path.
  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-mock-a", "subnet-mock-b"] }
  }
  # Default to arm64 (Graviton); runs that need x86_64 use override_data below.
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"] }
  }
}

variables {
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
}

run "explicit_subnet_and_arm64" {
  command = plan
  variables {
    cluster_name  = "bharat"
    instance_type = "m7g.large"
    subnet_id     = "subnet-explicit123"
  }
  assert {
    condition     = output.node_arch == "arm64"
    error_message = "instance type reporting arm64 in AWS metadata must produce arm64 node_arch"
  }
  assert {
    condition     = output.subnet_id == "subnet-explicit123"
    error_message = "an explicit subnet_id must be used as-is"
  }
}

run "subnet_name_lookup" {
  command = plan
  override_data {
    target = data.aws_subnet.by_name
    values = { id = "subnet-byname456", available_ip_address_count = 251 }
  }
  variables {
    cluster_name = "byname"
    subnet_name  = "my-private-subnet-az1"
  }
  assert {
    condition     = output.subnet_id == "subnet-byname456"
    error_message = "subnet_name should resolve to the looked-up subnet ID"
  }
}

# subnet_names goes through the same lookup and selection as subnet_name.
#
# Which of several candidates wins cannot be asserted here: override_data only
# targets a whole data source, never one for_each instance, so every candidate
# necessarily mocks to the same id and the same free-IP count. What IS
# distinguishable under that constraint is covered below: room for the cluster,
# no room anywhere, some room but too little, and an existing cluster staying
# put in a subnet that has since filled.
run "subnet_names_lookup" {
  command = plan
  override_data {
    target = data.aws_subnet.by_name
    values = { id = "subnet-pool123", available_ip_address_count = 250 }
  }
  variables {
    cluster_name = "pool"
    subnet_names = ["private-az1", "private-az2"]
  }
  assert {
    condition     = output.subnet_id == "subnet-pool123"
    error_message = "subnet_names should resolve to a looked-up subnet ID"
  }
}

run "subnet_names_all_full_fails" {
  command = plan
  override_data {
    target = data.aws_subnet.by_name
    values = { id = "subnet-pool123", available_ip_address_count = 0 }
  }
  variables {
    cluster_name = "pool"
    subnet_names = ["private-az1", "private-az2"]
  }
  expect_failures = [data.aws_subnet.selected]
}

# Some free addresses, but fewer than the nodes the cluster launches with: the
# apply would fail partway through, so the plan must refuse the subnet.
run "subnet_names_too_few_free_ips_fails" {
  command = plan
  override_data {
    target = data.aws_subnet.by_name
    values = { id = "subnet-pool123", available_ip_address_count = 2 }
  }
  variables {
    cluster_name        = "pool"
    subnet_names        = ["private-az1", "private-az2"]
    subnet_min_free_ips = 3
  }
  expect_failures = [data.aws_subnet.selected]
}

run "subnet_names_exactly_enough_free_ips" {
  command = plan
  override_data {
    target = data.aws_subnet.by_name
    values = { id = "subnet-pool123", available_ip_address_count = 3 }
  }
  variables {
    cluster_name        = "pool"
    subnet_names        = ["private-az1", "private-az2"]
    subnet_min_free_ips = 3
  }
  assert {
    condition     = output.subnet_id == "subnet-pool123"
    error_message = "a candidate with exactly subnet_min_free_ips free addresses must be chosen"
  }
}

# An existing control plane keeps the cluster in its subnet, however full the
# candidates now are. Without this the plan would fail, or move the cluster.
run "existing_cluster_stays_in_full_subnet" {
  command = plan
  override_data {
    target = data.aws_subnet.by_name
    values = { id = "subnet-other", available_ip_address_count = 0 }
  }
  override_data {
    target = data.aws_instances.existing_control_plane
    values = { ids = ["i-existing"] }
  }
  override_data {
    target = data.aws_instance.existing_control_plane
    values = { subnet_id = "subnet-placed" }
  }
  variables {
    cluster_name        = "pool"
    subnet_names        = ["private-az1", "private-az2"]
    subnet_min_free_ips = 3
  }
  assert {
    condition     = output.subnet_id == "subnet-placed"
    error_message = "an existing cluster must stay in its control plane's subnet"
  }
  assert {
    condition     = aws_instance.control_plane.subnet_id == "subnet-placed"
    error_message = "the control plane must not be moved to another subnet"
  }
}

# The same holds when the list itself changes: dropping or reordering subnets
# does not move a cluster that already exists.
run "existing_cluster_ignores_candidate_order" {
  command = plan
  override_data {
    target = data.aws_subnet.by_name
    values = { id = "subnet-first-candidate", available_ip_address_count = 250 }
  }
  override_data {
    target = data.aws_instances.existing_control_plane
    values = { ids = ["i-existing"] }
  }
  override_data {
    target = data.aws_instance.existing_control_plane
    values = { subnet_id = "subnet-placed" }
  }
  variables {
    cluster_name = "pool"
    subnet_names = ["private-az2", "private-az1"]
  }
  assert {
    condition     = output.subnet_id == "subnet-placed"
    error_message = "a roomier first candidate must not pull an existing cluster out of its subnet"
  }
}

run "subnet_name_and_subnet_names_are_mutually_exclusive" {
  command = plan
  variables {
    cluster_name = "pool"
    subnet_name  = "private-az1"
    subnet_names = ["private-az1", "private-az2"]
  }
  expect_failures = [var.subnet_names]
}

run "default_vpc_fallback" {
  command = plan
  variables {
    cluster_name  = "bharat"
    instance_type = "m7g.large"
    # subnet_id omitted -> null -> default-VPC fallback
  }
  assert {
    condition     = output.subnet_id == "subnet-mock-a"
    error_message = "null subnet_id must fall back to the first (sorted) default-VPC subnet"
  }
}

run "x86_64_derivation" {
  command = plan
  # Tell the mock that this instance type reports x86_64.
  override_data {
    target = data.aws_ec2_instance_type.selected
    values = { supported_architectures = ["x86_64"] }
  }
  variables {
    cluster_name  = "x86"
    instance_type = "m7i.large"
    subnet_id     = "subnet-x"
  }
  assert {
    condition     = output.node_arch == "x86_64"
    error_message = "instance type reporting x86_64 in AWS metadata must produce x86_64 node_arch"
  }
}

run "explicit_ami_overrides_lookup" {
  command = plan
  variables {
    cluster_name    = "amitest"
    instance_type   = "m7g.large"
    subnet_id       = "subnet-x"
    os_image_ami_id = "ami-0explicit123"
  }
  assert {
    condition     = output.effective_ami_id == "ami-0explicit123"
    error_message = "explicit os_image_ami_id must override the AMI lookup"
  }
}

run "os_image_name_lookup" {
  command = plan
  override_data {
    target = data.aws_ami.by_name
    values = { id = "ami-byname789" }
  }
  variables {
    cluster_name  = "byname"
    instance_type = "m7g.large"
    subnet_id     = "subnet-x"
    os_image_name = "almalinux10-arm64-kube-image-*"
  }
  assert {
    condition     = output.effective_ami_id == "ami-byname789"
    error_message = "os_image_name should resolve to the looked-up AMI ID"
  }
}

run "os_image_ami_id_overrides_os_image_name" {
  command = plan
  variables {
    cluster_name    = "bothset"
    instance_type   = "m7g.large"
    subnet_id       = "subnet-x"
    os_image_ami_id = "ami-0explicit123"
    os_image_name   = "almalinux10-arm64-kube-image-*"
  }
  assert {
    condition     = output.effective_ami_id == "ami-0explicit123"
    error_message = "os_image_ami_id must take precedence over os_image_name when both are set"
  }
}

# Previously broken with the regex approach: im4gn is a Graviton storage family
# (family prefix "im", not matched by the old i[0-9]+g pattern).
# The data-source approach handles it correctly regardless of naming convention.
run "storage_graviton_arm64" {
  command = plan
  variables {
    cluster_name  = "storage"
    instance_type = "im4gn.large"
    subnet_id     = "subnet-x"
  }
  assert {
    condition     = output.node_arch == "arm64"
    error_message = "im4gn.large is Graviton-based; AWS API reports arm64"
  }
}
