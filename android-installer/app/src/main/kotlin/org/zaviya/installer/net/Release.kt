package org.zaviya.installer.net

import org.json.JSONArray
import org.zaviya.installer.Config
import org.zaviya.installer.device.Chip

/** One image Zaviya can write for a chip. */
data class ImageRelease(
    val tag: String,
    val version: String,
    val assetName: String,
    val assetUrl: String,
    val assetBytes: Long,
    val sumsUrl: String,
)

object AssetNames {
    private fun regex(chip: Chip) =
        Regex("^${Config.ASSET_PREFIX}-${chip.soc.lowercase()}-(.+)${Regex.escape(Config.ASSET_SUFFIX)}$")

    /** The version in zaviya-<soc>-<version>.img.zst, or null when the name doesn't fit. */
    fun versionOf(name: String, chip: Chip): String? = regex(chip).matchEntire(name)?.groupValues?.get(1)
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
     * both an image for [chip] and a SHA256SUMS file.
     */
    fun pick(json: String, chip: Chip): ReleaseLookup {
        val releases = JSONArray(json)
        for (i in 0 until releases.length()) {
            val r = releases.getJSONObject(i)
            if (r.optBoolean("draft")) continue
            val assets = r.optJSONArray("assets") ?: continue
            var image: ImageRelease? = null
            var sums: String? = null
            for (j in 0 until assets.length()) {
                val a = assets.getJSONObject(j)
                val name = a.optString("name")
                val url = a.optString("browser_download_url")
                if (name == Config.SUMS_NAME) sums = url
                AssetNames.versionOf(name, chip)?.let { v ->
                    image = ImageRelease(r.optString("tag_name"), v, name, url, a.optLong("size"), "")
                }
            }
            val img = image
            if (img != null && sums != null) return ReleaseLookup.Found(img.copy(sumsUrl = sums))
        }
        return ReleaseLookup.NoImage
    }
}
