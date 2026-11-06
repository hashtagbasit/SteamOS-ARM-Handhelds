# Offline Zaviya updates

This updater is under verification for v1.2. It must not be advertised as release-ready until the boot-hook and hardware gates in `docs/V1.2-VERIFICATION.md` pass.

## How it works

1. In Desktop Mode, open **Zaviya Update** in ARM-Manager. Select the update package and paste its SHA-256 from the official GitHub release.
2. Preparation checks the archive, hashes every payload file, checks available space, and copies a private recovery runtime to HOME. It saves the current boot image and installs the recovery-capable bootstrap.
3. On restart, the initramfs mounts the same root, boot, and HOME filesystems. It verifies their UUIDs and takes a rollback copy before replacing system files.
4. It updates the system and the two bundled Decky plugins, verifies installed content, then boots Zaviya. Games, ROMs, saves, Steam account files, Decky settings, accounts, network credentials, and fstab are preserved.
5. An interrupted apply or rollback is recovered on the next boot. A failed apply restores the backup and reboots into the previous kernel. If recovery itself cannot finish, normal boot is stopped and its log is left on HOME.

No partition table is changed and no filesystem is formatted. Both SD and internal installs use the same process. HOME needs enough free space for the unpacked update and a copy of the current system; the root partition must also fit the new system. Existing backups are retained.

## Payload and trust

Packages contain only the managed system directories, boot image, and bundled Decky plugins. They contain no proprietary Lossless Scaling DLL, game data, Steam accounts, or SSH keys. The expected package hash must come from the official release. A local checksum proves integrity; it does not authenticate an untrusted download.

The old 1.x LSFG layer manifests are removed. LSFG v2 requires the official `lsfg-vk` Steam branch DLL; the Decky plugin guides its setup. Updating the OS does not reset or replace Steam game installations.

## Diagnostics and recovery

Transaction data and logs are under `/home/.konkr-updates/<id>/`, accessible to root. Keep the working microSD as a recovery option for an internal install. A recovery error must be investigated before deleting the pending marker or backup.

From a recovery SD, mount the affected root, boot, and HOME partitions and run the same helper as root with the corresponding paths:

```
python3 /usr/share/konkr-update/konkr-update.py recover \
  --root /mnt/root --boot /mnt/boot --home /mnt/home \
  --work /mnt/home/.konkr-updates/<id>
```

A return code of 10 means rollback completed: reboot into the restored boot image. A nonzero error leaves the pending transaction and backup intact.

The fault-injection tests exercise recovery state transitions and preservation. They do not establish immunity to storage hardware failure or every possible power-loss timing.
