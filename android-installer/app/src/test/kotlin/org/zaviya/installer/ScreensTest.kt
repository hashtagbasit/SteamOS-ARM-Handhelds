package org.zaviya.installer

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.zaviya.installer.device.Chip
import org.zaviya.installer.ui.Screen
import org.zaviya.installer.ui.WritePhase
import org.zaviya.installer.ui.ZaviyaScreen
import org.zaviya.installer.ui.toModel
import java.io.File

/** Renders every screen with fake state. No device needed; PNGs go to design/screens. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w960dp-h540dp-xhdpi")
class ScreensTest {
    @get:Rule val rule = createComposeRule()

    private val fakes: List<Pair<String, Screen>> = listOf(
        "chip-ok" to Screen.ChipOk(Chip.SM8650),
        "chip-unknown" to Screen.ChipUnknown("SM8450", "waipio"),
        "card-missing" to Screen.CardMissing,
        "card-small" to Screen.CardTooSmall("16 GB"),
        "card-found" to Screen.CardFound("SanDisk, 256 GB"),
        "no-image" to Screen.NoImage(Chip.SM8650),
        "image-ready" to Screen.ImageReady("1.4", 6_100_000_000),
        "lookup-failed" to Screen.LookupFailed("java.net.UnknownHostException: api.github.com", open = false),
        "downloading" to Screen.Downloading(4_200_000_000, 6_100_000_000),
        "checking-download" to Screen.CheckingDownload(0.64f),
        "write-ready" to Screen.WriteReady,
        "writing" to Screen.Writing(WritePhase.Writing, 0.42f),
        "writing-verify" to Screen.Writing(WritePhase.Verifying, 0.8f),
        "write-done" to Screen.WriteDone,
        "manual" to Screen.NeedsManual("zaviya-write.sh"),
        "backup-intro" to Screen.BackupIntro,
        "backup-running" to Screen.BackupRunning,
        "backup-done" to Screen.BackupDone("the zaviya-abl-backup folder on this device"),
        "flash-intro" to Screen.FlashIntro(Chip.SM8650),
        "flash-running" to Screen.FlashRunning,
        "ready" to Screen.Ready,
        "restore-ask" to Screen.RestoreAsk,
        "failed" to Screen.Failed("The card didn't read back correctly.", "Try another card.", "state=failed\nmessage=The card didn't read back correctly. Try another card."),
    )

    private val current = mutableStateOf<Screen>(Screen.Detecting)
    private val holdAmount = mutableStateOf(0f)

    private fun render(suffix: String) {
        rule.setContent { ZaviyaScreen(current.value.toModel(), {}, previewFocus = true, previewHold = holdAmount.value) }
        fakes.forEachIndexed { i, (name, s) ->
            current.value = s
            rule.mainClock.advanceTimeBy(600)
            rule.waitForIdle()
            rule.onRoot().captureRoboImage(File("../design/screens/%02d-%s-%s.png".format(i + 1, name, suffix)).path)
        }
    }

    private fun renderHolding(suffix: String) {
        rule.setContent { ZaviyaScreen(current.value.toModel(), {}, previewFocus = true, previewHold = 0.6f) }
        current.value = Screen.CardFound("SanDisk, 256 GB")
        rule.mainClock.advanceTimeBy(600)
        rule.waitForIdle()
        rule.onRoot().captureRoboImage(File("../design/screens/24-card-holding-$suffix.png").path)
    }

    @Test fun landscapeHolding() = renderHolding("landscape")

    @Test fun landscape() = render("landscape")

    @Test @Config(qualifiers = "w540dp-h960dp-xhdpi")
    fun portrait() = render("portrait")
}
