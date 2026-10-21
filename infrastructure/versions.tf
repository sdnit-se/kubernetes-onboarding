terraform {
  required_version = "~> 1.13.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.117.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.12.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "2.4.2"
    }
  }

  # State and saved plans hold the cluster's root keys, so OpenTofu refuses to
  # write either of them unencrypted. Losing the passphrase loses the state.
  encryption {
    key_provider "pbkdf2" "passphrase" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "passphrase" {
      keys = key_provider.pbkdf2.passphrase
    }

    state {
      method   = method.aes_gcm.passphrase
      enforced = true
    }

    plan {
      method   = method.aes_gcm.passphrase
      enforced = true
    }
  }
}

variable "state_passphrase" {
  description = "Encrypts OpenTofu state and plans. Keep it in your password manager; set it with TF_VAR_state_passphrase."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.state_passphrase) >= 16
    error_message = "state_passphrase must be at least 16 characters."
  }
}

variable "config_file" {
  description = "Alternative cluster configuration file. Tests use it; leave it unset."
  type        = string
  default     = null
}

module "config" {
  source  = "./modules/config"
  cluster = yamldecode(file(coalesce(var.config_file, "${path.module}/../cluster.yaml")))
}

# No ssh block on purpose: every resource here uses the Proxmox API. If a
# future change needs SSH, the provider fails loudly instead of falling back.
provider "proxmox" {
  endpoint = module.config.cluster.proxmox.endpoint
  insecure = module.config.cluster.proxmox.insecure_tls
}

provider "talos" {}
