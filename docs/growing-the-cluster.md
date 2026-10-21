# Growing the cluster

## Add a worker

Add an entry under `nodes` in `cluster.yaml` with a new name, a free VM ID and
a reserved address:

```yaml
nodes:
  cp-1:
    # unchanged
  worker-1:
    role: worker
    vm_id: 8002
    address: 192.168.1.42
    cpu_cores: 4
    memory_mib: 8192
    disk_gib: 64
```

```sh
mise run doctor
mise run plan
```

The plan creates the new VM and its Talos configuration. Nothing about `cp-1`
changes, because nodes are keyed by name and the control plane's
configuration does not depend on the workers. Apply it with `mise run apply`.
`mise exec -- kubectl get nodes` shows the worker a few minutes later.

`cp-1` keeps running workloads too. Once you have workers, you can stop that by
removing the `KubeNodeConfig` patch in
`infrastructure/modules/machine-config/main.tf`.

## Grow to three control planes

A single control plane is a single point of failure. The next step is three,
never two: etcd needs a majority, and two members are less available than
one. Add `cp-2` and `cp-3` with `role: controlplane`, then plan and apply.
They join the existing etcd cluster, and the Kubernetes API address
(`network.vip`) moves to whichever control plane is healthy, so your
kubeconfig keeps working. Talos API calls always go to node addresses.

## Retire a node

Removing a node destroys its VM and disk, so OpenTofu refuses unless you
switch the guard off for one apply.

1. Move its workloads away and remove it from Kubernetes. `mise exec` makes
   sure these commands reach this cluster, not whatever your shell points at:

   ```sh
   mise exec -- kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data
   mise exec -- talosctl --nodes 192.168.1.42 reset
   mise exec -- kubectl delete node worker-1
   ```

2. Delete its entry from `cluster.yaml`.
3. In `infrastructure/proxmox.tf`, change `prevent_destroy = true` to `false`.
4. Run `mise run plan`. It must destroy only that node's VM and Talos entry.
   If it shows anything else, stop and undo.
5. Run `mise run apply`, then set `prevent_destroy` back to `true`.

For a control plane, remove one at a time and keep an odd number.

## Add an app

Every directory under `kubernetes/apps` becomes an Argo CD Application with
the same name. To add one, create a directory with a `kustomization.yaml`.
The simplest app is plain manifests:

```text
kubernetes/apps/whoami/
├── kustomization.yaml
├── namespace.yaml
├── deployment.yaml
└── service.yaml
```

```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - deployment.yaml
  - service.yaml
```

```yaml
# namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: whoami
  annotations:
    # Argo CD keeps the namespace even if you delete the app later.
    argocd.argoproj.io/sync-options: Delete=false
```

To install a Helm chart instead, copy the `helmCharts` block from
`kubernetes/apps/sealed-secrets/kustomization.yaml`. Pin the chart `version`
and keep your settings in a `values.yaml` next to it.

Check that everything still renders, then commit and push:

```sh
mise run test:manifests
git add kubernetes/apps/whoami
git commit -m "feat: add whoami"
git push
```

Deleting the directory and pushing removes the app's resources. The namespace
stays because of the annotation.

### Secrets for an app

Never commit a plain Secret. Create a sealed one, named the way the app
expects:

```sh
mise run seal whoami whoami whoami-settings api_token
```

This writes `kubernetes/apps/whoami/whoami-settings.sealed.yaml` and adds it
to the kustomization. Argo CD creates an ordinary Secret called
`whoami-settings` in the `whoami` namespace, so the app reads it like any
other Secret. Use `key=@path/to/file` for values stored in files.

## Put an app on your tailnet

Once the Tailscale operator runs, a Service with the `tailscale` load-balancer
class becomes a device on your tailnet:

```yaml
# service.yaml
apiVersion: v1
kind: Service
metadata:
  name: whoami
  namespace: whoami
  annotations:
    tailscale.com/hostname: whoami
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale
  selector:
    app: whoami
  ports:
    - port: 80
      targetPort: 8080
```

After Argo CD syncs it, `http://whoami` works from your tailnet devices.
Tailscale encrypts traffic up to the operator's proxy pod, and the proxy
forwards it to your app inside the cluster. Tailscale's Ingress with HTTPS
certificates needs HTTPS enabled for the whole tailnet, so ask your tailnet
admin before you use it.
