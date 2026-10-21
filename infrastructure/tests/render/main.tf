# Renders every node's machine configuration with throwaway secrets, so tests
# and `mise run test` can check the real generated YAML without a cluster.

terraform {
  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "0.12.0"
    }
  }
}

variable "config_file" {
  description = "cluster.yaml to render, relative to the working directory or absolute."
  type        = string
}

module "config" {
  source  = "../../modules/config"
  cluster = yamldecode(file(var.config_file))
}

resource "talos_machine_secrets" "throwaway" {
  talos_version = module.machine_config.config_contract
}

data "talos_image_factory_urls" "installed" {
  talos_version = module.config.cluster.talos.version
  schematic_id  = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"
  platform      = "nocloud"
}

module "machine_config" {
  source          = "../../modules/machine-config"
  cluster         = module.config.cluster
  machine_secrets = talos_machine_secrets.throwaway.machine_secrets
  installer_image = data.talos_image_factory_urls.installed.urls.installer
}

output "machine_configurations" {
  value     = module.machine_config.machine_configurations
  sensitive = true
}
