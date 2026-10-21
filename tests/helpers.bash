# Shared setup for task tests. Each test runs the real task scripts inside a
# throwaway copy of the repository, with HOME pointing at an empty directory
# and kubectl/helm replaced by stubs that record every call. No test can reach
# a real cluster or a real Proxmox host.

REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)

setup_project() {
    PROJECT=$BATS_TEST_TMPDIR/project
    mkdir -p "$PROJECT/.local" "$PROJECT/infrastructure" "$BATS_TEST_TMPDIR/home" "$BATS_TEST_TMPDIR/bin"
    cp -R "$REPO_ROOT/mise-tasks" "$REPO_ROOT/kubernetes" "$PROJECT/"
    rm -rf "$PROJECT/kubernetes/bootstrap/argocd/charts"

    age-keygen -o "$BATS_TEST_TMPDIR/identity.txt" 2>/dev/null
    RECIPIENT=$(age-keygen -y "$BATS_TEST_TMPDIR/identity.txt")
    export RECIPIENT
    # A stable fixture, not your cluster.yaml, so editing yours never breaks tests.
    FIXTURE=$REPO_ROOT/infrastructure/tests/fixtures/single-node.yaml
    yq '
        .proxmox.endpoint = "https://10.20.0.2:8006/" |
        .network.cidr = "10.20.0.0/24" | .network.gateway = "10.20.0.1" |
        .network.dns_servers = ["10.20.0.1"] | .network.vip = "10.20.0.50" |
        .nodes["cp-1"].address = "10.20.0.51" |
        .backup.age_recipients = [strenv(RECIPIENT)] |
        .backup.directory = strenv(BATS_TEST_TMPDIR) + "/backups"
    ' "$FIXTURE" >"$PROJECT/cluster.yaml"

    yq -i '.spec.generators[0].git.repoURL = "https://git.example.test/lab.git"' \
        "$PROJECT/kubernetes/bootstrap/apps.yaml"

    # Version-manager shims read their configuration from HOME, which is about
    # to change. Tasks started by mise already have the real tool directories
    # on PATH.
    PYTHON3=$(python3 -c 'import sys; print(sys.executable)')
    PATH=$(tr ':' '\n' <<<"$PATH" | grep -v '/shims$' | paste -sd: -)
    export HOME=$BATS_TEST_TMPDIR/home
    export CALLS=$BATS_TEST_TMPDIR/calls.log
    export KUBECONFIG=$PROJECT/.local/kubeconfig
    export STUB_CONTEXT=admin@lab
    export STUB_SERVER=https://10.20.0.50:6443
    REAL_KUBECTL=$(command -v kubectl)
    export REAL_KUBECTL
    : >"$CALLS"
    install_stubs
    export PATH=$BATS_TEST_TMPDIR/bin:$PATH
    cd "$PROJECT" || return
}

install_stubs() {
    cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$CALLS"
args=" $* "
case $args in
    *" config current-context "*) echo "$STUB_CONTEXT" ;;
    *" config view "*) echo "$STUB_SERVER" ;;
    *" get --raw /version "*) echo '{"gitVersion":"v1.37.1"}' ;;
    *" create secret "*) exec "$REAL_KUBECTL" "$@" ;;
    *" get secret "*"sealed-secrets-key"*)
        if [[ $args == *jsonpath* ]]; then
            yq -r '[.items[].metadata.name] | join(" ")' "$STUB_KEYS"
        else
            cat "$STUB_KEYS"
        fi
        ;;
    *" get crd "*) exit 1 ;;
    *" apply "*)
        file=${*: -1}
        if [[ $file == - ]]; then
            cat >>"$BATS_TEST_TMPDIR/applied.yaml"
        elif [[ -f $file ]]; then
            cp "$file" "$BATS_TEST_TMPDIR/applied.yaml"
        fi
        ;;
esac
exit 0
EOF
    cat >"$BATS_TEST_TMPDIR/bin/helm" <<'EOF'
#!/usr/bin/env bash
echo "helm $*" >>"$CALLS"
case $1 in
    status) exit 1 ;;
esac
exit 0
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/kubectl" "$BATS_TEST_TMPDIR/bin/helm"
}

