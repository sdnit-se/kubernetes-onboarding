#!/usr/bin/env bash
# Called by OpenTofu's external data source with {"address": "..."} on stdin.
# Prints {"answered": "true"} when something replies to ping at that address.
#
# Best effort: a reply proves the address is taken, silence does not prove it
# is free (firewalls drop ping, devices sleep). You still reserve node
# addresses and the VIP outside your DHCP pool. If ping itself cannot run or
# has no route, the probe fails instead of reporting silence.
set -euo pipefail

address=$(jq -r '.address')

if ! command -v ping >/dev/null; then
    echo "ping is not installed, so the address probe cannot run" >&2
    exit 1
fi

case "$(uname -s)" in
    Darwin) timeout_flag=(-t 2) ;;
    *) timeout_flag=(-W 2) ;;
esac

status=0
output=$(ping -c 2 "${timeout_flag[@]}" "$address" 2>&1) || status=$?

# ping exits 0 on a reply. No reply is exit 1 on Linux (iputils) and 2 on macOS;
# anything else (no route, bad address) is an error, not an answer.
case "$(uname -s):$status" in
    *:0) jq -n '{answered: "true"}' ;;
    Darwin:2 | Linux:1) jq -n '{answered: "false"}' ;;
    *)
        echo "could not probe $address: $output" >&2
        exit 1
        ;;
esac
