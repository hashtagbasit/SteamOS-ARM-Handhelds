# Internal UFS boot (OpenABL dual-boot)

**One `KERNEL` file** — same bootimg on microSD `/boot` and on the UFS `boot` partition (`cp -a /flash/.` with no cmdline patch).

## How it works

| Piece | Role |
|-------|------|
| `boot/KERNEL` cmdline | `root=UUID=<SD>` + `masi.ufsroot=PARTLABEL=STORAGE` (after `update.sh`) |
| initramfs `masi-dual-root` | Runs in **init-premount** (before root wait): SD → UUID; UFS → STORAGE |
| `install-to-internal.sh` | `cp /boot/KERNEL` → `boot/KERNEL` (no `abootimg`) |
| `update.sh` | Repacks KERNEL with this device's `masi.sdroot`, syncs it to the internal boot partition if present |

## Build and install

```bash
cd ~/Projects/Kernel_Zaviya
./make.sh
sudo ./update.sh          # embeds masi.sdroot=UUID= for this microSD
sudo install-to-internal.sh  # copies same KERNEL to boot
```

Kernel updates on an existing UFS install:

```bash
sudo ./update.sh            # updates /boot/KERNEL and boot/KERNEL
```

## Scripts (installed by `update.sh`)

```bash
sudo install-to-internal.sh
sudo install-to-internal.sh --deploy-only   # partitions exist, copy only
sudo masi-ufs-diagnose
sudo /usr/lib/masi/ufs-linux/ufs-fix-internal-boot.sh   # rescue only
```

**Do not** use an old `~/Desktop/ufs-Linux` copy — run `sudo ./update.sh` to install matching scripts.

## Internal boot with microSD inserted

If both SD and UFS layouts exist, prefer **removing the SD card** for the first internal Linux boot test.

If the SD must stay in: add `masi.root=ufs` to the kernel cmdline (advanced) or remove SD when booting internal Linux.

## Troubleshooting

**`bad config entry` / `Failed to patch KERNEL`?**  
You are on an **old installer** that patched cmdline at install time. Fix:

```bash
cd ~/Projects/Kernel_Zaviya && ./make.sh && sudo ./update.sh
sudo install-to-internal.sh --deploy-only
```

**Black screen booting internal Linux?**  
Old KERNEL still had `root=UUID=<SD>` only. Rebuild + `update.sh`, then `--deploy-only` or `ufs-fix-internal-boot.sh`.
