# Turns cluster.yaml and the cluster secrets into one Talos machine
# configuration per node. Talos generates the base documents; the patches
# below are everything this repository changes.

terraform {
  required_providers {
    talos = {
      source = "siderolabs/talos"
    }
  }
}

variable "cluster" {
  description = "Validated cluster.yaml, as returned by the config module."
  type        = any
}

variable "machine_secrets" {
  description = "machine_secrets from talos_machine_secrets."
  type        = any
  sensitive   = true
}

variable "installer_image" {
  description = "Talos installer image that nodes install and upgrade to."
  type        = string
}

locals {
  # The machine-config format stays at the release the cluster was created
  # with. Upgrading Talos changes talos.version, not this.
  config_contract     = join(".", slice(split(".", var.cluster.talos.initial_version), 0, 2))
  kubernetes_endpoint = "https://${var.cluster.network.vip}:6443"

  node_patches = {
    for name, node in var.cluster.nodes : name => [
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "UnattendedInstallConfig"
        installer  = { image = var.installer_image }
        provisioning = {
          diskSelector = { match = "disk.dev_path == \"/dev/sda\"" }
        }
      }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "HostnameConfig"
        auto       = "off"
        hostname   = name
      }),
      # A stable name for the VM's only network card, whatever the kernel calls it.
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "LinkAliasConfig"
        name       = "net0"
        selector   = { match = "link.driver == \"virtio_net\"" }
      }),
    ]
  }

  control_plane_patches = [
    # The Kubernetes API address. It moves between control-plane nodes once
    # there is more than one, so kubeconfig never needs to change.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "Layer2VIPConfig"
      name       = var.cluster.network.vip
      link       = "net0"
    }),
    # Control-plane nodes also run ordinary workloads in this cluster.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeNodeConfig"
      taints = {
        "node-role.kubernetes.io/control-plane" = { "$patch" = "delete" }
      }
    }),
  ]
}

data "talos_machine_configuration" "node" {
  for_each = var.cluster.nodes

  cluster_name       = var.cluster.name
  cluster_endpoint   = local.kubernetes_endpoint
  machine_type       = each.value.role
  machine_secrets    = var.machine_secrets
  talos_version      = local.config_contract
  kubernetes_version = var.cluster.kubernetes.version
  config_patches     = concat(local.node_patches[each.key], each.value.role == "controlplane" ? local.control_plane_patches : [])
}

output "config_contract" {
  value = local.config_contract
}

output "kubernetes_endpoint" {
  value = local.kubernetes_endpoint
}

output "machine_configurations" {
  value     = { for name, config in data.talos_machine_configuration.node : name => config.machine_configuration }
  sensitive = true
}
