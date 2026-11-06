package org.zaviya.installer.storage

import org.zaviya.installer.Config
import kotlin.math.roundToLong

/** What the app read about one disk under /sys/block. */
data class DiskInfo(
    val name: String,
    val sizeBytes: Long,
    /** Contents of device/type: "SD" for a microSD card, "MMC" for built-in eMMC. */
    val type: String?,
    /** Manufacturer id from device/manfid, e.g. "0x000003". */
    val manfid: String? = null,
    /** True when the card's partitions are mounted as the system's own storage. */
    val usedBySystem: Boolean = false,
)

/** The card the app will offer to erase. */
data class SdCard(val name: String, val sizeBytes: Long, val maker: String?) {
    val devicePath get() = "/dev/block/$name"
    val label get() = listOfNotNull(maker, SdRules.sizeLabel(sizeBytes)).joinToString(", ")
}

sealed interface SdResult {
    data class Ok(val card: SdCard) : SdResult
    data object Missing : SdResult
    data class TooSmall(val sizeBytes: Long) : SdResult
    /** Not a removable card: built-in storage, a partition, or in use by Android. */
    data class Refused(val reason: String) : SdResult
}

object SdRules {
    private val CARD_NAME = Regex("^mmcblk[0-9]+$")

    /** Only a whole mmcblk disk of type SD qualifies. Built-in storage never does. */
    fun validate(disks: List<DiskInfo>, minBytes: Long = Config.MIN_CARD_BYTES): SdResult {
        val sd = disks.filter { it.type.equals("SD", ignoreCase = true) }
        if (sd.isEmpty()) return SdResult.Missing
        val disk = sd.firstOrNull { CARD_NAME.matches(it.name) }
            ?: return SdResult.Refused("${sd.first().name} is not a whole card.")
        if (disk.usedBySystem) return SdResult.Refused("Android is using this card as part of its own storage.")
        if (disk.sizeBytes < minBytes) return SdResult.TooSmall(disk.sizeBytes)
        return SdResult.Ok(SdCard(disk.name, disk.sizeBytes, makerName(disk.manfid)))
    }

    /** True only for the verified card's own device path. */
    fun isTargetAllowed(path: String, verified: SdCard): Boolean =
        path == verified.devicePath && CARD_NAME.matches(path.removePrefix("/dev/block/"))

    /** Paths that can never be a target, whatever else is true. */
    fun isInternalPath(path: String): Boolean {
        val p = path.trim()
        if (p.contains("by-name") || p.contains("..")) return true
        val name = p.substringAfterLast('/')
        if (!p.startsWith("/dev/block/")) return true
        return !CARD_NAME.matches(name)
    }

    /** "32 GB", "256 GB": the size the card is sold as. */
    fun sizeLabel(bytes: Long): String {
        val gb = bytes / 1_000_000_000.0
        for (sold in listOf(8, 16, 32, 64, 128, 256, 512, 1024)) {
            if (gb <= sold && gb >= sold * 0.9) return if (sold == 1024) "1 TB" else "$sold GB"
        }
        return "${gb.roundToLong()} GB"
    }

    fun makerName(manfid: String?): String? {
        val id = manfid?.trim()?.removePrefix("0x")?.toIntOrNull(16) ?: return null
        return when (id) {
            0x03 -> "SanDisk"
            0x1b -> "Samsung"
            0x1d -> "ADATA"
            0x27 -> "Phison"
            0x28 -> "Lexar"
            0x41 -> "Kingston"
            0x6f -> "Silicon Motion"
            0x74 -> "Transcend"
            else -> null
        }
    }
}
