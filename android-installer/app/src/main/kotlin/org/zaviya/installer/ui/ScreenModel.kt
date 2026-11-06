package org.zaviya.installer.ui

import org.zaviya.installer.device.Chip
import java.util.Locale

enum class ActionId {
    Continue, Close, CheckCard, EraseCard, Download, StartWrite, SaveCopy, InstallMenu,
    AskRestore, Restore, Retry, Cancel, Details,
}

data class ActionSpec(val id: ActionId, val label: String, val hold: Boolean = false)

/** Everything one screen shows, as plain data. */
data class ScreenModel(
    val key: String,
    val statement: String,
    val detail: String? = null,
    val primary: ActionSpec? = null,
    val secondary: ActionSpec? = null,
    /** 0..1 of the current long job, or null. */
    val progress: Float? = null,
    /** Large number shown during long work, like "42%". */
    val big: String? = null,
    /** Where this screen sits in the whole flow, 0..1. */
    val position: Float = 0f,
    /** The quiet technical text behind "Details". */
    val technical: String? = null,
    val showTechnical: Boolean = false,
) {
    /** Length of the gold line: where we are, plus the job's progress inside this stretch. */
    val line: Float get() = (position + (progress ?: 0f) * SPAN).coerceIn(0f, 1f)

    companion object { const val SPAN = 0.12f }
}

enum class WritePhase { Checking, Unmounting, Writing, Verifying }

sealed interface Screen {
    data object Detecting : Screen
    data class ChipOk(val chip: Chip) : Screen
    data class ChipUnknown(val soc: String, val platform: String) : Screen
    data object CardMissing : Screen
    data class CardTooSmall(val label: String) : Screen
    data class CardRefused(val reason: String) : Screen
    data class CardFound(val label: String) : Screen
    data object Looking : Screen
    data class NoImage(val chip: Chip) : Screen
    data class ImageReady(val version: String, val bytes: Long) : Screen
    data class LookupFailed(val technical: String, val open: Boolean = false) : Screen
    data class Downloading(val done: Long, val total: Long) : Screen
    data class CheckingDownload(val fraction: Float) : Screen
    data class DownloadFailed(val technical: String, val open: Boolean = false) : Screen
    data object WriteReady : Screen
    data class Writing(val phase: WritePhase, val fraction: Float) : Screen
    data object WriteDone : Screen
    data class NeedsManual(val launcher: String) : Screen
    data object BackupIntro : Screen
    data object BackupRunning : Screen
    data class BackupDone(val folder: String) : Screen
    data class FlashIntro(val chip: Chip) : Screen
    data object FlashRunning : Screen
    data object Ready : Screen
    data object RestoreAsk : Screen
    data object RestoreRunning : Screen
    data object RestoreDone : Screen
    data class Failed(val what: String, val advice: String, val technical: String?, val open: Boolean = false, val key: String = "failed") : Screen
}

fun gb(bytes: Long): String = String.format(Locale.US, "%.1f GB", bytes / 1_000_000_000.0)
fun percent(f: Float): String = "${(f * 100).toInt().coerceIn(0, 100)}%"

