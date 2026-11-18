#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
exec unshare -Urn bash -s -- "$root/build/linux-tun" <<'CHECK'
set -euo pipefail
build=$1
run=$(mktemp -d "$build/recovery-check.XXXXXX")
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$run/no-system-bus"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$run/no-session-bus"
trap 'if [[ -n ${guard:-} ]]; then kill "$guard" 2>/dev/null || true; wait "$guard" || true; fi; if [[ -n ${site:-} ]]; then kill "$site" 2>/dev/null || true; wait "$site" || true; fi; rm -rf -- "$run"' EXIT

ip link set lo up
unshare -n bash -euc '
    until ip link show peer >/dev/null 2>&1; do sleep .05; done
    ip link set lo up
    ip addr add 198.18.1.1/32 dev lo
    ip addr add 198.18.0.2/30 dev peer
    ip link set peer up
    exec python3 -u -c "$1"
' _ '
from http.server import BaseHTTPRequestHandler, HTTPServer
from socket import AF_INET, SOCK_DGRAM, inet_aton, socket
from struct import pack
from threading import Thread

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"recovery fixture")

def respond(server):
    while True:
        request, peer = server.recvfrom(512)
        question = b"\x05probe\x07utabako\x04test\0\0\x01\0\x01"
        if request[12:12 + len(question)].lower() == question:
            answer = pack("!3HIH", 0xc00c, 1, 1, 0, 4) + inet_aton("198.18.1.1")
            server.sendto(request[:2] + pack("!5H", 0x8180, 1, 1, 0, 0) + question + answer, peer)

with socket(AF_INET, SOCK_DGRAM) as dns:
    dns.bind(("198.18.1.1", 5353))
    Thread(target=respond, args=(dns,), daemon=True).start()
    HTTPServer(("198.18.1.1", 8080), Handler).serve_forever()
' >"$run/site.log" 2>&1 &
site=$!
for _ in {1..50}; do
    [[ $(readlink "/proc/$site/ns/net") != "$(readlink /proc/self/ns/net)" ]] && break
    sleep .05
done
[[ $(readlink "/proc/$site/ns/net") != "$(readlink /proc/self/ns/net)" ]]
ip link add uplink type veth peer name peer
ip link set dev uplink addrgenmode none
ip -6 addr add 2001:db8:1::1/64 dev uplink nodad
ip link set peer netns "$site"
ip addr add 198.18.0.1/30 dev uplink
ip link set uplink up
ip route add default via 198.18.0.2

http() { curl -fsS --noproxy '*' --max-time 3 http://198.18.1.1:8080/; }
dns() { dig +time=1 +tries=1 +short @198.18.1.1 -p "$1" probe.utabako.test A; }
for _ in {1..50}; do http >/dev/null 2>&1 && break; sleep .05; done
[[ $(http) == 'recovery fixture' && $(dns 5353) == 198.18.1.1 ]]

# These rules overlap sing-tun's old priority range. The existing sing-box
# table and Docker's shared chain belong to other services, not this worker.
for family in -4 -6; do
    ip "$family" rule add pref 1 fwmark 0x77 lookup 99 protocol 128
    ip "$family" rule add pref 9000 fwmark 0x78 lookup 99 protocol 128
done
ip route add 198.19.0.0/24 dev uplink table 99 protocol 128
nft add table inet sing-box
nft add chain inet sing-box keep
nft add table ip filter
nft add chain ip filter DOCKER-USER
nft 'add rule ip filter DOCKER-USER counter comment "third-party"'

snapshot() {
    ip -brief link
    for family in -4 -6; do
        ip -details "$family" rule show
        ip "$family" route show table all
    done
    nft -s list ruleset
}
snapshot >"$run/before"

make_config() {
    local mode=$1
    cat >"$run/tun.json" <<JSON
{
 "log":{"level":"warn"},
 "dns":{"servers":[{"type":"udp","tag":"fixture","server":"198.18.1.1","server_port":5353}],"final":"fixture"},
 "inbounds":[{"type":"tun","tag":"tun-in","interface_name":"utabako-test","address":["172.19.0.1/30","fdfe:dcba:9876::1/126"],"stack":"gvisor","auto_route":true,"auto_redirect":$mode,"strict_route":true,"dns_mode":"hijack"}],
 "outbounds":[{"type":"direct","tag":"fixture-direct"}],
 "route":{"auto_detect_interface":true,"rules":[{"action":"sniff"},{"protocol":"dns","action":"hijack-dns"}]}
}
JSON
}

start() {
    local phase=$1
    "$build/boxdd" run -D "$run/$phase" --socket "$run/$phase.sock" >"$run/boxdd.log" 2>&1 &
    guard=$!
    for _ in {1..50}; do
        [[ -S "$run/$phase.sock" ]] && break
        sleep .05
    done
    if ! "$build/diagnostics" -socket "$run/$phase.sock" start "$run/tun.json"; then
        cat "$run/boxdd.log" >&2
        return 1
    fi
}

check_restored() {
    snapshot >"$run/after"
    diff -u "$run/before" "$run/after"
    [[ $(http) == 'recovery fixture' && $(dns 5353) == 198.18.1.1 ]]
    ! dns 53 >/dev/null 2>&1
}

for redirect in false true; do
    make_config "$redirect"
    start "normal-$redirect"
    ip link show utabako-test >/dev/null
    [[ $(http) == 'recovery fixture' && $(dns 53) == 198.18.1.1 ]]
    if [[ $redirect == true ]]; then
        nft list tables | grep -q 'table inet utabako_tun_'
        nft list chain ip filter DOCKER-USER | grep -q 'Docker compatibility'
    fi
    "$build/diagnostics" -socket "$run/normal-$redirect.sock" stop
    check_restored
    kill -TERM "$guard"
    wait "$guard"
    guard=

    start "crash-$redirect"
    ip link show utabako-test >/dev/null
    [[ $(http) == 'recovery fixture' && $(dns 53) == 198.18.1.1 ]]
    # A different process can add a rule at the same priority while TUN runs.
    ip -4 rule add pref 9001 fwmark 0x79 lookup 99 protocol 128
    worker=$(pgrep -x -P "$guard" boxdd-core)
    kill -KILL "$worker"
    status=0
    wait "$guard" || status=$?
    guard=
    if [[ $status != 137 ]]; then
        cat "$run/boxdd.log" >&2
        printf 'expected SIGKILL exit 137, got %s\n' "$status" >&2
        exit 1
    fi
    if grep -E 'delete |list owned|list nftables' "$run/boxdd.log"; then
        exit 1
    fi
    # Delete this exact third-party rule to prove it survived, then compare baseline.
    ip -4 rule del pref 9001 fwmark 0x79 lookup 99 protocol 128
    check_restored
    printf 'auto_redirect=%s: stop and SIGKILL restored routing, nftables and DNS interception\n' "$redirect"
done
CHECK
