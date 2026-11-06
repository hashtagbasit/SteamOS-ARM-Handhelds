package org.zaviya.installer.root

import org.zaviya.installer.device.Chip

/** Builds the root job scripts from the templates in resources/scripts. */
object ScriptKit {
    /** Single-quoted for sh. */
    fun quote(s: String): String = "'" + s.replace("'", "'\\''") + "'"

    private fun template(name: String): String =
        ScriptKit::class.java.classLoader!!.getResourceAsStream("scripts/$name.sh")!!.bufferedReader().use { it.readText() }

    private val PLACEHOLDER = Regex("@[A-Z_0-9]+@")

    /** Replaces every @NAME@ with the quoted value; fails if one is left over. */
    fun fill(text: String, values: Map<String, String>): String {
        var out = text
        values.forEach { (k, v) -> out = out.replace("@$k@", quote(v)) }
        val left = PLACEHOLDER.find(out)
        check(left == null) { "Unfilled placeholder ${left?.value}" }
        return out
    }

    /** Common start of every job: prelude, then the chip check. */
    private fun head(job: String, id: String, status: String, chip: Chip, withChip: Boolean = true): String {
        val base = fill(template("prelude"), mapOf("JOB_NAME" to job, "JOB_ID" to id, "STATUS" to status))
        if (!withChip) return base
        return base + fill(template("chip"), mapOf("CHIP_MODELS" to chip.models.joinToString(" "), "CHIP_PLATFORM" to chip.platform))
    }

    data class WriteJob(
        val id: String,
        val statusFile: String,
        val chip: Chip,
        val zstd: String,
        val image: String,
        val imageSha256: String,
        val imageBytes: Long,
        val sdName: String,
        val sdBytes: Long,
        val minBytes: Long,
    )

    fun write(j: WriteJob): String = head("write", j.id, j.statusFile, j.chip) + fill(
        template("write"),
        mapOf(
            "ZSTD" to j.zstd, "IMAGE" to j.image, "IMAGE_SHA" to j.imageSha256, "IMAGE_BYTES" to j.imageBytes.toString(),
            "SD_NAME" to j.sdName, "SD_BYTES" to j.sdBytes.toString(), "MIN_BYTES" to j.minBytes.toString(),
        ),
    )

    data class AblJob(
        val id: String,
        val statusFile: String,
        val chip: Chip,
        /** The bundled boot menu file, as root sees it. */
        val elf: String,
        val backupDir: String,
        val stamp: String,
    )

    /** Saves the bootloader copies only. */
    fun backup(j: AblJob): String = abl(j, "backup")

    /** Saves the copies if needed, then writes the bundled boot menu to both slots. */
    fun flash(j: AblJob): String = abl(j, "flash")

    private fun abl(j: AblJob, mode: String): String = head(if (mode == "backup") "backup" else "flash", j.id, j.statusFile, j.chip) +
        template("slots") + fill(
            template("abl"),
            mapOf(
                "MODE" to mode, "ELF" to j.elf, "ELF_SHA" to j.chip.ablSha256, "ELF_BYTES" to j.chip.ablBytes.toString(),
                "BACKUP_DIR" to j.backupDir, "STAMP" to j.stamp,
            ),
        )

    fun restore(j: AblJob): String = head("restore", j.id, j.statusFile, j.chip) +
        template("slots") + fill(template("restore"), mapOf("BACKUP_DIR" to j.backupDir))

    /** Job name used for the script, status and launcher files. */
    fun jobName(script: String): String = Regex("JOB_NAME='([a-z]+)'").find(script)!!.groupValues[1]
}
