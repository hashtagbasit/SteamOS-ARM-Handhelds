package org.zaviya.installer.device

/** The chips Zaviya has an image and a boot menu for. */
enum class Chip(
    val soc: String,
    val platform: String,
    /** Values of ro.soc.model that belong to this chip. */
    val models: List<String>,
    val label: String,
    /** SHA-256 and size of the bundled OpenABL 1.2 file. */
    val ablSha256: String,
    val ablBytes: Long,
) {
    SM8650("SM8650", "pineapple", listOf("SM8650"), "Snapdragon 8 Gen 3",
        "303e389b1e3909074b42415276872c3fc0dcc997200918b4d055fd264b0736dc", 532480),
    SM8550("SM8550", "kalama", listOf("SM8550", "QCS8550"), "Snapdragon 8 Gen 2",
        "2a2808d12f2d494ddd2c39093bbffa90bc43402050be1a87baf6a4c37c830163", 532480),
    SM8750("SM8750", "sun", listOf("SM8750", "CQ8725S"), "Snapdragon 8 Elite",
        "0dba7b90d1a36e13977c00fec87f4f5ccc8f49b98864ad495a1ed04d35e33c3a", 532480),
    SM8250("SM8250", "kona", listOf("SM8250"), "Snapdragon 865",
        "628dbff74f5b570b897c14725f2c36ff2ca5fe018998e2c248a3d15d906ccef9", 532480);

    val ablAsset get() = "openabl/abl_signed-$soc.elf"

    companion object {
        /**
         * The chip for the two system properties, or null when they name no
         * supported chip, or two different ones.
         */
        fun identify(socModel: String, platform: String): Chip? {
            val byModel = entries.firstOrNull { c -> c.models.any { it.equals(socModel.trim(), true) } }
            val byPlatform = entries.firstOrNull { it.platform.equals(platform.trim(), true) }
            return when {
                byModel != null && byPlatform != null && byModel != byPlatform -> null
                else -> byModel ?: byPlatform
            }
        }
    }
}
