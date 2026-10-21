# Secrets, backups and recovery

## Where every secret lives

| Secret | Where it lives | Needed for |
| --- | --- | --- |
| Proxmox API token | password manager | planning and applying |
| State passphrase | password manager | reading OpenTofu state and plans |
| Backup key (age identity) | password manager | restoring a backup |
| Argo CD deploy key | password manager | `mise run repo-credential` after a rebuild |
| Tailscale OAuth client, GitHub App key | password manager, and sealed in Git | resealing if you lose the sealing keys |
| Cluster certificates and keys (Talos secrets) | OpenTofu state, encrypted | everything; they are the cluster's identity |
| Sealing keys | the cluster, and every backup | decrypting the sealed files in Git |

Nothing in that table is ever committed in plain form. Git only holds
`*.sealed.yaml` files, which only your cluster's sealing keys can decrypt.
OpenTofu state, saved plans and `.local/` are ignored by Git. State and plans
are also encrypted with your state passphrase.

## How Sealed Secrets keys work

The Sealed Secrets controller encrypts with its newest key and creates a new
key every 30 days. It keeps the old keys, so everything you sealed earlier
still decrypts. A backup taken before a renewal is missing the new key, and
anything sealed after the renewal could not be decrypted from that backup.
That is why one backup is not enough.

## Backups

A backup covers what it takes to rebuild this cluster: the OpenTofu state and
the sealing keys. It is not a backup of application data. This repository
installs no stateful apps or persistent volumes; if you add some, back up their
data separately.

`mise run backup` writes one archive containing the OpenTofu state (still
encrypted with your passphrase) and every current sealing key, encrypted to
the public keys in `backup.age_recipients`. Taking a backup needs neither the
backup key nor the state passphrase on this computer, which is what makes it
safe to schedule. It does read the sealing keys with the cluster's admin
kubeconfig in `.local/`, so protect that file like any other credential. If nothing changed
since the last archive, it writes nothing.

`mise run schedule-backup` adds a crontab entry that runs the backup every
Monday. Your computer has to be on and on the LAN; a missed week is caught up
the next time it runs. Run `mise run backup` by hand after you change the
infrastructure, too.

`mise run status` checks that the newest archive still exists in
`backup.directory` and contains every sealing key the cluster has. It fails
when either is not true.

Keep `backup.directory` on storage that survives losing both this computer and
the cluster, for example a NAS share or a synced folder. Copy an archive
somewhere else from time to time.

## Recovery

These procedures follow the tools' documented behavior. They have not been
rehearsed against a real host for this repository, so try them once on a
spare cluster before you need them.

### You lost your computer

The cluster is fine. On the new computer:

1. Clone your repository, `mise trust`, `mise install`, and recreate
   `mise.local.toml` from your password manager.
2. Save your backup key from the password manager to a temporary file, then:

   ```sh
   mise run restore:state backups/lab-YYYYMMDDTHHMMSSZ.tar.age --identity /tmp/backup-key.txt
   rm /tmp/backup-key.txt
   ```

3. `mise run plan` should report no changes. Then write your credentials:

   ```sh
   mise run credentials
   mise run status
   ```

### The cluster's VM is gone or broken

Your state and backups are fine. The cluster's certificates are in the state,
so the rebuilt cluster keeps its identity.

1. If the VM still exists but is broken, delete it yourself in the Proxmox UI.
   OpenTofu will not delete it for you.
2. Tell OpenTofu to forget the node and the old bootstrap:

   ```sh
   mise exec -- tofu -chdir=infrastructure state rm \
     'proxmox_virtual_environment_vm.node["cp-1"]' 'talos_machine.node["cp-1"]' \
     talos_cluster.this talos_cluster_kubeconfig.admin
   ```

3. `mise run plan` creates the VM again. Read it, then `mise run apply`.
4. Put the sealing keys back before Argo CD installs Sealed Secrets:

   ```sh
   mise run restore:sealing-keys backups/lab-YYYYMMDDTHHMMSSZ.tar.age --identity /tmp/backup-key.txt
   mise run repo-credential path/to/argocd-deploy-key
   mise run bootstrap
   ```

Argo CD then reinstalls every app, and every sealed file in Git decrypts.

### You lost everything except your backups

Follow "You lost your computer" up to restoring the state, then "The cluster's
VM is gone or broken".

### You lost the sealing keys but not the cluster's Git history

Seal every secret again from your password manager with `mise run seal`,
commit and push. Each `seal` run replaces the old sealed file.

### You lost the state passphrase

The state cannot be decrypted. The running cluster keeps working, and you can
still use it while `.local/kubeconfig` and `.local/talosconfig` exist. To
manage the infrastructure with OpenTofu again you have to build a new cluster
with a new VM ID and move your apps to it.
