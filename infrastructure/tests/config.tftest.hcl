# Offline tests of cluster.yaml validation and of the real machine
# configuration the Talos provider generates. Scenarios use fixtures, never
# your cluster.yaml; mise run test:talos-config validates yours.

run "duplicate_vm_id_is_rejected_before_any_api_call" {
  command = plan

  module {
    source = "./modules/config"
  }

  variables {
    cluster = yamldecode(file("tests/fixtures/duplicate-vm-id.yaml"))
  }

  expect_failures = [var.cluster]
}

run "address_outside_the_network_is_rejected" {
  command = plan

  module {
    source = "./modules/config"
  }

  variables {
    cluster = yamldecode(file("tests/fixtures/address-outside-network.yaml"))
  }

  expect_failures = [var.cluster]
}

run "render_single_node" {
  module {
    source = "./tests/render"
  }

  variables {
    config_file = "tests/fixtures/single-node.yaml"
  }

  assert {
    condition = anytrue([
      for document in split("\n---\n", output.machine_configurations["cp-1"]) :
      try(yamldecode(document).kind == "Layer2VIPConfig" && yamldecode(document).name == "192.0.2.50" && yamldecode(document).link == "net0", false)
    ])
    error_message = "The control plane must announce the VIP on the aliased network card."
  }

  assert {
    condition = anytrue([
      for document in split("\n---\n", output.machine_configurations["cp-1"]) :
      try(yamldecode(document).kind == "KubeNodeConfig" && !contains(keys(try(yamldecode(document).taints, {})), "node-role.kubernetes.io/control-plane"), false)
    ])
    error_message = "The single control plane must accept ordinary workloads."
  }

  assert {
    condition = anytrue([
      for document in split("\n---\n", output.machine_configurations["cp-1"]) :
      try(yamldecode(document).kind == "UnattendedInstallConfig" && strcontains(yamldecode(document).installer.image, "nocloud-installer/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515:v1.14.4"), false)
    ])
    error_message = "Nodes must install the nocloud installer with the guest agent extension at talos.version."
  }
}

run "render_after_adding_a_worker" {
  module {
    source = "./tests/render"
  }

  variables {
    config_file           = "tests/fixtures/two-nodes.yaml"
    single_node_cp_config = run.render_single_node.machine_configurations["cp-1"]
  }

  assert {
    condition     = output.machine_configurations["cp-1"] == var.single_node_cp_config
    error_message = "Adding a worker must not change the existing control plane's machine configuration."
  }

  assert {
    condition = !anytrue([
      for document in split("\n---\n", output.machine_configurations["worker-1"]) :
      try(yamldecode(document).kind == "Layer2VIPConfig", false)
    ])
    error_message = "Workers must not try to hold the control-plane VIP."
  }
}
