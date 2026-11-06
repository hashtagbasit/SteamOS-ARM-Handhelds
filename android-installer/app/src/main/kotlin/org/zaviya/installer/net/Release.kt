package org.zaviya.installer.net

import org.json.JSONArray
import org.zaviya.installer.Config
import org.zaviya.installer.device.Chip

/** One file of an image. GitHub caps release files at 2 GiB, so an image is usually several. */
data class ImagePart(val url: String, val bytes: Long)

/** One image Zaviya can write for a chip. [assetName] is the joined file, the name SHA256SUMS lists. */
data class ImageRelease(
    val tag: String,
    val version: String,
    val assetName: String,
    val parts: List<ImagePart>,
    val sumsUrl: String,
) {
    val assetBytes: Long get() = parts.sumOf { it.bytes }
}

object AssetNames {
    private fun regex(chip: Chip) =
        Regex("^${Config.ASSET_PREFIX}-${chip.soc.lowercase()}-(.+)${Regex.escape(Config.ASSET_SUFFIX)}(?:\\.(\\d{3}))?$")

    /** The version in zaviya-<soc>-<version>.img.zst[.NNN], or null when the name doesn't fit. */
    fun versionOf(name: String, chip: Chip): String? = regex(chip).matchEntire(name)?.groupValues?.get(1)

    /** The part number in a split name, or null for a whole file. */
    fun partOf(name: String, chip: Chip): Int? = regex(chip).matchEntire(name)?.groupValues?.get(2)?.toIntOrNull()

    /** The name with any part number removed. */
    fun joined(name: String): String = name.replace(Regex("\\.\\d{3}$"), "")
}

object Sha256Sums {
    private val LINE = Regex("^([0-9a-fA-F]{64})\\s+[*]?(?:\\./)?(.+?)\\s*$")

    /** file name to lower-case hash, from the lines of a sha256sum file. */
    fun parse(text: String): Map<String, String> = text.lineSequence()
        .mapNotNull { LINE.matchEntire(it.trim())?.destructured }
        .associate { (hash, name) -> name to hash.lowercase() }
}

sealed interface ReleaseLookup {
    data class Found(val release: ImageRelease) : ReleaseLookup
    data object NoImage : ReleaseLookup
}

object ReleaseParser {
    /**
     * Picks the newest published release (the API lists newest first) that has
     * both a complete image for [chip] and a SHA256SUMS file. A release still
     * missing a part is passed over, as during an upload.
     */
    fun pick(json: String, chip: Chip): ReleaseLookup {
        val releases = JSONArray(json)
        for (i in 0 until releases.length()) {
            val r = releases.getJSONObject(i)
            if (r.optBoolean("draft")) continue
            val assets = r.optJSONArray("assets") ?: continue
            var sums: String? = null
            var version: String? = null
            var name: String? = null
            var whole: ImagePart? = null
            val numbered = sortedMapOf<Int, ImagePart>()
            for (j in 0 until assets.length()) {
                val a = assets.getJSONObject(j)
                val assetName = a.optString("name")
                val part = ImagePart(a.optString("browser_download_url"), a.optLong("size"))
                if (assetName == Config.SUMS_NAME) sums = part.url
                val v = AssetNames.versionOf(assetName, chip) ?: continue
                version = v
                name = AssetNames.joined(assetName)
                val n = AssetNames.partOf(assetName, chip)
                if (n == null) whole = part else numbered[n] = part
            }
            val parts = whole?.let { listOf(it) }
                ?: numbered.takeIf { it.isNotEmpty() && it.keys.toList() == (1..it.size).toList() }?.values?.toList()
            if (parts != null && sums != null) {
                return ReleaseLookup.Found(ImageRelease(r.optString("tag_name"), version!!, name!!, parts, sums!!))
            }
        }
        return ReleaseLookup.NoImage
    }
}