# Valid enough for kubectl's client-side dry run; the stub answers the rest.
write_kubeconfig() {
    cat >"$PROJECT/.local/kubeconfig" <<'EOF'
apiVersion: v1
kind: Config
clusters: [{name: lab, cluster: {server: "https://10.20.0.50:6443"}}]
users: [{name: admin@lab, user: {token: offline-test-not-a-credential}}]
contexts: [{name: admin@lab, context: {cluster: lab, user: admin@lab}}]
current-context: admin@lab
EOF
}

mutating_calls() {
    grep -E '^(helm (upgrade|install|uninstall)|kubectl .*(apply|delete|create secret|rollout restart|patch|replace))' "$CALLS" |
        grep -v -- '--dry-run=client' || true
}

# A minimal Proxmox API: each JSON file under $API_ROOT answers the GET with
# that path. The metadata endpoint also models the Factory's HEAD restriction.
start_fake_proxmox() {
    API_ROOT=$BATS_TEST_TMPDIR/api/api2/json
    mkdir -p "$API_ROOT/access" "$API_ROOT/cluster" "$API_ROOT/nodes/pve"
    echo '{"data":{"version":"9.0.3","release":"9.0"}}' >"$API_ROOT/version"
    local vm_privileges='{"VM.Allocate":1,"VM.Audit":1,"VM.Config.CDROM":1,"VM.Config.CPU":1,"VM.Config.Cloudinit":1,"VM.Config.Disk":1,"VM.Config.HWType":1,"VM.Config.Memory":1,"VM.Config.Network":1,"VM.Config.Options":1,"VM.PowerMgmt":1}'
    jq -n --argjson vm "$vm_privileges" '{data: {
        "/vms": {"VM.Audit": 1},
        "/vms/8001": $vm, "/vms/8002": $vm,
        "/storage/local-lvm": {"Datastore.AllocateSpace": 1, "Datastore.Audit": 1},
        "/storage/local": {"Datastore.AllocateTemplate": 1, "Datastore.Audit": 1},
        "/sdn/zones/localnetwork/vmbr0": {"SDN.Use": 1},
        "/nodes/pve": {"Sys.AccessNetwork": 1},
        "/": {}
    }}' >"$API_ROOT/access/permissions"
    set_free_gib 200
    echo '{"data":[{"iface":"vmbr0","type":"bridge","active":1},{"iface":"eno1","type":"eth","active":1}]}' \
        >"$API_ROOT/nodes/pve/network"
    echo '{"data":[{"vmid":101,"name":"pihole","type":"qemu","tags":""}]}' >"$API_ROOT/cluster/resources"
    echo '{"data":{}}' >"$API_ROOT/nodes/pve/query-url-metadata"

    "$PYTHON3" - "$BATS_TEST_TMPDIR/api" "$BATS_TEST_TMPDIR/port" <<'EOF' &
import functools, http.server, sys, urllib.parse

class ProxmoxHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        request = urllib.parse.urlsplit(self.path)
        if request.path.endswith("/query-url-metadata"):
            target = urllib.parse.parse_qs(request.query).get("url", [""])[0]
            if target == "https://factory.talos.dev/versions":
                self.send_error(500, "invalid server response: '405 Method Not Allowed'")
                return
        super().do_GET()

handler = functools.partial(ProxmoxHandler, directory=sys.argv[1])
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
open(sys.argv[2], "w").write(str(server.server_port))
server.serve_forever()
EOF
    FAKE_API_PID=$!
    for _ in $(seq 50); do [[ -s $BATS_TEST_TMPDIR/port ]] && break; sleep 0.1; done
    yq -i ".proxmox.endpoint = \"http://127.0.0.1:$(cat "$BATS_TEST_TMPDIR/port")/\"" "$PROJECT/cluster.yaml"
    export PROXMOX_VE_API_TOKEN='tofu@pve!onboarding=00000000-0000-0000-0000-000000000000'
    export TF_VAR_state_passphrase=offline-test-only-passphrase
}

stop_fake_proxmox() {
    [[ -n ${FAKE_API_PID:-} ]] && kill "$FAKE_API_PID" 2>/dev/null || true
}

set_free_gib() {
    jq -n --argjson free "$(($1 * 1073741824))" '{data: [
        {storage: "local", content: "iso,vztmpl,backup", active: 1, enabled: 1, avail: 107374182400},
        {storage: "local-lvm", content: "images,rootdir", active: 1, enabled: 1, avail: $free}
    ]}' >"$API_ROOT/nodes/pve/storage"
}
