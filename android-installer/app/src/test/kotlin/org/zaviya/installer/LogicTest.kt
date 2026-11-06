package org.zaviya.installer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.zaviya.installer.device.Chip
import org.zaviya.installer.net.AssetNames
import org.zaviya.installer.net.ReleaseLookup
import org.zaviya.installer.net.ReleaseParser
import org.zaviya.installer.net.Sha256Sums
import org.zaviya.installer.root.JobStatus
import org.zaviya.installer.storage.DiskInfo
import org.zaviya.installer.storage.SdCard
import org.zaviya.installer.storage.SdResult
import org.zaviya.installer.storage.SdRules

class ChipTest {
    @Test fun mapsEachSupportedChip() {
        assertEquals(Chip.SM8650, Chip.identify("SM8650", "pineapple"))
        assertEquals(Chip.SM8550, Chip.identify("SM8550", "kalama"))
        assertEquals(Chip.SM8750, Chip.identify("SM8750", "sun"))
        assertEquals(Chip.SM8250, Chip.identify("SM8250", "kona"))
    }
    @Test fun platformAloneIsEnough() = assertEquals(Chip.SM8650, Chip.identify("", "pineapple"))
    @Test fun aliasModels() {
        assertEquals(Chip.SM8550, Chip.identify("QCS8550", ""))
        assertEquals(Chip.SM8750, Chip.identify("CQ8725S", "sun"))
    }
    @Test fun unknownChipIsNull() {
        assertNull(Chip.identify("SM8450", "waipio"))
        assertNull(Chip.identify("", ""))
    }
    @Test fun disagreeingPropertiesAreRefused() = assertNull(Chip.identify("SM8650", "kalama"))
    @Test fun pinnedHashesAreNotEmpty() = Chip.entries.forEach { assertEquals(64, it.ablSha256.length) }
}

class ReleaseTest {
    @Test fun assetNameParsing() {
        assertEquals("1.4", AssetNames.versionOf("zaviya-sm8650-1.4.img.zst", Chip.SM8650))
        assertEquals("1.5-rc1", AssetNames.versionOf("zaviya-sm8550-1.5-rc1.img.zst", Chip.SM8550))
        assertNull(AssetNames.versionOf("zaviya-sm8550-1.4.img.zst", Chip.SM8650))
        assertNull(AssetNames.versionOf("zaviya-sm8650-1.4.img.zst.sig", Chip.SM8650))
        assertNull(AssetNames.versionOf("other-sm8650-1.4.img.zst", Chip.SM8650))
    }

    @Test fun sumsParsing() {
        val h1 = "a".repeat(64); val h2 = "B".repeat(64)
        val m = Sha256Sums.parse("$h1  zaviya-sm8650-1.4.img.zst\n$h2 *./zaviya-sm8550-1.4.img.zst\nnot a line\n")
        assertEquals(h1, m["zaviya-sm8650-1.4.img.zst"])
        assertEquals("b".repeat(64), m["zaviya-sm8550-1.4.img.zst"])
        assertEquals(2, m.size)
    }

    private fun release(tag: String, vararg assets: String, draft: Boolean = false) =
        """{"tag_name":"$tag","draft":$draft,"assets":[${assets.joinToString(",") { """{"name":"$it","size":100,"browser_download_url":"https://x/$tag/$it"}""" }}]}"""

    @Test fun picksNewestReleaseWithImageAndSums() {
        val json = "[" + listOf(
            release("v1.5", "SHA256SUMS", "zaviya-sm8550-1.5.img.zst"),
            release("v1.4", "SHA256SUMS", "zaviya-sm8650-1.4.img.zst"),
            release("v1.3", "SHA256SUMS", "zaviya-sm8650-1.3.img.zst"),
        ).joinToString(",") + "]"
        val r = (ReleaseParser.pick(json, Chip.SM8650) as ReleaseLookup.Found).release
        assertEquals("1.4", r.version)
        assertEquals("https://x/v1.4/SHA256SUMS", r.sumsUrl)
    }

    @Test fun noMatchingImage() {
        val json = "[" + release("v1.4", "SHA256SUMS", "zaviya-sm8550-1.4.img.zst") + "]"
        assertEquals(ReleaseLookup.NoImage, ReleaseParser.pick(json, Chip.SM8650))
        assertEquals(ReleaseLookup.NoImage, ReleaseParser.pick("[]", Chip.SM8650))
    }

    @Test fun skipsDraftsAndReleasesWithoutSums() {
        val json = "[" + listOf(
            release("v2", "SHA256SUMS", "zaviya-sm8650-2.0.img.zst", draft = true),
            release("v1.9", "zaviya-sm8650-1.9.img.zst"),
        ).joinToString(",") + "]"
        assertEquals(ReleaseLookup.NoImage, ReleaseParser.pick(json, Chip.SM8650))
    }

