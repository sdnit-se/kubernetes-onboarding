#!/usr/bin/env bats

setup() {
    bats_require_minimum_version 1.5.0
    load helpers
    setup_project
    write_kubeconfig
    openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=sealed-secrets-test -days 1 \
        -keyout "$BATS_TEST_TMPDIR/sealing.key" -out "$BATS_TEST_TMPDIR/sealing.crt" 2>/dev/null
    export SEALED_SECRETS_CERT=$BATS_TEST_TMPDIR/sealing.crt
    mkdir -p kubernetes/apps/demo
    printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n' \
        >kubernetes/apps/demo/kustomization.yaml
}

sealing_keys() {
    export STUB_KEYS=$BATS_TEST_TMPDIR/keys.yaml
    yq -n '{"apiVersion": "v1", "kind": "List", "items": []}' >"$STUB_KEYS"
    for name in "$@"; do
        NAME=$name yq -i '.items += [{"apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/tls",
            "metadata": {"name": strenv(NAME), "namespace": "kube-system", "uid": "1234", "resourceVersion": "99",
                "creationTimestamp": "2026-10-01T00:00:00Z",
                "labels": {"sealedsecrets.bitnami.com/sealed-secrets-key": "active"}},
            "data": {"tls.crt": "Y2VydA==", "tls.key": "a2V5"}}]' "$STUB_KEYS"
    done
}

@test "seal encrypts values without passing them as arguments and registers the file once" {
    printf 'client-id-value\nclient-secret-value\n' >"$BATS_TEST_TMPDIR/answers"
    run mise-tasks/seal demo demo operator-oauth client_id client_secret <"$BATS_TEST_TMPDIR/answers"
    [ "$status" -eq 0 ]
    sealed=kubernetes/apps/demo/operator-oauth.sealed.yaml
    [ "$(yq -r '.kind + " " + .metadata.namespace + "/" + .metadata.name' "$sealed")" = "SealedSecret demo/operator-oauth" ]
    [ "$(yq -r '.spec.encryptedData | keys | join(",")' "$sealed")" = "client_id,client_secret" ]
    run ! grep -q 'client-secret-value' "$sealed" "$CALLS"

    printf 'client-id-value\nrotated-secret\n' >"$BATS_TEST_TMPDIR/answers"
    run mise-tasks/seal demo demo operator-oauth client_id client_secret <"$BATS_TEST_TMPDIR/answers"
    [ "$status" -eq 0 ]
    [ "$(yq '[.resources[] | select(. == "operator-oauth.sealed.yaml")] | length' kubernetes/apps/demo/kustomization.yaml)" -eq 1 ]
}

@test "seal reads multi-line values such as a GitHub App key from a file" {
    openssl genrsa -out "$BATS_TEST_TMPDIR/app.pem" 2048 2>/dev/null
    printf '12345\n67890\n' >"$BATS_TEST_TMPDIR/answers"
    run mise-tasks/seal demo demo arc-github-app github_app_id github_app_installation_id \
        "github_app_private_key=@$BATS_TEST_TMPDIR/app.pem" <"$BATS_TEST_TMPDIR/answers"
    [ "$status" -eq 0 ]
    [ "$(yq -r '.spec.encryptedData | keys | join(",")' kubernetes/apps/demo/arc-github-app.sealed.yaml)" = "github_app_id,github_app_installation_id,github_app_private_key" ]
}

@test "backup, then restore state on a new laptop and keys on a rebuilt cluster" {
    echo '{"encrypted": "state stand-in"}' >infrastructure/terraform.tfstate
    sealing_keys sealed-secrets-key4abcd sealed-secrets-key9wxyz
    run mise-tasks/backup
    [ "$status" -eq 0 ]
    archive=$(ls "$BATS_TEST_TMPDIR"/backups/lab-*.tar.age)
    run ! grep -q 'state stand-in' "$archive"

    rm infrastructure/terraform.tfstate
    usage_archive=$archive usage_identity=$BATS_TEST_TMPDIR/identity.txt run mise-tasks/restore/state
    [ "$status" -eq 0 ]
    [ "$(cat infrastructure/terraform.tfstate)" = '{"encrypted": "state stand-in"}' ]

    usage_archive=$archive usage_identity=$BATS_TEST_TMPDIR/identity.txt run mise-tasks/restore/sealing-keys
    [ "$status" -eq 0 ]
    [ "$(yq -r '[.items[].metadata.name] | join(" ")' "$BATS_TEST_TMPDIR/applied.yaml")" = "sealed-secrets-key4abcd sealed-secrets-key9wxyz" ]
    [ "$(yq '[.items[].metadata | has("uid") or has("resourceVersion")] | any' "$BATS_TEST_TMPDIR/applied.yaml")" = "false" ]
}

