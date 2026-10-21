#!/usr/bin/env bats

setup() {
    load helpers
    setup_project
    # A stand-in for tofu output: STUB_TOFU_FAIL names an output that fails,
    # STUB_TOFU_EMPTY one that succeeds with nothing.
    cat >"$BATS_TEST_TMPDIR/bin/tofu" <<'EOF'
#!/usr/bin/env bash
name=${*: -1}
[[ $name == "${STUB_TOFU_FAIL:-}" ]] && { echo "decryption failed" >&2; exit 1; }
[[ $name == "${STUB_TOFU_EMPTY:-}" ]] && exit 0
echo "new $name"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/tofu"
    printf 'old kubeconfig\n' >.local/kubeconfig
    printf 'old talosconfig\n' >.local/talosconfig
    chmod 600 .local/kubeconfig .local/talosconfig
    cp .local/kubeconfig "$BATS_TEST_TMPDIR/kubeconfig.before"
    cp .local/talosconfig "$BATS_TEST_TMPDIR/talosconfig.before"
}

assert_old_pair_untouched() {
    cmp .local/kubeconfig "$BATS_TEST_TMPDIR/kubeconfig.before"
    cmp .local/talosconfig "$BATS_TEST_TMPDIR/talosconfig.before"
    [ -z "$(find .local -name 'credentials.*')" ]
}

@test "a failed first export keeps the existing credentials" {
    STUB_TOFU_FAIL=kubeconfig run mise-tasks/credentials
    [ "$status" -eq 1 ]
    [[ $output == *".local/ was left unchanged"* ]]
    assert_old_pair_untouched
}

@test "a failed second export does not leave a mixed pair" {
    STUB_TOFU_FAIL=talosconfig run mise-tasks/credentials
    [ "$status" -eq 1 ]
    assert_old_pair_untouched
}

@test "an empty export keeps the existing credentials" {
    STUB_TOFU_EMPTY=talosconfig run mise-tasks/credentials
    [ "$status" -eq 1 ]
    assert_old_pair_untouched
}

@test "a successful export replaces both files with private permissions" {
    run mise-tasks/credentials
    [ "$status" -eq 0 ]
    [ "$(cat .local/kubeconfig)" = "new kubeconfig" ]
    [ "$(cat .local/talosconfig)" = "new talosconfig" ]
    [[ $(ls -l .local/kubeconfig) == -rw-------* ]]
    [[ $(ls -l .local/talosconfig) == -rw-------* ]]
    [ -z "$(find .local -name 'credentials.*')" ]
}