    @Test fun partNames() {
        assertEquals("1.5.0", AssetNames.versionOf("zaviya-sm8650-1.5.0.img.zst.002", Chip.SM8650))
        assertEquals(2, AssetNames.partOf("zaviya-sm8650-1.5.0.img.zst.002", Chip.SM8650))
        assertNull(AssetNames.partOf("zaviya-sm8650-1.5.0.img.zst", Chip.SM8650))
        assertEquals("zaviya-sm8650-1.5.0.img.zst", AssetNames.joined("zaviya-sm8650-1.5.0.img.zst.002"))
        assertNull(AssetNames.versionOf("zaviya-sm8650-1.5.0.7z.001", Chip.SM8650))
    }

    @Test fun joinsPartsInOrderWhateverOrderTheyAreListed() {
        val json = "[" + release("v1.5", "SHA256SUMS", "zaviya-sm8650-1.5.0.img.zst.002", "zaviya-sm8650-1.5.0.img.zst.001", "zaviya-sm8650-1.5.0.7z.001") + "]"
        val r = (ReleaseParser.pick(json, Chip.SM8650) as ReleaseLookup.Found).release
        assertEquals("1.5.0", r.version)
        assertEquals("zaviya-sm8650-1.5.0.img.zst", r.assetName)
        assertEquals(listOf("001", "002"), r.parts.map { it.url.takeLast(3) })
        assertEquals(200L, r.assetBytes)
    }

    @Test fun releaseMissingAPartIsPassedOver() {
        val json = "[" + listOf(
            release("v1.5", "SHA256SUMS", "zaviya-sm8650-1.5.img.zst.001", "zaviya-sm8650-1.5.img.zst.003"),
            release("v1.4", "SHA256SUMS", "zaviya-sm8650-1.4.img.zst"),
        ).joinToString(",") + "]"
        assertEquals("1.4", (ReleaseParser.pick(json, Chip.SM8650) as ReleaseLookup.Found).release.version)
    }
}

class SdRulesTest {
    private val gb = 1_000_000_000L
    private val internal = DiskInfo("mmcblk0", 128 * gb, "MMC")
    private val ufs = DiskInfo("sda", 256 * gb, null)
    private val sd = DiskInfo("mmcblk1", 256 * gb, "SD", "0x000003")

    @Test fun acceptsTheCard() {
        val r = SdRules.validate(listOf(internal, ufs, sd)) as SdResult.Ok
        assertEquals("mmcblk1", r.card.name)
        assertEquals("SanDisk, 256 GB", r.card.label)
    }
    @Test fun builtInStorageIsNeverOffered() {
        assertEquals(SdResult.Missing, SdRules.validate(listOf(internal, ufs)))
        assertEquals(SdResult.Missing, SdRules.validate(emptyList()))
    }
    @Test fun partitionsAreRefused() {
        assertTrue(SdRules.validate(listOf(DiskInfo("mmcblk1p1", 256 * gb, "SD"))) is SdResult.Refused)
    }
    @Test fun smallCardIsRefused() {
        assertTrue(SdRules.validate(listOf(sd.copy(sizeBytes = 16 * gb))) is SdResult.TooSmall)
        assertTrue(SdRules.validate(listOf(sd.copy(sizeBytes = 31_900_000_000))) is SdResult.Ok)
    }
    @Test fun cardUsedAsInternalStorageIsRefused() {
        assertTrue(SdRules.validate(listOf(sd.copy(usedBySystem = true))) is SdResult.Refused)
    }
    @Test fun internalPathsAreRefused() {
        listOf("/dev/block/mmcblk0", "/dev/block/sda", "/dev/block/by-name/abl_a", "/dev/block/mmcblk1p1",
            "/dev/block/../mmcblk1", "/sdcard", "mmcblk1", "/dev/block/dm-0", "/data/media/0")
            .forEach { assertTrue(it, SdRules.isInternalPath(it) || it.endsWith("mmcblk0")) }
        assertTrue(SdRules.isInternalPath("/dev/block/by-name/userdata"))
        assertTrue(!SdRules.isInternalPath("/dev/block/mmcblk1"))
    }
    @Test fun targetMustBeTheVerifiedCard() {
        val card = SdCard("mmcblk1", 256 * gb, null)
        assertTrue(SdRules.isTargetAllowed("/dev/block/mmcblk1", card))
        assertTrue(!SdRules.isTargetAllowed("/dev/block/mmcblk0", card))
        assertTrue(!SdRules.isTargetAllowed("/dev/block/by-name/userdata", card))
        assertTrue(!SdRules.isTargetAllowed("/dev/block/mmcblk1p1", card))
    }
    @Test fun sizeLabels() {
        assertEquals("32 GB", SdRules.sizeLabel(31_900_000_000))
        assertEquals("64 GB", SdRules.sizeLabel(63_864_569_856))
        assertEquals("256 GB", SdRules.sizeLabel(255_000_000_000))
    }
}

class JobStatusTest {
    @Test fun parsesAndMatchesTheJob() {
        val text = "job=abc\nstate=writing\ndone=50\ntotal=200\nmessage=\nbackup=new\n"
        val s = JobStatus.parse(text, "abc")!!
        assertEquals("writing", s.state)
        assertEquals(0.25f, s.fraction, 0.001f)
        assertEquals("new", s.values["backup"])
        assertNull(JobStatus.parse(text, "other"))
        assertNotNull(JobStatus.parse("job=abc\nstate=done\n", "abc")!!.takeIf { it.finished })
    }
}
