package org.zaviya.installer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.zaviya.installer.device.Chip
import org.zaviya.installer.root.ScriptKit
import java.io.File

class ScriptsTest {
    private val write = ScriptKit.write(ScriptKit.WriteJob(
        "id1", "/data/media/0/x/status", Chip.SM8650, "/data/app/lib/libzstd_bin.so", "/data/media/0/x/img it's.zst",
        "a".repeat(64), 1234, "mmcblk1", 256_000_000_000, 31_000_000_000,
    ))
    private val job = ScriptKit.AblJob("id2", "/data/media/0/x/status", Chip.SM8650, "/data/media/0/x/abl.elf", "/data/media/0/zaviya-abl-backup", "20261106-120000")
    private val flash = ScriptKit.flash(job)
    private val backup = ScriptKit.backup(job)
    private val restore = ScriptKit.restore(job)

    private fun syntaxOk(script: String) {
        val bash = File("/bin/bash")
        assumeTrue(bash.exists())
        val f = File.createTempFile("zaviya", ".sh").apply { writeText(script); deleteOnExit() }
        val p = ProcessBuilder("/bin/bash", "-n", f.path).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText()
        assertEquals(out, 0, p.waitFor())
    }

    @Test fun everyScriptStopsOnWrongChip() {
        listOf(write, flash, backup, restore).forEach {
            assertTrue(it.contains("getprop ro.soc.model"))
            assertTrue(it.contains("CHIP_MODELS='SM8650'"))
            assertTrue(it.contains("CHIP_PLATFORM='pineapple'"))
            assertTrue(it.contains("check_chip\n"))
        }
    }
    @Test fun scriptsUseSetEAndDetach() {
        listOf(write, flash, backup, restore).forEach {
            assertTrue(it.contains("set -e"))
            assertTrue(it.contains("nohup sh"))
            assertTrue(it.contains("wake_lock"))
        }
    }
    @Test fun writeReadsBackAndComparesHash() {
        assertTrue(write.contains("head -c \"\$RAW_BYTES\" \"\$TARGET\" | sha256sum"))
        assertTrue(write.contains("\"\$RAW_SHA\" ] || fail \"The card didn't read back correctly"))
        assertTrue(write.contains("expr \"\$(cat \"/sys/block/\$DEV/size\")\""))
        assertTrue(write.contains("grep -Eq '^mmcblk[0-9]+\$'"))
        assertTrue(write.contains("TARGET=/dev/block/\$DEV"))
        assertTrue(write.contains("SD_BYTES='256000000000'"))
    }
    @Test fun pathsAreQuoted() {
        assertTrue(write.contains("IMG='/data/media/0/x/img it'\\''s.zst'"))
    }
    @Test fun flashChecksVerifiesBothSlotsAndHash() {
        assertTrue(flash.contains("MODE='flash'"))
        assertTrue(flash.contains("ELF_SHA='${Chip.SM8650.ablSha256}'"))
        assertTrue(flash.contains("abl_a") && flash.contains("abl_b"))
        assertTrue(flash.contains("shan \"\$ws_dev\" \"\$ELF_BYTES\"") )
        assertTrue(flash.contains("[ -s \"\$BK/abl_\$s.img\" ]"))
        assertTrue(flash.contains("matches the partition") || flash.contains("doesn't match the partition"))
        assertTrue(flash.contains("slot_order"))
    }
    @Test fun backupModeNeverWritesPartitions() {
        assertTrue(backup.contains("MODE='backup'"))
        assertTrue(backup.contains("[ \"\$MODE\" = backup ]"))
    }
    @Test fun restoreChecksBackupBeforeWriting() {
        assertTrue(restore.indexOf("sha256sum -c SHA256SUMS") < restore.indexOf("of=\"\$(part \$s)\""))
        assertTrue(restore.contains("soc="))
    }
    @Test fun noPlaceholdersLeft() {
        listOf(write, flash, backup, restore).forEach { assertFalse(Regex("@[A-Z_]+@").containsMatchIn(it)) }
    }
    @Test fun syntaxIsValid() = listOf(write, flash, backup, restore).forEach(::syntaxOk)
    @Test fun quoteEscapes() = assertEquals("'a'\\''b'", ScriptKit.quote("a'b"))
}
