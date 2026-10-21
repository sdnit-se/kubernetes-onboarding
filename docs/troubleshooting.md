# Troubleshooting

Start with the task that failed. Every check prints what it expected and what
to change.

## mise run doctor

**"cannot reach the API with this token".** Open `proxmox.endpoint` in a
browser from the same computer. If the browser warns about the certificate,
see "An API token" in [prerequisites](prerequisites.md). Check that
`PROXMOX_VE_API_TOKEN` has the form `user@realm!tokenid=secret`.

**"the token lacks ...".** The message names the privilege and the path.
Grant it to the token's user in Datacenter > Permissions, or use the
Administrator role from the prerequisites. A token created without
`--privsep 0` has its own, separate permissions.

**Storage or bridge messages.** `doctor` never changes the host. Enable the
named content type on the storage yourself, or choose another storage or
bridge in `cluster.yaml`.

**"cannot fetch https://factory.talos.dev/versions".** The Proxmox host
itself needs outbound HTTPS. Check its DNS and firewall.

## mise run plan

**"VM ID ... is already used by ...".** Another VM owns that ID. Choose a free
`vm_id`. This repository never adopts an existing VM, even one with the same
name.

**"... replied to ping".** Something on your network already uses that
address. Choose another reserved address. The probe can only prove an address
is taken, never that it is free.

**"could not probe ...".** `ping` could not run or had no route to the
address. Run the plan from a computer on the cluster's LAN.

**"Instance cannot be destroyed".** Your edit would rebuild or delete a node
VM or the cluster's secrets. Undo it. See "Retire a node" in
[growing the cluster](growing-the-cluster.md) if you meant it.

## mise run apply

**It waits a long time at `talos_machine`.** Open the VM's console in
Proxmox. The Talos screen shows its address and stage.

- If it shows a different address, the VM did not get its static address from
  the cloud-init drive. Check that the VM's Cloud-Init tab shows your
  address, and that the ISO's name contains `nocloud`.
- If it says it is installing or rebooting, wait. The first boot downloads
  container images.
- If it is stuck in maintenance mode, your computer cannot reach port 50000 on
  the node. Check firewalls between them.

**"Saved plan is stale".** Something changed since `mise run plan`. Plan again.

After any failure, `mise run plan` shows what is still missing and
`mise run apply` continues from there.

## kubectl or talosctl

**"KUBECONFIG is ..." or "not admin@... at ...".** The tasks only talk to the
cluster in `.local/kubeconfig`. Run `mise run credentials` to rewrite it from
the state.

**kubectl times out on the VIP.** The VIP only answers after etcd is
bootstrapped and the API server is healthy. `mise exec -- talosctl health` talks to the
node directly and shows which part is not ready.

## Argo CD

**An app shows "ComparisonError".** Argo CD could not render it. Run
`mise run test:manifests` to see the same error locally.

**`tailscale-operator` is Degraded.** Usually `operator-oauth` is missing or
wrong. Check the operator's log with
`mise exec -- kubectl --namespace tailscale logs deployment/operator`. A message about
tags means the policy snippet is not merged, or the OAuth client lacks
`tag:k8s-operator`.

**`arc-runners` stays Progressing or jobs never start.** Find the listener
pod with `mise exec -- kubectl --namespace arc-systems get pods` (its name contains
`listener`) and read its log with
`mise exec -- kubectl --namespace arc-systems logs POD-NAME`. Common causes are a `githubConfigUrl` that does not match the repository the
GitHub App is installed on, or a missing Administration permission.

**Runner pods are Pending.** The node does not have the CPU or memory the
runner requests. Lower `maxRunners` or the requests in
`kubernetes/apps/arc-runners/values.yaml`, or add a worker.

**A pod is rejected with a "PodSecurity" message.** Talos enforces the
baseline Pod Security level. Only `arc-runners` allows privileged pods. Make
your app run without privileges rather than relaxing its namespace.

**A sealed file does not decrypt.** It was sealed for another cluster, or the
key that sealed it is gone. Run `mise run status` and follow
[secrets and recovery](secrets-and-recovery.md).
