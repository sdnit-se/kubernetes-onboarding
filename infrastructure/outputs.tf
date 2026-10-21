output "kubeconfig" {
  description = "Cluster administrator kubeconfig. mise run credentials writes it to .local/kubeconfig."
  value       = talos_cluster_kubeconfig.admin.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "Talos API client configuration. mise run credentials writes it to .local/talosconfig."
  value       = data.talos_client_configuration.admin.talos_config
  sensitive   = true
}

output "nodes" {
  description = "Node name to VM ID and address."
  value       = { for name, vm in proxmox_virtual_environment_vm.node : name => { vm_id = vm.vm_id, address = local.nodes[name].address } }
}
