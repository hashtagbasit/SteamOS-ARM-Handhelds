package org.zaviya.installer.device

data class DeviceProps(val socModel: String, val platform: String, val maker: String, val model: String) {
    val chip: Chip? get() = Chip.identify(socModel, platform)

    companion object {
        fun read(): DeviceProps = DeviceProps(
            prop("ro.soc.model"), prop("ro.board.platform"),
            android.os.Build.MANUFACTURER.orEmpty(), android.os.Build.MODEL.orEmpty(),
        )

        private fun prop(key: String): String = runCatching {
            val p = ProcessBuilder("getprop", key).redirectErrorStream(true).start()
            p.inputStream.bufferedReader().readText().trim().also { p.waitFor() }
        }.getOrDefault("")
    }
}
