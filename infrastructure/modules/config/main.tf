# Types and rules for cluster.yaml. OpenTofu reports a failed rule here before
# it contacts Proxmox, so a typo never reaches the host.

variable "cluster" {
  type = object({
    name = string
    talos = object({
      version         = string
      initial_version = string
    })
    kubernetes = object({
      version = string
    })
    proxmox = object({
      endpoint     = string
      insecure_tls = bool
      node         = string
      iso_storage  = string
      vm_storage   = string
      bridge       = string
      vlan_id      = optional(number)
    })
    network = object({
      cidr        = string
      gateway     = string
      dns_servers = list(string)
      vip         = string
    })
    nodes = map(object({
      role       = string
      vm_id      = number
      address    = string
      cpu_cores  = number
      memory_mib = number
      disk_gib   = number
    }))
  })

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$", var.cluster.name))
    error_message = "name must be a short DNS label: lowercase letters, digits and dashes."
  }

  validation {
    condition = alltrue([
      for version in [var.cluster.talos.version, var.cluster.talos.initial_version, var.cluster.kubernetes.version] :
      can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", version))
    ])
    error_message = "talos.version, talos.initial_version and kubernetes.version must look like v1.2.3."
  }

  validation {
    condition     = can(regex("^https?://[^/]+(:[0-9]+)?/?$", var.cluster.proxmox.endpoint))
    error_message = "proxmox.endpoint must be the API base URL, for example https://pve.lan:8006/."
  }

  validation {
    condition     = can(cidrhost(var.cluster.network.cidr, 0)) && can(cidrhost("${var.cluster.network.gateway}/32", 0)) && can(cidrhost("${var.cluster.network.vip}/32", 0))
    error_message = "network.cidr must be CIDR notation, and network.gateway and network.vip must be plain IPv4 addresses."
  }

  validation {
    condition     = length(var.cluster.nodes) > 0 && length([for node in values(var.cluster.nodes) : node if node.role == "controlplane"]) > 0
    error_message = "nodes must contain at least one node with role: controlplane."
  }

  validation {
    condition     = alltrue([for name, node in var.cluster.nodes : can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", name))])
    error_message = "Node names become hostnames: use lowercase letters, digits and dashes."
  }

  validation {
    condition     = alltrue([for node in values(var.cluster.nodes) : contains(["controlplane", "worker"], node.role)])
    error_message = "Each node role must be controlplane or worker."
  }

  validation {
    condition     = alltrue([for node in values(var.cluster.nodes) : node.vm_id >= 100 && node.vm_id <= 999999999 && floor(node.vm_id) == node.vm_id])
    error_message = "Each vm_id must be a whole number between 100 and 999999999, which is the range Proxmox accepts."
  }

  validation {
    condition     = length(distinct([for node in values(var.cluster.nodes) : node.vm_id])) == length(var.cluster.nodes)
    error_message = "Two nodes share a vm_id. Every node needs its own."
  }

  validation {
    condition = length(distinct(concat(
      [for node in values(var.cluster.nodes) : node.address],
      [var.cluster.network.gateway, var.cluster.network.vip],
    ))) == length(var.cluster.nodes) + 2
    error_message = "Node addresses, the gateway and the VIP must all be different."
  }

  validation {
    condition = alltrue([
      for address in concat([for node in values(var.cluster.nodes) : node.address], [var.cluster.network.gateway, var.cluster.network.vip]) :
      can(cidrhost("${address}/32", 0)) && can(cidrhost(var.cluster.network.cidr, 0)) &&
      cidrhost("${address}/${split("/", var.cluster.network.cidr)[1]}", 0) == cidrhost(var.cluster.network.cidr, 0)
    ])
    error_message = "Every node address, the gateway and the VIP must be inside network.cidr."
  }

  validation {
    condition = alltrue([
      for node in values(var.cluster.nodes) :
      node.cpu_cores >= 2 && node.memory_mib >= 2048 && node.disk_gib >= 16
    ])
    error_message = "Talos needs at least 2 CPU cores, 2048 MiB of memory and a 16 GiB disk per node."
  }

  validation {
    condition     = var.cluster.proxmox.vlan_id == null || try(var.cluster.proxmox.vlan_id >= 1 && var.cluster.proxmox.vlan_id <= 4094, false)
    error_message = "proxmox.vlan_id must be between 1 and 4094, or left out for an untagged bridge."
  }
}

output "cluster" {
  value = var.cluster
}
