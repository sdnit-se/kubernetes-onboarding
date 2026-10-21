# Prerequisites

Collect everything on this page before you start. Write each value down,
because you will put most of them into `cluster.yaml`. Put every secret
straight into your password manager.

## Your computer

- Linux, on the same LAN as the Proxmox host. macOS should work with Bash 4.4
  or newer first on your `PATH`, but it has not been tested.
- [mise](https://mise.jdx.dev/getting-started.html), Git, `curl` and `ping`.
  Mise installs everything else at the versions pinned in this repository.
- A password manager.

## The Proxmox host

You need Proxmox VE 8.0 or newer. Open its web UI and note:

| Value | Where to find it | Goes into |
| --- | --- | --- |
| The web UI address, such as `https://192.168.1.10:8006/` | your browser's address bar | `proxmox.endpoint` |
| Node name | the left tree, under Datacenter | `proxmox.node` |
| A storage whose content includes "ISO image" (often `local`) | Datacenter > Storage | `proxmox.iso_storage` |
| A storage whose content includes "Disk image" (often `local-lvm`), with about 70 GiB free | Datacenter > Storage | `proxmox.vm_storage` |
| The bridge your VMs use to reach the LAN (often `vmbr0`) and its VLAN tag, if any | the node > System > Network, or an existing VM's Hardware tab | `proxmox.bridge`, `proxmox.vlan_id` |
| An unused VM ID, such as `8001` | the IDs shown in the left tree | `nodes.cp-1.vm_id` |

This repository uses the storages and bridge as they are. It never changes
storage settings, bridges or host networking, and it never touches a VM it did
not create. If `doctor` later reports that a storage lacks the right content
type, enable it yourself in the Proxmox UI or pick another storage.

If the Proxmox web UI shows a certificate warning, either give Proxmox a
trusted certificate (Datacenter > ACME) or set `proxmox.insecure_tls: true`
in `cluster.yaml`, knowing that the connection is then not verified.

### An API token

OpenTofu talks to Proxmox with an API token. Open a shell on the host from the
web UI (the node > Shell) and run:

```sh
pveum user add kubernetes-onboarding@pve --comment "Kubernetes onboarding"
pveum acl modify / --users kubernetes-onboarding@pve --roles Administrator
pveum user token add kubernetes-onboarding@pve opentofu --privsep 0
```

The last command prints the token's secret once. Save it in your password
manager as `kubernetes-onboarding@pve!opentofu=<secret>`.

The token is an administrator so the cluster can grow later without new
permissions. That does not widen what this repository touches: every plan
only creates or changes VMs tagged with your cluster's name and the one Talos
ISO it downloads, and `mise run plan` shows each change before it happens.

Proxmox downloads the Talos ISO itself (the "Download from URL" feature), so
the host needs outbound HTTPS to `factory.talos.dev`. Nothing here uses SSH.

## Your network

| Value | Example | Goes into |
| --- | --- | --- |
| LAN in CIDR form | `192.168.1.0/24` | `network.cidr` |
| Gateway | `192.168.1.1` | `network.gateway` |
| DNS servers | `192.168.1.1` | `network.dns_servers` |
| One free address for the Kubernetes API | `192.168.1.40` | `network.vip` |
| One free address per node | `192.168.1.41` | `nodes.cp-1.address` |

Reserve these addresses outside your DHCP pool in your router, or shrink the
pool so they stay unused. `mise run plan` pings them and stops if something
answers, but a device that ignores ping can still collide. The reservation is
what keeps them free.

## Secrets you create now

Generate these and save them in your password manager. Losing them means
losing the ability to recover.

1. **State passphrase.** At least 16 characters, for example from
   `openssl rand -base64 24`. OpenTofu encrypts its state and saved plans with
   it.
2. **Backup key.** You create it in step 2 of
   [your first cluster](first-cluster.md), once the repository and its pinned
   `age` tool are installed. Make room for it in your password manager.

## GitHub

- **Your copy of this repository.** Click "Use this template" and create a
  **private** repository. Private matters: the runners in your cluster run
  any workflow in the repository they serve, with a privileged Docker daemon,
  and a public repository accepts workflows from strangers' pull requests.
- **A deploy key for Argo CD.** Run
  `ssh-keygen -t ed25519 -N "" -C argocd -f argocd-deploy-key`. Add
  `argocd-deploy-key.pub` under your repository's Settings > Deploy keys,
  read-only. Save the private file in your password manager and delete the
  local copies after you use them in the first-cluster guide.
- **A GitHub App for the runners.** Under your account's Settings > Developer
  settings > GitHub Apps, create an app with no webhook and these repository
  permissions: Administration read and write, Metadata read-only. Install it
  on your copy of the repository only. Note the App ID (on the app's page) and
  the installation ID (the number at the end of the installation's settings
  URL), and generate a private key. Save all three in your password manager.

## Tailscale

You need someone who administers your tailnet. This repository does not manage
your tailnet's policy, devices, DNS or routes, and nothing is installed on the
Proxmox host. Ask the administrator for two things:

1. **Merge the policy snippet** in [tailscale-policy.hujson](tailscale-policy.hujson)
   into the tailnet policy. It lets the operator own two tags and nothing else.
2. **Create one OAuth client** under Settings > Trust credentials, tagged
   `tag:k8s-operator`, with write access to these scopes: Devices > Core,
   Keys > Auth Keys and General > Services. Save its client ID and secret in
   your password manager.

You can build the cluster first and add Tailscale later. Until then, open
Argo CD through `mise run argocd`.
