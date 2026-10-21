# Offline tests of plan-time safety. Proxmox, Talos and the address probe are
# mocked, so nothing here contacts a host. Scenarios use fixtures, never your
# cluster.yaml, so editing it cannot break these tests.

variables {
  state_passphrase = "offline-test-only-passphrase"
  config_file      = "tests/fixtures/single-node.yaml"
}

mock_provider "proxmox" {
  mock_resource "proxmox_download_file" {
    defaults = { id = "local:iso/talos-k8s-lab-8001-v1.14.4-ce4c980550dd-nocloud-amd64.iso" }
  }

  mock_data "proxmox_virtual_environment_vms" {
    defaults = { vms = [] }
  }
}

mock_provider "talos" {
  mock_resource "talos_image_factory_schematic" {
    defaults = { id = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515" }
  }
}

mock_provider "external" {
  mock_data "external" {
    defaults = { result = { answered = "false" } }
  }
}

run "new_cluster_on_an_empty_host" {
  command = plan

  assert {
    condition     = keys(proxmox_virtual_environment_vm.node) == ["cp-1"]
    error_message = "The example cluster.yaml should create exactly one node, cp-1."
  }

  assert {
    condition = (
      proxmox_virtual_environment_vm.node["cp-1"].vm_id == 8001 &&
      proxmox_virtual_environment_vm.node["cp-1"].cpu[0].cores == 4 &&
      proxmox_virtual_environment_vm.node["cp-1"].memory[0].dedicated == 8192 &&
      proxmox_virtual_environment_vm.node["cp-1"].disk[0].size == 64
    )
    error_message = "VM sizing must come from cluster.yaml."
  }

  assert {
    condition     = proxmox_virtual_environment_vm.node["cp-1"].memory[0].floating == 0
    error_message = "Talos does not support memory ballooning, so it must stay off."
  }

  assert {
    condition     = proxmox_virtual_environment_vm.node["cp-1"].initialization[0].ip_config[0].ipv4[0].address == "192.0.2.51/24"
    error_message = "The node address must reach Talos through the cloud-init drive with the network prefix."
  }

  assert {
    condition     = contains(proxmox_virtual_environment_vm.node["cp-1"].tags, "k8s-lab")
    error_message = "Created VMs must carry the cluster tag that later runs use to recognise them."
  }

  assert {
    condition     = proxmox_download_file.talos_iso.overwrite_unmanaged == false && proxmox_download_file.talos_iso.content_type == "iso"
    error_message = "The ISO download must never replace a file this cluster did not create."
  }

  assert {
    condition     = proxmox_download_file.talos_iso.file_name == "talos-k8s-lab-8001-v1.14.4-ce4c980550dd-nocloud-amd64.iso"
    error_message = "The boot ISO name must identify this cluster, not only the Talos release."
  }

  assert {
    condition     = talos_cluster.this.node == "192.0.2.51" && talos_cluster.this.kubernetes_version == "v1.37.1"
    error_message = "etcd must be bootstrapped on cp-1 at the configured Kubernetes version."
  }
}

run "another_cluster_on_the_same_host_gets_its_own_iso" {
  command = plan

  variables {
    config_file = "tests/fixtures/other-cluster.yaml"
  }

  assert {
    condition     = proxmox_download_file.talos_iso.file_name == "talos-k8s-office-9001-v1.14.4-ce4c980550dd-nocloud-amd64.iso"
    error_message = "A second cluster with the same Talos release must not share the first cluster's ISO file."
  }
}

run "rerun_recognises_its_own_running_node" {
  command = plan

  override_data {
    target = data.proxmox_virtual_environment_vms.all
    values = {
      vms = [{ vm_id = 8001, name = "cp-1", node_name = "pve", status = "running", tags = ["controlplane", "k8s-lab"], template = false }]
    }
  }

  override_data {
    target = data.external.address_probe
    values = { result = { answered = "true" } }
  }
}

run "adding_a_worker_next_to_the_running_node" {
  command = plan

  variables {
    config_file = "tests/fixtures/two-nodes.yaml"
  }

  override_data {
    target = data.proxmox_virtual_environment_vms.all
    values = {
      vms = [{ vm_id = 8001, name = "cp-1", node_name = "pve", status = "running", tags = ["controlplane", "k8s-lab"], template = false }]
    }
  }

  override_data {
    target = data.external.address_probe["cp-1"]
    values = { result = { answered = "true" } }
  }

  override_data {
    target = data.external.address_probe["lab-vip"]
    values = { result = { answered = "true" } }
  }

  assert {
    condition     = proxmox_virtual_environment_vm.node["worker-1"].vm_id == 8002 && contains(proxmox_virtual_environment_vm.node["worker-1"].tags, "worker")
    error_message = "The new worker must get its own VM."
  }

  assert {
    condition     = talos_cluster.this.node == "192.0.2.51" && talos_cluster.this.control_plane_nodes == tolist(["192.0.2.51"])
    error_message = "Adding a worker must not move etcd bootstrap or change the control-plane set."
  }
}

run "foreign_vm_id_stops_the_plan" {
  command = plan

  override_data {
    target = data.proxmox_virtual_environment_vms.all
    values = {
      vms = [{ vm_id = 8001, name = "pihole", node_name = "pve", status = "running", tags = [], template = false }]
    }
  }

  expect_failures = [proxmox_virtual_environment_vm.node]
}

run "same_name_without_cluster_tag_is_still_foreign" {
  command = plan

  override_data {
    target = data.proxmox_virtual_environment_vms.all
    values = {
      vms = [{ vm_id = 8001, name = "cp-1", node_name = "pve", status = "stopped", tags = ["k8s-other"], template = false }]
    }
  }

  expect_failures = [proxmox_virtual_environment_vm.node]
}

run "address_that_replies_stops_the_plan" {
  command = plan

  override_data {
    target = data.external.address_probe["cp-1"]
    values = { result = { answered = "true" } }
  }

  expect_failures = [proxmox_virtual_environment_vm.node]
}

run "vip_that_replies_stops_the_first_plan" {
  command = plan

  override_data {
    target = data.external.address_probe["lab-vip"]
    values = { result = { answered = "true" } }
  }

  expect_failures = [proxmox_virtual_environment_vm.node]
}

# Last, so a mistake in your cluster.yaml does not hide the scenarios above.
run "your_cluster_yaml_plans_offline" {
  command = plan

  variables {
    config_file = null
  }
}
