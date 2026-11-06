package org.zaviya.installer.storage

import java.io.File

/** Reads the disks the system shows under /sys/block. */
object SdScanner {
    fun scan(): List<DiskInfo> {
        val mounts = runCatching { File("/proc/mounts").readText() }.getOrDefault("")
        return File("/sys/block").listFiles().orEmpty().filter { it.name.startsWith("mmcblk") || it.name.startsWith("sd") }
            .mapNotNull { d ->
                runCatching {
                    DiskInfo(
                        name = d.name,
                        sizeBytes = File(d, "size").readText().trim().toLong() * 512,
                        type = File(d, "device/type").takeIf { it.exists() }?.readText()?.trim(),
                        manfid = File(d, "device/manfid").takeIf { it.exists() }?.readText()?.trim(),
                        usedBySystem = mounts.lineSequence().any {
                            it.startsWith("/dev/block/${d.name}") && (" /mnt/expand/" in it || it.contains(" /data ") || it.contains(" / "))
                        },
                    )
                }.getOrNull()
            }
    }

    fun find(): SdResult = SdRules.validate(scan())
}
