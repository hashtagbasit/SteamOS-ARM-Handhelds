#!/usr/bin/env bash
# Vulkan layer that retries swapchain acquire timeouts in Steam's webhelper,
# so a wait that expired during sleep does not kill its GPU process. Called by
# each apply-overlays script.
#   install-webhelper-acquire-layer.sh <rootfs>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
R="${1:?rootfs}"
SRC="${ROOT}/external-and-mods/webhelper-acquire-layer"
VKINC="${ROOT}/external-and-mods/gamescope/src/reshade/deps/vulkan/include"
SO="$R/usr/lib/steamos-arm/libVkLayer_webhelper_acquire.so"
[[ "$(uname -m)" == aarch64 ]] || { echo "install-webhelper-acquire-layer: needs an aarch64 build host" >&2; exit 1; }

mkdir -p "$R/usr/lib/steamos-arm"
gcc -std=gnu11 -O2 -Wall -Wextra -shared -fPIC -fvisibility=hidden -I"$VKINC" \
  "$SRC/webhelper_acquire_layer.c" -o "$SO"
chmod 0755 "$SO"
install -D -m0644 "$SRC/VkLayer_webhelper_acquire.json" \
  "$R/usr/share/vulkan/implicit_layer.d/VkLayer_webhelper_acquire.json"

# Only libc and the loader, so it loads inside any image.
needed="$(readelf -d "$SO" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | sort -u | tr '\n' ' ')"
[[ "$needed" == "ld-linux-aarch64.so.1 libc.so.6 " ]] || { echo "install-webhelper-acquire-layer: unexpected NEEDED: $needed" >&2; exit 1; }
echo "webhelper acquire layer installed"
