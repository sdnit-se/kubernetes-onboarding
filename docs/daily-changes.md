# Everyday changes

Each kind of change has one path. Pick the row for what you want to change.

| You want to change | Edit | Then run |
| --- | --- | --- |
| VM CPU, memory or disk size | `cluster.yaml` | `mise run plan`, `mise run apply` |
| Talos version | `talos.version` in `cluster.yaml` | `mise run plan`, `mise run apply` |
| Kubernetes version | `kubernetes.version` in `cluster.yaml` | `mise run plan`, `mise run apply` |
| An app's settings or chart version | files in `kubernetes/apps/<app>/` | `git commit`, `git push` |
| A secret an app uses | nothing by hand | `mise run seal ...`, `git commit`, `git push` |
| Runner count or size | `kubernetes/apps/arc-runners/values.yaml` | `git commit`, `git push` |
| Argo CD's version or settings | `kubernetes/bootstrap/argocd/` | `mise run bootstrap` |

## Infrastructure changes

Always read the plan. A healthy rerun with no edits says "No changes".

- **Resizing a VM.** Changing `cpu_cores` or `memory_mib` restarts the VM so
  the change takes effect, which briefly takes a one-node cluster down.
  Disks can grow but not shrink.
- **Upgrading Talos.** Raise `talos.version`. The plan shows an in-place
  update of each node's `talos_machine`, and `apply` upgrades one node at a
  time. Leave `talos.initial_version` alone: it only decides the boot ISO and
  the configuration format, and new nodes still install `talos.version`.
- **Upgrading Kubernetes.** Raise `kubernetes.version` by one minor version at
  a time. `apply` runs Talos's guarded upgrade, component by component.
  Talos 1.14 supports Kubernetes up to 1.37.

A plan that wants to replace or destroy a node VM, or the cluster's secrets,
fails with "Instance cannot be destroyed". That is a guard, not a bug. It
usually means a change, such as a new `vm_id` or storage, would rebuild the
VM. Undo the edit; [growing the cluster](growing-the-cluster.md) explains the
deliberate way to retire a node.

`mise run apply` refuses a plan that is out of date, for example after you
edit `cluster.yaml` again. Run `mise run plan` once more.

## App changes

Argo CD checks your repository every few minutes and applies what changed
under `kubernetes/apps`. Watch it with `mise run argocd`. To roll back, revert
the commit and push.

Each app's `kustomization.yaml` pins its Helm chart version. To upgrade, read
the chart's release notes, raise `version:`, commit and push. Check that it
still renders before you push:

```sh
mise run test:manifests
```

## Upgrading Argo CD

Argo CD is the one component Argo CD does not manage. Raise the version in
`kubernetes/bootstrap/argocd/Chart.yaml`, then:

```sh
mise exec -- helm repo add argo https://argoproj.github.io/argo-helm --force-update
mise exec -- helm dependency update kubernetes/bootstrap/argocd
mise run bootstrap
```

`bootstrap` shows the difference against the running cluster and asks before
applying it. Commit `Chart.yaml` and `Chart.lock`.

## Tool versions

`mise.toml` pins every tool and `mise.lock` records their checksums. To move to
newer tools, change the version in `mise.toml`, run `mise lock`, then
`mise run check`, and commit both files.
