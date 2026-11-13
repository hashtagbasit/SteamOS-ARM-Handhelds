package org.zaviya.installer

/** Everything about where images come from, in one place. */
object Config {
    const val REPO_OWNER = "hashtagbasit"
    const val REPO_NAME = "Zaviya"

    /** Image asset name: zaviya-<soc>-<version>.img.zst, with the soc in lower case. */
    const val ASSET_PREFIX = "zaviya"
    const val ASSET_SUFFIX = ".img.zst"
    const val SUMS_NAME = "SHA256SUMS"

    /** Small manifest on the download server, tried before GitHub. */
    const val MANIFEST_URL = "https://downloads.zaviyaos.workers.dev/latest.json"

    const val RELEASES_URL = "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases?per_page=30"

    /** Many "32 GB" cards hold a little under 32 000 000 000 bytes. */
    const val MIN_CARD_BYTES = 31_000_000_000L

    /** Where the bootloader copies go, as the user sees it. */
    const val BACKUP_FOLDER = "zaviya-abl-backup"
}