fun Screen.toModel(): ScreenModel = when (this) {
    Screen.Detecting -> ScreenModel("detecting", "Checking your handheld.", position = 0.02f)
    is Screen.ChipOk -> ScreenModel("chip", "Your handheld is supported.", "${chip.label}. Zaviya has an image for it.",
        ActionSpec(ActionId.Continue, "Continue"), position = 0.05f)
    is Screen.ChipUnknown -> ScreenModel("chip-unknown", "This chip isn't supported yet.",
        "Found ${soc.ifBlank { "no chip name" }}${if (platform.isNotBlank()) " ($platform)" else ""}. Zaviya runs on Snapdragon 8 Elite, 8 Gen 3, 8 Gen 2 and 865.",
        ActionSpec(ActionId.Close, "Close"), position = 0.05f)
    Screen.CardMissing -> ScreenModel("card-missing", "Put in a microSD card.", "32 GB or bigger.",
        ActionSpec(ActionId.CheckCard, "Check again"), position = 0.12f)
    is Screen.CardTooSmall -> ScreenModel("card-small", "That card looks too small.", "This one is $label. Use 32 GB or bigger.",
        ActionSpec(ActionId.CheckCard, "Check again"), position = 0.12f)
    is Screen.CardRefused -> ScreenModel("card-refused", "That card can't be used.", reason,
        ActionSpec(ActionId.CheckCard, "Check again"), position = 0.12f)
    is Screen.CardFound -> ScreenModel("card-found", "This card will be erased.", "$label. Everything on it goes.",
        ActionSpec(ActionId.EraseCard, "Hold to erase card", hold = true), ActionSpec(ActionId.CheckCard, "Check again"), position = 0.2f)
    Screen.Looking -> ScreenModel("looking", "Looking for Zaviya.", position = 0.25f)
    is Screen.NoImage -> ScreenModel("no-image", "There's no image for this handheld yet.",
        "The newest release has no file for ${chip.label}. Try again later.", ActionSpec(ActionId.Retry, "Try again"), position = 0.25f)
    is Screen.ImageReady -> ScreenModel("image-ready", "Zaviya $version is ready.", "${gb(bytes)} to download. Wi-Fi is best.",
        ActionSpec(ActionId.Download, "Download"), position = 0.28f)
    is Screen.LookupFailed -> ScreenModel("lookup-failed", "Couldn't reach the server.", "Check your connection, then try again.",
        ActionSpec(ActionId.Retry, "Try again"), ActionSpec(ActionId.Details, "Details"), position = 0.25f, technical = technical, showTechnical = open)
    is Screen.Downloading -> (if (total > 0) done.toFloat() / total else 0f).let { f ->
        ScreenModel("downloading", "Getting Zaviya.", "${gb(done)} of ${gb(total)}. You can switch to other apps.",
            progress = f, big = percent(f), position = 0.3f)
    }
    is Screen.CheckingDownload -> ScreenModel("checking-download", "Checking the download.", "Making sure nothing is damaged.",
        progress = fraction, big = percent(fraction), position = 0.42f)
    is Screen.DownloadFailed -> ScreenModel("download-failed", "The download stopped.", "What was saved is kept. Try again to carry on.",
        ActionSpec(ActionId.Retry, "Try again"), ActionSpec(ActionId.Details, "Details"), position = 0.3f, technical = technical, showTechnical = open)
    Screen.WriteReady -> ScreenModel("write-ready", "Zaviya is ready to write.", "The card you chose will be erased now.",
        ActionSpec(ActionId.StartWrite, "Write to card"), position = 0.45f)
    is Screen.Writing -> when (phase) {
        WritePhase.Checking -> ScreenModel("writing-checking", "Checking the files.", "Keep the card in.", progress = fraction, big = percent(fraction), position = 0.46f)
        WritePhase.Unmounting -> ScreenModel("writing-unmount", "Getting the card ready.", "Keep the card in.", position = 0.5f)
        WritePhase.Writing -> ScreenModel("writing", "Writing to your card.", "About 10 minutes. Keep it in.", progress = fraction, big = percent(fraction), position = 0.5f)
        WritePhase.Verifying -> ScreenModel("writing-verify", "Checking the card.", "Reading it back to be sure.", progress = fraction, big = percent(fraction), position = 0.6f)
    }
    Screen.WriteDone -> ScreenModel("write-done", "Zaviya is on your card.", "Next, add the boot menu so you can start it.",
        ActionSpec(ActionId.Continue, "Continue"), position = 0.66f)
    is Screen.NeedsManual -> ScreenModel("manual", "Run one script as root.",
        "Open Settings, then Run Script as Root, and pick $launcher from Downloads. Then come back here.",
        secondary = ActionSpec(ActionId.Cancel, "Cancel"), position = 0.5f)
    Screen.BackupIntro -> ScreenModel("backup-intro", "Save your bootloader.", "We keep a copy so you can go back to stock. Move it off this device too.",
        ActionSpec(ActionId.SaveCopy, "Save a copy"), position = 0.7f)
    Screen.BackupRunning -> ScreenModel("backup-running", "Saving a copy.", "Checking each part against the original.", position = 0.72f)
    is Screen.BackupDone -> ScreenModel("backup-done", "Copy saved.", "It's in $folder. Move it to a PC or the cloud too.",
        ActionSpec(ActionId.Continue, "Continue"), position = 0.76f)
    is Screen.FlashIntro -> ScreenModel("flash-intro", "Add the boot menu.", "OpenABL 1.2 for ${chip.label}. Your saved copy can put things back.",
        ActionSpec(ActionId.InstallMenu, "Hold to install", hold = true), position = 0.8f)
    Screen.FlashRunning -> ScreenModel("flash-running", "Installing the boot menu.", "Keep the device on. This takes a moment.", position = 0.85f)
    Screen.Ready -> ScreenModel("ready", "You're ready.",
        "Turn off. Hold Volume Down while powering on. Set Boot mode to Linux, pick your device, then Start. Volume moves, Power selects. Volume Up starts Android.",
        ActionSpec(ActionId.Close, "Close"), ActionSpec(ActionId.AskRestore, "Restore original bootloader"), position = 1f)
    Screen.RestoreAsk -> ScreenModel("restore-ask", "Put the original bootloader back?", "Zaviya won't start from the menu after this.",
        ActionSpec(ActionId.Restore, "Hold to restore", hold = true), ActionSpec(ActionId.Cancel, "Cancel"), position = 1f)
    Screen.RestoreRunning -> ScreenModel("restore-running", "Restoring.", "Keep the device on. This takes a moment.", position = 0.9f)
    Screen.RestoreDone -> ScreenModel("restore-done", "Original bootloader restored.", "Android starts as before.",
        ActionSpec(ActionId.Close, "Close"), position = 1f)
    is Screen.Failed -> ScreenModel(key, what, advice, ActionSpec(ActionId.Retry, "Try again"),
        technical?.let { ActionSpec(ActionId.Details, "Details") }, position = 0.5f, technical = technical, showTechnical = open)
}
