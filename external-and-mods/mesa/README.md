# Mesa for 8 Gen 2 (Adreno 740)

The Frame image ships its own Mesa (26.3.0-devel, a private commit). The
Frame is an Adreno 750, so that build doesn't carry the fixes the Adreno 740
needs, and on 8 Gen 2 devices nothing gets on screen. The 8 Gen 2 image
replaces the whole Mesa stack with this one instead, built from Mesa 26.2.6:

- `aarch64`: the system Mesa (Turnip for Vulkan, zink for GL, EGL, GLX, GBM)
- `x86_64` and `i386`: the Mesa that x86 games see under FEX
  (`/usr/share/guestos/fex-mesa`)

Same drivers as the Frame's build, all built together, so zink and Turnip always
match. The 8 Gen 3 image keeps the Frame's Mesa.

## Patches

| Patch | Why |
|---|---|
| `0001-turnip-a740-disable-sparse-sync.patch` | A740 GPU translation fault storms from the graphics/sparse queue cross sync added in Mesa `0cc0e786` |
| `0002-ir3-a740-disable-bindless-ubo-const-lowering.patch` | ir3 shader bug on the A740 |
| `0004-tu-z-mutable-ubwc.patch` | Keeps mutable images tiled with UBWC on A740. `TU_Z_MUTABLE=0` restores upstream |
| `0005-tu-z-mutable-ubwc-copy-format.patch` | Copies use the written format: black or white overlays and water |
| `0006-ir3-array-to-ssa-resolve-trivial-phi-chains.patch` | Shader compile crash in Enshrouded and Onimusha |

Build: `scripts/build-mesa.sh` (all three architectures).
