# Kubernetes onboarding

Shebang's hands-on introduction to Kubernetes. Starting from a Proxmox host
you already run, you build a small cluster yourself, one previewed step at a
time, and end up with something you understand, can rebuild and can grow.

You will set up:

- a Talos Linux VM on Proxmox running Kubernetes,
- Argo CD, deploying everything in `kubernetes/apps` from your Git repository,
- Sealed Secrets, so encrypted secrets can live in Git,
- the Tailscale operator, to put apps on your tailnet,
- GitHub Actions runners with Docker,
- encrypted backups of what it takes to rebuild the cluster.

## Who owns what

Each part has one owner, and you change it through that owner:

| Part | Owner | You change it by |
| --- | --- | --- |
| VMs, Talos and Kubernetes versions | OpenTofu in `infrastructure/`, reading `cluster.yaml` | editing `cluster.yaml`, then `mise run plan` and `mise run apply` |
| Argo CD and the ApplicationSet that points it at Git | `mise run bootstrap`, using `kubernetes/bootstrap/` | editing those files, then `mise run bootstrap` |
| Apps in `kubernetes/apps/` | Argo CD | committing and pushing |

Every command is a [mise](https://mise.jdx.dev) task, and `mise tasks` lists
them. Mise also installs the exact tool versions the repository pins.

## Guides

Start with the prerequisites, then build your first cluster:

1. [Prerequisites](docs/prerequisites.md): what to gather from Proxmox, your
   network, GitHub and Tailscale.
2. [Your first cluster](docs/first-cluster.md)
3. [Everyday changes](docs/daily-changes.md)
4. [Growing the cluster](docs/growing-the-cluster.md)
5. [Secrets, backups and recovery](docs/secrets-and-recovery.md)
6. [Troubleshooting](docs/troubleshooting.md)

## License

MIT. See [LICENSE](LICENSE).
