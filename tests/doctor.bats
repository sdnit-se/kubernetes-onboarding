#!/usr/bin/env bats

setup() {
    load helpers
    setup_project
    start_fake_proxmox
}

teardown() {
    stop_fake_proxmox
}

add_worker() {
    yq -i '.nodes["worker-1"] = {"role": "worker", "vm_id": 8002, "address": "10.20.0.52", "cpu_cores": 4, "memory_mib": 8192, "disk_gib": 64}' cluster.yaml
}

cp_1_exists() {
    echo '{"data":[{"vmid":101,"name":"pihole","type":"qemu","tags":""},{"vmid":8001,"name":"cp-1","type":"qemu","tags":"controlplane;k8s-lab"}]}' \
        >"$API_ROOT/cluster/resources"
}

@test "a healthy host and token pass" {
    run mise-tasks/doctor
    [ "$status" -eq 0 ]
    [[ $output == *"Proxmox VE 9.0.3"* ]]
    [[ $output == *"new node(s) cp-1 (65 GiB needed)"* ]]
}

@test "documentation placeholders stop before contacting anything" {
    cp "$FIXTURE" cluster.yaml
    run mise-tasks/doctor
    [ "$status" -eq 1 ]
    [[ $output == *"replace the example 192.0.2.x addresses"* ]]
    [[ $output == *"add an age public key"* ]]
    [[ $output != *"Proxmox API"* ]]
}

@test "adding a worker only needs space for the worker's disks" {
    add_worker
    cp_1_exists
    set_free_gib 70
    run mise-tasks/doctor
    [ "$status" -eq 0 ]
    [[ $output == *"new node(s) worker-1 (65 GiB needed)"* ]]
}

@test "a rerun with every node created needs no new space" {
    cp_1_exists
    set_free_gib 1
    run mise-tasks/doctor
    [ "$status" -eq 0 ]
    [[ $output == *"every node already has its disks"* ]]
}

@test "too little space for the new worker fails" {
    add_worker
    cp_1_exists
    set_free_gib 40
    run mise-tasks/doctor
    [ "$status" -eq 1 ]
    [[ $output == *"40 GiB free, but new node(s) worker-1 need 65 GiB"* ]]
}

@test "a VM with the same name from another cluster does not count as created" {
    echo '{"data":[{"vmid":8001,"name":"cp-1","type":"qemu","tags":"k8s-other"}]}' >"$API_ROOT/cluster/resources"
    set_free_gib 10
    run mise-tasks/doctor
    [ "$status" -eq 1 ]
    [[ $output == *"new node(s) cp-1 need 65 GiB"* ]]
}

@test "a token that cannot see every VM is refused" {
    jq '.data["/vms"] = {}' "$API_ROOT/access/permissions" >"$BATS_TEST_TMPDIR/p" && mv "$BATS_TEST_TMPDIR/p" "$API_ROOT/access/permissions"
    run mise-tasks/doctor
    [ "$status" -eq 1 ]
    [[ $output == *"collisions cannot hide: the token lacks VM.Audit on /vms"* ]]
}

@test "missing ISO download permission is explicit and never falls back to SSH" {
    jq '.data["/nodes/pve"] = {}' "$API_ROOT/access/permissions" >"$BATS_TEST_TMPDIR/p" && mv "$BATS_TEST_TMPDIR/p" "$API_ROOT/access/permissions"
    run mise-tasks/doctor
    [ "$status" -eq 1 ]
    [[ $output == *"grant Sys.AccessNetwork on /nodes/pve"* ]]
    [[ $output == *"never falls back to SSH"* ]]
}

@test "ISO storage without the ISO content type is refused" {
    jq '.data[0].content = "backup,vztmpl"' "$API_ROOT/nodes/pve/storage" >"$BATS_TEST_TMPDIR/s" && mv "$BATS_TEST_TMPDIR/s" "$API_ROOT/nodes/pve/storage"
    run mise-tasks/doctor
    [ "$status" -eq 1 ]
    [[ $output == *'local must be active with the "ISO image" content type'* ]]
}

@test "a missing bridge is reported, not created" {
    yq -i '.proxmox.bridge = "vmbr9"' cluster.yaml
    run mise-tasks/doctor
    [ "$status" -eq 1 ]
    [[ $output == *"no active bridge named vmbr9"* ]]
}