@test "restore never overwrites different existing state" {
    echo '{"encrypted": "state stand-in"}' >infrastructure/terraform.tfstate
    sealing_keys sealed-secrets-key4abcd
    run mise-tasks/backup
    archive=$(ls "$BATS_TEST_TMPDIR"/backups/lab-*.tar.age)
    echo '{"encrypted": "newer state"}' >infrastructure/terraform.tfstate

    usage_archive=$archive usage_identity=$BATS_TEST_TMPDIR/identity.txt run mise-tasks/restore/state
    [ "$status" -eq 1 ]
    [ "$(cat infrastructure/terraform.tfstate)" = '{"encrypted": "newer state"}' ]
}

@test "an unchanged cluster does not pile up identical backups" {
    echo '{"encrypted": "state stand-in"}' >infrastructure/terraform.tfstate
    sealing_keys sealed-secrets-key4abcd
    run mise-tasks/backup
    [ "$status" -eq 0 ]
    run mise-tasks/backup
    [ "$status" -eq 0 ]
    [[ $output == *"Nothing changed since"* ]]
    [ "$(find "$BATS_TEST_TMPDIR/backups" -name '*.tar.age' | wc -l)" -eq 1 ]

    sealing_keys sealed-secrets-key4abcd sealed-secrets-keyrenew
    run mise-tasks/backup
    [ "$status" -eq 0 ]
    [ "$(find "$BATS_TEST_TMPDIR/backups" -name '*.tar.age' | wc -l)" -eq 2 ]
}

@test "status does not claim coverage when the newest archive is gone" {
    echo '{"encrypted": "state stand-in"}' >infrastructure/terraform.tfstate
    sealing_keys sealed-secrets-key4abcd
    run mise-tasks/backup
    rm "$BATS_TEST_TMPDIR"/backups/*.tar.age
    run mise-tasks/status
    [ "$status" -eq 1 ]
    [[ $output == *"is missing. Run mise run backup now."* ]]

    run mise-tasks/backup
    [ "$status" -eq 0 ]
    [[ $output == *"Wrote"* ]]
}

@test "schedule-backup installs one weekly entry and keeps other crontab lines" {
    cat >"$BATS_TEST_TMPDIR/bin/crontab" <<'EOF'
#!/usr/bin/env bash
table=$BATS_TEST_TMPDIR/crontab.txt
if [[ $1 == -l ]]; then cat "$table" 2>/dev/null; else new=$(cat); printf '%s\n' "$new" >"$table"; fi
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/crontab"
    echo "0 3 * * * existing-job" >"$BATS_TEST_TMPDIR/crontab.txt"

    MISE_BIN=/opt/mise run mise-tasks/schedule-backup
    [ "$status" -eq 0 ]
    MISE_BIN=/opt/mise run mise-tasks/schedule-backup
    [ "$status" -eq 0 ]
    run cat "$BATS_TEST_TMPDIR/crontab.txt"
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "0 3 * * * existing-job" ]
    [[ ${lines[1]} == "17 9 * * 1 cd '$PROJECT' && '/opt/mise' run backup "* ]]
}

@test "status warns when a renewed sealing key is not backed up yet" {
    echo '{"encrypted": "state stand-in"}' >infrastructure/terraform.tfstate
    sealing_keys sealed-secrets-key4abcd
    run mise-tasks/backup
    [ "$status" -eq 0 ]
    run mise-tasks/status
    [ "$status" -eq 0 ]
    [[ $output == *"holds every sealing key"* ]]

    sealing_keys sealed-secrets-key4abcd sealed-secrets-keyrenew
    run mise-tasks/status
    [ "$status" -eq 1 ]
    [[ $output == *": sealed-secrets-keyrenew"* ]]
}
