locals {
  cluster       = module.config.cluster
  nodes         = local.cluster.nodes
  prefix_length = split("/", local.cluster.network.cidr)[1]

  # Every VM this repository creates carries this tag. A VM ID that is taken by
  # a VM without it belongs to someone else, and the plan stops.
  cluster_tag = "k8s-${local.cluster.name}"

  existing_vms = { for vm in data.proxmox_virtual_environment_vms.all.vms : tostring(vm.vm_id) => vm }

  node_vm_owner = {
    for name, node in local.nodes : name => (
      !contains(keys(local.existing_vms), tostring(node.vm_id)) ? "free" :
      try(local.existing_vms[tostring(node.vm_id)].name == name && contains(local.existing_vms[tostring(node.vm_id)].tags, local.cluster_tag), false) ? "cluster" :
      "foreign"
    )
  }

  control_plane_exists = anytrue([for name, node in local.nodes : node.role == "controlplane" && local.node_vm_owner[name] == "cluster"])
}

# Lists every VM on every Proxmox node the token can see. Read-only.
data "proxmox_virtual_environment_vms" "all" {}

# Best-effort check that nothing already answers on the addresses this cluster
# wants. A reply stops the plan; silence proves nothing, which is why
# cluster.yaml asks you to reserve these addresses outside your DHCP pool.
data "external" "address_probe" {
  for_each = merge(
    { for name, node in local.nodes : name => node.address },
    { "${local.cluster.name}-vip" = local.cluster.network.vip },
  )

  program = ["${path.module}/probe-address.sh"]
  query   = { address = each.value }
}

resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = ["siderolabs/qemu-guest-agent"]
      }
    }
  })
}

data "talos_image_factory_urls" "boot" {
  talos_version = local.cluster.talos.initial_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "nocloud"
}

data "talos_image_factory_urls" "installed" {
  talos_version = local.cluster.talos.version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "nocloud"
}

# Proxmox downloads the boot ISO itself over its API (download-url), so the
# host never needs SSH. New nodes boot it once, then install the version in
# talos.version to disk. The file name carries this cluster's name and its
# first control plane's VM ID, so another cluster on the same host never
# shares, replaces or deletes it.
resource "proxmox_download_file" "talos_iso" {
  node_name           = local.cluster.proxmox.node
  datastore_id        = local.cluster.proxmox.iso_storage
  content_type        = "iso"
  url                 = data.talos_image_factory_urls.boot.urls.iso
  file_name           = "talos-${local.cluster_tag}-${local.nodes[local.bootstrap_node].vm_id}-${local.cluster.talos.initial_version}-${substr(talos_image_factory_schematic.this.id, 0, 12)}-nocloud-amd64.iso"
  overwrite           = false
  overwrite_unmanaged = false
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = local.nodes

  name        = each.key
  description = "Talos ${each.value.role} for the ${local.cluster.name} Kubernetes cluster. Managed by OpenTofu: change cluster.yaml, not this VM."
  tags        = sort([local.cluster_tag, each.value.role])
  node_name   = local.cluster.proxmox.node
  vm_id       = each.value.vm_id

  on_boot         = true
  started         = true
  stop_on_destroy = true

  # Settings from the Talos Proxmox guide: UEFI on q35, host CPU, no memory
  # ballooning, and plain VirtIO SCSI (the "single" variant hangs bootstrap).
  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-pci"
  boot_order    = ["scsi0", "ide0"]

  cpu {
    cores = each.value.cpu_cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory_mib
    floating  = 0
  }

  efi_disk {
    datastore_id      = local.cluster.proxmox.vm_storage
    type              = "4m"
    pre_enrolled_keys = false
  }

  disk {
    datastore_id = local.cluster.proxmox.vm_storage
    interface    = "scsi0"
    size         = each.value.disk_gib
    file_format  = "raw"
    discard      = "on"
    ssd          = true
  }

  cdrom {
    interface = "ide0"
    file_id   = proxmox_download_file.talos_iso.id
  }

  # Talos's nocloud platform reads this cloud-init drive for its address and
  # ignores the generated #cloud-config user data. The machine configuration
  # arrives later over the Talos API.
  initialization {
    datastore_id = local.cluster.proxmox.vm_storage
    interface    = "ide2"

    ip_config {
      ipv4 {
        address = "${each.value.address}/${local.prefix_length}"
        gateway = local.cluster.network.gateway
      }
    }

    dns {
      servers = local.cluster.network.dns_servers
    }
  }

  network_device {
    bridge  = local.cluster.proxmox.bridge
    model   = "virtio"
    vlan_id = local.cluster.proxmox.vlan_id
  }

  agent {
    enabled = true

    wait_for_ip {
      disabled = true
    }
  }

  operating_system {
    type = "l26"
  }

  serial_device {}

  lifecycle {
    # Replacing or deleting a node VM destroys its disk. Retiring a node is a
    # deliberate code change, described in docs/growing-the-cluster.md.
    prevent_destroy = true

    precondition {
      condition     = local.node_vm_owner[each.key] != "foreign"
      error_message = "VM ID ${each.value.vm_id} for node ${each.key} is already used by '${try(local.existing_vms[tostring(each.value.vm_id)].name, "?")}', which this cluster did not create. Choose a free vm_id in cluster.yaml. Nothing was changed."
    }

    precondition {
      condition     = local.node_vm_owner[each.key] == "cluster" || data.external.address_probe[each.key].result.answered == "false"
      error_message = "${each.value.address} (node ${each.key}) replied to ping, but no VM from this cluster owns it. Something else is using it; choose another reserved address in cluster.yaml. Nothing was changed."
    }

    precondition {
      condition     = local.control_plane_exists || data.external.address_probe["${local.cluster.name}-vip"].result.answered == "false"
      error_message = "The VIP ${local.cluster.network.vip} replied to ping before this cluster exists. Something else is using it; choose another reserved address for network.vip in cluster.yaml. Nothing was changed."
    }
  }
}
