# Your first cluster

Plan for an afternoon. Every step can be rerun: a task that already did its
work changes nothing the second time.

## 1. Get the repository and its tools

```sh
git clone git@github.com:YOUR-ACCOUNT/YOUR-REPO.git
cd YOUR-REPO
mise trust
mise install
```

`mise install` downloads OpenTofu, talosctl, kubectl, Helm and the rest at the
exact versions in `mise.lock`.

This guide runs those tools as `mise exec -- kubectl ...`. That uses the
pinned version and this cluster's credentials in `.local/`, even if your shell
has another Kubernetes context active. If you have
[activated mise](https://mise.jdx.dev/getting-started.html) in your shell,
plain `kubectl` inside this directory does the same.

## 2. Describe your cluster

Create your backup key now, from inside the repository:

```sh
mise exec -- age-keygen
```

Save the whole output in your password manager, including the
`AGE-SECRET-KEY-...` line, and copy the public key (`age1...`) into
`backup.age_recipients` in `cluster.yaml`.

Open `cluster.yaml` and replace every example value with the ones you
gathered in the [prerequisites](prerequisites.md). The comments explain each
field. Keep the node name `cp-1` or choose your own, but do not rename a node
after it exists.

Then point the cluster at your repository:

- In `kubernetes/bootstrap/apps.yaml`, set `repoURL` to your repository's SSH
  address, such as `git@github.com:YOUR-ACCOUNT/YOUR-REPO.git`.
- In `kubernetes/apps/arc-runners/values.yaml`, set `githubConfigUrl` to your
  repository's web address, such as `https://github.com/YOUR-ACCOUNT/YOUR-REPO`.

## 3. Give the tasks your credentials

The Proxmox token and the state passphrase are read from environment
variables. The simplest place for them is `mise.local.toml` in the repository,
which Git ignores:

```toml
[env]
PROXMOX_VE_API_TOKEN = "kubernetes-onboarding@pve!opentofu=PASTE-THE-SECRET"
TF_VAR_state_passphrase = "PASTE-THE-PASSPHRASE"
```

That file is plain text on your disk. If you prefer, export both variables
from your password manager's command-line tool in each new shell instead.

## 4. Check before you change anything

```sh
mise run doctor
```

`doctor` only reads. It checks your edits, your credentials, the token's
permissions, the two storages, the bridge and whether Proxmox can reach the
Talos Image Factory. Fix whatever it reports and run it again.

## 5. Preview and create the VM

```sh
mise run plan
```

Read the plan. On a first run every line is a create (`+`): the Talos image
schematic, the ISO download, one VM, the cluster's secrets, the Talos
configuration and the cluster bootstrap. Nothing is changed or destroyed.
Before saving the plan, OpenTofu also checks that no existing VM uses your VM
ID and that nothing answers on your addresses.

```sh
mise run apply
```

This applies exactly the plan you read. It takes about ten minutes:

1. Proxmox downloads the Talos ISO and creates the VM.
2. The VM boots the ISO. Talos reads its address from the VM's cloud-init
   drive and waits in maintenance mode.
3. OpenTofu sends the machine configuration over the Talos API. Talos installs
   itself to the disk and reboots.
4. OpenTofu bootstraps etcd and Kubernetes starts.
5. The task writes `.local/kubeconfig` and `.local/talosconfig`.

If anything fails halfway, run `mise run plan` and `mise run apply` again. The
plan only contains what is still missing.

Check the result:

```sh
mise exec -- kubectl get nodes
mise exec -- talosctl health
```

## 6. Hand the apps to Argo CD

Argo CD reads from your repository, so push your edits first:

```sh
git add cluster.yaml kubernetes
git commit -m "chore: configure my cluster"
git push
```

Give Argo CD the deploy key, then install it:

```sh
mise run repo-credential path/to/argocd-deploy-key
mise run bootstrap
```

`bootstrap` shows what it will install and asks before it does anything. Open
the dashboard:

```sh
mise run argocd
```

You see one Application per directory in `kubernetes/apps`. `sealed-secrets`
turns green within a few minutes. `tailscale-operator` and `arc-runners` stay
unhealthy until you give them credentials in the next steps; that is
expected.

## 7. Turn on backups

As soon as Sealed Secrets is running:

```sh
mise run backup
mise run schedule-backup
```

`backup` writes an encrypted archive of the OpenTofu state and the sealing
keys to `backup.directory`. `schedule-backup` adds a weekly crontab entry
that repeats it, so the key that Sealed Secrets renews every 30 days always
lands in a backup. Point `backup.directory` at storage that survives losing
this laptop, such as a NAS share. See
[secrets and recovery](secrets-and-recovery.md).

## 8. Connect Tailscale

With the policy snippet merged and the OAuth client created:

```sh
mise run seal tailscale-operator tailscale operator-oauth client_id client_secret
git add kubernetes/apps/tailscale-operator
git commit -m "feat: connect the cluster to Tailscale"
git push
```

`seal` asks for each value without echoing it and writes
`operator-oauth.sealed.yaml`, which only your cluster can decrypt. After Argo
CD syncs, the operator joins your tailnet and Argo CD appears at
`http://argocd`. WireGuard encrypts the way from your device to the cluster;
inside the cluster, the last hop to Argo CD is plain HTTP.

## 9. Start the runners

```sh
mise run seal arc-runners arc-runners arc-github-app github_app_id \
  github_app_installation_id github_app_private_key=@path/to/app-private-key.pem
git add kubernetes/apps/arc-runners
git commit -m "feat: add homelab runners"
git push
```

When `arc-runners` is healthy, open your repository's Actions tab and run the
"homelab runner" workflow. It builds and runs a small image with Docker on
your cluster.

The runners use the upstream Docker-in-Docker mode: each job gets a fresh pod
with a privileged Docker daemon, which is why the `arc-runners` namespace is
the only one allowed privileged pods. A workflow on these runners can do
anything that pod can do, including reaching your LAN. Only run workflows you
trust, keep the repository private, and do not attach these runners to a
public repository.

## 10. Look around

```sh
mise run status
```

You now have a working cluster. Continue with
[everyday changes](daily-changes.md).
