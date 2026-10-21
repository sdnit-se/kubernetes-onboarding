# Kubernetes onboarding

Shebang's hands-on introduction to Kubernetes. You start from a Proxmox host
you already run and end with a single-node Kubernetes cluster that you
understand, can rebuild and can grow. You do every step yourself, and the
repository keeps each step small, previewed and repeatable.

When you finish, you have:

- a Talos Linux VM on Proxmox, created through the Proxmox API, running
  Kubernetes as a control plane that also runs your workloads,
- Argo CD, with its dashboard on your tailnet, deploying everything under
  `kubernetes/apps` from your Git repository,
- Sealed Secrets, so encrypted secrets can live in Git,
- the Tailscale operator, so apps reach your tailnet by declaring a Service,
- GitHub Actions runners with Docker inside your cluster,
- encrypted backups that survive losing your laptop or the cluster.

## Who owns what

Every object in the cluster has exactly one owner. Change it through that
owner and nothing else.

| Layer | What it is | Owner | You change it by |
| --- | --- | --- | --- |
| Infrastructure | VMs, Talos, Kubernetes versions | OpenTofu in `infrastructure/`, reading `cluster.yaml` | editing `cluster.yaml`, then `mise run plan` and `mise run apply` |
| Bootstrap | Argo CD and the one ApplicationSet that points it at Git | `mise run bootstrap`, using `kubernetes/bootstrap/` | editing those files, then `mise run bootstrap` |
| Applications | everything in `kubernetes/apps/` | Argo CD | committing and pushing |

OpenTofu never touches Kubernetes objects. Argo CD never manages itself.
Neither one touches Proxmox guests, disks, bridges or storage it did not
create, your tailnet's policy, devices or DNS, or the Proxmox host's network.

```text
cluster.yaml ──► mise run plan/apply ──► Proxmox VM ──► Talos ──► Kubernetes
kubernetes/bootstrap ──► mise run bootstrap ──► Argo CD
kubernetes/apps/* ──► git push ──► Argo CD ──► Sealed Secrets, Tailscale operator, runners
```

## Start here

1. [Gather the prerequisites](docs/prerequisites.md). It lists everything
   you need from your Proxmox host, network, GitHub and Tailscale.
2. [Build your first cluster](docs/first-cluster.md).
3. [Make everyday changes](docs/daily-changes.md): upgrades, resizing, apps.
4. [Grow the cluster](docs/growing-the-cluster.md): workers, new apps,
   exposing apps on your tailnet.
5. [Secrets, backups and recovery](docs/secrets-and-recovery.md).
6. [Troubleshooting](docs/troubleshooting.md).

## Tasks

Every command is a [mise](https://mise.jdx.dev) task. Mise also installs the
exact tool versions pinned in `mise.toml` and `mise.lock`. List the tasks with
`mise tasks`. The ones you use most:

| Task | What it does |
| --- | --- |
| `mise run doctor` | Checks `cluster.yaml`, your credentials and the Proxmox host. Read-only. |
| `mise run plan` | Shows what would change and saves that exact plan. |
| `mise run apply` | Applies the saved plan, then writes `.local/kubeconfig` and `.local/talosconfig`. |
| `mise run bootstrap` | Installs or upgrades Argo CD after showing the difference. |
| `mise run argocd` | Opens the Argo CD dashboard on `http://localhost:8080`. |
| `mise run seal` | Encrypts a Secret for an app so you can commit it. |
| `mise run backup` | Writes an encrypted backup of state and sealing keys. |
| `mise run status` | Shows nodes, apps and whether your backup is current. |
| `mise run check` | Runs every offline check that CI runs. |

Tasks always use this cluster's credentials in `.local/`, never your default
`~/.kube/config`. Run the tools yourself the same way with
`mise exec -- kubectl ...`, or activate mise in your shell.

## What is deliberately left out

Talos's default network plugin (Flannel) is enough here, so there is no
Cilium, MetalLB, ingress controller or storage system. Kubernetes keeps its
own state in etcd on the control plane, but no app here stores data in a
persistent volume, so Git plus your backup of the OpenTofu state and sealing
keys rebuild the cluster. That backup does not cover application data. Add
storage, and a backup for it, when an app actually needs them.

The tasks are tested on Linux. They need Bash 4.4 or newer, so on macOS
install a newer Bash (`brew install bash`). macOS has not been tested.

## License

MIT. See [LICENSE](LICENSE).
