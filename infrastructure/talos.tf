locals {
  control_planes        = { for name, node in local.nodes : name => node if node.role == "controlplane" }
  bootstrap_node        = sort(keys(local.control_planes))[0]
  control_plane_address = [for name in sort(keys(local.control_planes)) : local.control_planes[name].address]
}

resource "talos_machine_secrets" "this" {
  talos_version = module.machine_config.config_contract

  lifecycle {
    # These are the cluster's certificate authorities. Replacing them orphans
    # every node and every kubeconfig.
    prevent_destroy = true
  }
}

module "machine_config" {
  source          = "./modules/machine-config"
  cluster         = local.cluster
  machine_secrets = talos_machine_secrets.this.machine_secrets
  installer_image = data.talos_image_factory_urls.installed.urls.installer
}

# Generated locally from the cluster secrets; nothing is stored or fetched.
ephemeral "talos_cluster_kubeconfig" "drain" {
  cluster_name    = local.cluster.name
  machine_secrets = talos_machine_secrets.this.machine_secrets
  endpoint        = module.machine_config.kubernetes_endpoint
}

# Applies configuration to a node and upgrades Talos when talos.version
# changes. The first apply finds the node in maintenance mode, installs Talos
# to disk and waits for it to come back.
resource "talos_machine" "node" {
  for_each = local.nodes

  node                            = each.value.address
  client_configuration            = talos_machine_secrets.this.client_configuration
  machine_configuration           = module.machine_config.machine_configurations[each.key]
  image                           = data.talos_image_factory_urls.installed.urls.installer
  ignore_kubernetes_upgrade_drift = true

  # Draining a single node has nowhere to move pods to.
  drain_on_upgrade = length(local.nodes) > 1
  kubeconfig_wo    = ephemeral.talos_cluster_kubeconfig.drain.kubeconfig_raw

  depends_on = [proxmox_virtual_environment_vm.node]
}

# Bootstraps etcd once and runs Talos's guarded upgrade-k8s procedure when
# kubernetes.version changes.
resource "talos_cluster" "this" {
  node                 = local.control_planes[local.bootstrap_node].address
  control_plane_nodes  = local.control_plane_address
  client_configuration = talos_machine_secrets.this.client_configuration
  kubernetes_version   = local.cluster.kubernetes.version

  depends_on = [talos_machine.node]
}

resource "talos_cluster_kubeconfig" "admin" {
  node                 = local.control_planes[local.bootstrap_node].address
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [talos_cluster.this]
}

data "talos_client_configuration" "admin" {
  cluster_name         = local.cluster.name
  client_configuration = talos_machine_secrets.this.client_configuration
  # Talos API traffic goes to node addresses, never the VIP, so a broken
  # control plane can still be repaired.
  endpoints = local.control_plane_address
  nodes     = [for name in sort(keys(local.nodes)) : local.nodes[name].address]
}
