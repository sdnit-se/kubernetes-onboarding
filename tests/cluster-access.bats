#!/usr/bin/env bats
# Each test runs in its own subshell, so per-test exports are intended.
# shellcheck disable=SC2030,SC2031

setup() {
    load helpers
    setup_project
}

@test "bootstrap refuses a KUBECONFIG other than this project's" {
    write_kubeconfig
    export KUBECONFIG=$HOME/.kube/config
    run mise-tasks/bootstrap --yes
    [ "$status" -eq 1 ]
    [[ $output == *"Tasks only use $PROJECT/.local/kubeconfig"* ]]
    [ -z "$(mutating_calls)" ]
    [ ! -s "$CALLS" ]
}

@test "bootstrap refuses when credentials were never written" {
    run mise-tasks/bootstrap --yes
    [ "$status" -eq 1 ]
    [[ $output == *"Run mise run credentials"* ]]
    [ ! -s "$CALLS" ]
}

@test "bootstrap refuses a kubeconfig for another cluster" {
    write_kubeconfig
    export STUB_CONTEXT=admin@other STUB_SERVER=https://10.9.9.9:6443
    run mise-tasks/bootstrap --yes
    [ "$status" -eq 1 ]
    [[ $output == *"not admin@lab at https://10.20.0.50:6443"* ]]
    [ -z "$(mutating_calls)" ]
}

@test "bootstrap shows what it will do and stops when not confirmed" {
    write_kubeconfig
    run mise-tasks/bootstrap <<<"n"
    [ "$status" -eq 1 ]
    [[ $output == *"Argo CD is not installed yet"* ]]
    [[ $output == *"syncs kubernetes/apps from https://git.example.test/lab.git"* ]]
    [ -z "$(mutating_calls)" ]
}

@test "bootstrap refuses the template repository URL" {
    write_kubeconfig
    yq -i '.spec.generators[0].git.repoURL = "https://github.com/your-org/your-cluster.git"' kubernetes/bootstrap/apps.yaml
    run mise-tasks/bootstrap --yes
    [ "$status" -eq 1 ]
    [[ $output == *"Set repoURL"* ]]
    [ -z "$(mutating_calls)" ]
}

@test "confirmed bootstrap installs Argo CD and then the ApplicationSet" {
    write_kubeconfig
    usage_yes=true run mise-tasks/bootstrap
    [ "$status" -eq 0 ]
    run mutating_calls
    [ "${lines[0]}" = "helm upgrade --install argocd kubernetes/bootstrap/argocd --namespace argocd --create-namespace" ]
    [ "${lines[1]}" = "kubectl apply --server-side -f kubernetes/bootstrap/apps.yaml" ]
}

@test "restoring sealing keys refuses a foreign cluster before applying anything" {
    write_kubeconfig
    export STUB_SERVER=https://10.9.9.9:6443
    usage_archive=/nonexistent run mise-tasks/restore/sealing-keys
    [ "$status" -eq 1 ]
    [ -z "$(mutating_calls)" ]
}

@test "backup and status refuse to read from the default kubeconfig" {
    unset KUBECONFIG
    run mise-tasks/backup
    [ "$status" -eq 1 ]
    run mise-tasks/status
    [ "$status" -eq 1 ]
    [ ! -s "$CALLS" ]
}

@test "the Argo CD deploy key is applied as a labelled repository Secret without touching argv" {
    write_kubeconfig
    yq -i '.spec.generators[0].git.repoURL = "git@github.com:example/lab.git"' kubernetes/bootstrap/apps.yaml
    printf 'deploy-key-material\n' >"$BATS_TEST_TMPDIR/deploy_key"
    run mise-tasks/repo-credential "$BATS_TEST_TMPDIR/deploy_key"
    [ "$status" -eq 0 ]
    secret=$(yq 'select(.kind == "Secret")' "$BATS_TEST_TMPDIR/applied.yaml")
    [ "$(yq -r '.metadata.labels["argocd.argoproj.io/secret-type"]' <<<"$secret")" = repository ]
    [ "$(yq -r '.data.url | @base64d' <<<"$secret")" = "git@github.com:example/lab.git" ]
    run grep -c 'deploy-key-material' "$CALLS"
    [ "$output" = 0 ]
}

@test "the deploy key task refuses an HTTPS repository URL" {
    write_kubeconfig
    run mise-tasks/repo-credential /dev/null
    [ "$status" -eq 1 ]
    [[ $output == *"Deploy keys work over SSH"* ]]
    [ -z "$(mutating_calls)" ]
}
