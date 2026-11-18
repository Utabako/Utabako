#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
output="$root/build/linux-tun"
cache="$root/.dart_tool/libbox"
source_dir="$cache/source"
spec="$root/tool/libbox.json"
commit=$(jq -r .commit "$spec")
repository=$(jq -r .repository "$spec")
version=$(jq -r .version "$spec")
tags=$(jq -r '.tags | join(",")' "$spec")

mkdir -p "$output/client" "$cache/tmp"
export GOTOOLCHAIN=local GOWORK=off CGO_ENABLED=1
export GOPATH="$cache/go" GOMODCACHE="$cache/go/pkg/mod" GOCACHE="$cache/go-build" GOTMPDIR="$cache/tmp"
required_go=$(jq -r .go_version "$spec")
if [[ $(go env GOVERSION) != "$required_go" ]]; then
    printf 'Linux core requires %s\n' "$required_go" >&2
    exit 1
fi

if [[ ! -d "$source_dir/.git" ]]; then
    git init -q "$source_dir"
fi
if ! git -C "$source_dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
    git -C "$source_dir" fetch --depth=1 "$repository" "$commit"
fi
if [[ -n $(git -C "$source_dir" status --porcelain) ]]; then
    printf 'Core source has local changes: %s\n' "$source_dir" >&2
    exit 1
fi
if [[ $(git -C "$source_dir" rev-parse --verify HEAD 2>/dev/null || true) != "$commit" ]]; then
    git -C "$source_dir" checkout --detach "$commit"
fi

cd "$source_dir"
python3 "$root/tool/linux_tun/recovery_overlay.py" "$output/overlay"
overlay="$output/overlay/overlay.json"
ldflags="-X github.com/sagernet/sing-box/constant.Version=$version -checklinkname=0"
go build -modfile "$output/overlay/recovery.mod" -overlay "$overlay" -mod=readonly -trimpath -buildvcs=false -ldflags "$ldflags" -tags "$tags" -o "$output/boxdd-core" ./experimental/boxdd
go build -modfile "$output/overlay/recovery.mod" -mod=readonly -trimpath -buildvcs=false -o "$output/boxdd" "$root/tool/linux_tun/supervisor.go"
cp "$root/tool/linux_tun/main.go" experimental/boxdd/desktop_service{,_grpc}.pb.go "$output/client/"
go build -mod=readonly -trimpath -buildvcs=false -o "$output/diagnostics" "$output/client/"*.go

cd "$root/tool/diagnostics_preview"
fvm flutter pub get --enforce-lockfile
fvm flutter build web --no-pub --no-wasm-dry-run --no-web-resources-cdn \
    --dart-define=UTABAKO_LIVE=true --output "$output/web"
