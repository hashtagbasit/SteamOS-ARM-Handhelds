package org.zaviya.installer

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.zaviya.installer.device.Chip
import org.zaviya.installer.device.DeviceProps
import org.zaviya.installer.net.ImageRelease
import org.zaviya.installer.net.Network
import org.zaviya.installer.net.ReleaseLookup
import org.zaviya.installer.net.ReleaseParser
import org.zaviya.installer.net.Sha256Sums
import org.zaviya.installer.root.JobStatus
import org.zaviya.installer.root.RootRunner
import org.zaviya.installer.root.Route
import org.zaviya.installer.root.ScriptKit
import org.zaviya.installer.storage.SdCard
import org.zaviya.installer.storage.SdRules
import org.zaviya.installer.storage.SdResult
import org.zaviya.installer.storage.SdScanner
import org.zaviya.installer.ui.ActionId
import org.zaviya.installer.ui.Screen
import org.zaviya.installer.ui.WritePhase
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Holds the flow. Each screen waits for one explicit action; nothing advances by itself. */
class InstallerViewModel(app: Application) : AndroidViewModel(app) {
    private val _screen = MutableStateFlow<Screen>(Screen.Detecting)
    val screen: StateFlow<Screen> = _screen
    private val _close = MutableStateFlow(false)
    val close: StateFlow<Boolean> = _close

    private val root = RootRunner(app)
    private var chip: Chip? = null
    private var card: SdCard? = null
    private var release: ImageRelease? = null
    private var imageFile: File? = null
    private var imageSha: String? = null
    private var job: Job? = null
    private var retry: () -> Unit = {}

    init { detect() }

    private fun set(s: Screen) { _screen.value = s }

    private fun launch(block: suspend () -> Unit) {
        job?.cancel()
        job = viewModelScope.launch(Dispatchers.IO) {
            try { block() } catch (e: CancellationException) { throw e }
            catch (e: Exception) { set(Screen.Failed("Something went wrong.", "Try again. If it keeps happening, open Details.", e.toString())) }
        }
    }

    private fun detect(): Unit = launch {
        val p = DeviceProps.read()
        chip = p.chip
        set(p.chip?.let { Screen.ChipOk(it) } ?: Screen.ChipUnknown(p.socModel, p.platform))
    }

    fun onAction(id: ActionId) {
        val s = _screen.value
        when (id) {
            ActionId.Close -> _close.value = true
            ActionId.Continue -> when (s) {
                is Screen.ChipOk -> checkCard()
                Screen.WriteDone -> set(Screen.BackupIntro)
                is Screen.BackupDone -> set(Screen.FlashIntro(chip!!))
                else -> {}
            }
            ActionId.CheckCard -> checkCard()
            ActionId.EraseCard -> lookup()
            ActionId.Retry -> when (s) {
                is Screen.LookupFailed, is Screen.NoImage -> lookup()
                is Screen.DownloadFailed -> download()
                is Screen.Failed -> retry()
                else -> {}
            }
            ActionId.Download -> download()
            ActionId.StartWrite -> write()
            ActionId.SaveCopy -> abl("backup")
            ActionId.InstallMenu -> abl("flash")
            ActionId.AskRestore -> set(Screen.RestoreAsk)
            ActionId.Restore -> abl("restore")
            ActionId.Cancel -> back()
            ActionId.Details -> set(when (s) {
                is Screen.Failed -> s.copy(open = !s.open)
                is Screen.LookupFailed -> s.copy(open = !s.open)
                is Screen.DownloadFailed -> s.copy(open = !s.open)
                else -> s
            })
        }
    }

    /** B and the back key: only where nothing is running. */
    fun back() {
        when (_screen.value) {
            is Screen.CardMissing, is Screen.CardTooSmall, is Screen.CardRefused, is Screen.CardFound -> chip?.let { set(Screen.ChipOk(it)) }
            is Screen.ImageReady, is Screen.NoImage, is Screen.LookupFailed -> checkCard()
            Screen.RestoreAsk -> set(Screen.Ready)
            is Screen.NeedsManual -> { job?.cancel(); set(Screen.BackupIntro) }
            else -> {}
        }
    }

    private fun checkCard(): Unit = launch {
        set(Screen.Detecting)
        when (val r = SdScanner.find()) {
            is SdResult.Ok -> { card = r.card; set(Screen.CardFound(r.card.label)) }
            SdResult.Missing -> set(Screen.CardMissing)
            is SdResult.TooSmall -> set(Screen.CardTooSmall(SdRules.sizeLabel(r.sizeBytes)))
            is SdResult.Refused -> set(Screen.CardRefused(r.reason))
        }
    }

    private fun lookup(): Unit = launch {
        val c = chip ?: return@launch
        set(Screen.Looking)
        val json = try { Network.getText(Config.RELEASES_URL) } catch (e: Exception) {
            set(Screen.LookupFailed(e.toString())); return@launch
        }
        when (val r = ReleaseParser.pick(json, c)) {
            is ReleaseLookup.Found -> { release = r.release; set(Screen.ImageReady(r.release.version, r.release.assetBytes)) }
            ReleaseLookup.NoImage -> set(Screen.NoImage(c))
        }
    }

    private fun download(): Unit = launch {
        val rel = release ?: return@launch
        val app = getApplication<Application>()
        val running = currentCoroutineContext()
        val total = rel.assetBytes
        val percentOf = { n: Long -> if (total > 0) (n * 100 / total).toInt() else 0 }
        // Null when the job was cancelled: nobody is waiting to hear about it.
        var result: String? = null
        BackgroundDownload.start(app, DownloadProgress("Getting Zaviya.", 0))
        try {
            set(Screen.Downloading(0, total))
            val dir = File(app.getExternalFilesDir(null), "images").apply { mkdirs() }
            val dest = File(dir, rel.assetName)
            val want = try {
                Sha256Sums.parse(Network.getText(rel.sumsUrl, "text/plain"))[rel.assetName]
                    ?: throw IllegalStateException("${Config.SUMS_NAME} has no entry for ${rel.assetName}")
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { result = "The download stopped."; set(Screen.DownloadFailed(e.toString())); return@launch }
            try {
                // These loops block, so they only notice a cancel through their progress calls.
                Network.download(rel.assetUrl, dest, total) {
                    running.ensureActive()
                    set(Screen.Downloading(it, total))
                    BackgroundDownload.update(DownloadProgress("Getting Zaviya.", percentOf(it)))
                }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { result = "The download stopped."; set(Screen.DownloadFailed(e.toString())); return@launch }
            set(Screen.CheckingDownload(0f))
            val got = Network.sha256(dest) {
                running.ensureActive()
                set(Screen.CheckingDownload(it.toFloat() / total))
                BackgroundDownload.update(DownloadProgress("Checking the download.", percentOf(it)))
            }
            if (got != want) {
                dest.delete()
                result = "The download was damaged."
                set(Screen.Failed("The download was damaged.", "It has been removed. Download it again.", "expected $want\ngot      $got", key = "damaged"))
                retry = { download() }
                return@launch
            }
            imageFile = dest; imageSha = want
            result = "Zaviya is ready to write."
            set(Screen.WriteReady)
        } finally { BackgroundDownload.stop(app, result) }
    }

    private fun write(): Unit = launch {
        val c = chip!!; val sd = card!!; val img = imageFile!!; val sha = imageSha!!
        val app = getApplication<Application>()
        retry = { set(Screen.WriteReady) }
        val id = root.newId()
        val script = ScriptKit.write(ScriptKit.WriteJob(
            id, root.rootPath(root.statusFile("write")), c, File(app.applicationInfo.nativeLibraryDir, "libzstd_bin.so").path,
            root.rootPath(img), sha, img.length(), sd.name, sd.sizeBytes, Config.MIN_CARD_BYTES,
        ))
        val st = runRoot("write", id, script) { s ->
            val phase = when (s.state) {
                "unmounting" -> WritePhase.Unmounting
                "writing" -> WritePhase.Writing
                "verifying" -> WritePhase.Verifying
                else -> WritePhase.Checking
            }
            set(Screen.Writing(phase, s.fraction))
        } ?: return@launch
        if (st.state == "done") set(Screen.WriteDone) else fail(st, "Check the card and try again. Nothing else was changed.")
    }

    private fun abl(mode: String): Unit = launch {
        val c = chip!!
        val app = getApplication<Application>()
        retry = { set(when (mode) { "backup" -> Screen.BackupIntro; "flash" -> Screen.FlashIntro(c); else -> Screen.RestoreAsk }) }
        val id = root.newId()
        val elfFile = File(File(app.getExternalFilesDir(null), "abl").apply { mkdirs() }, "abl_signed-${c.soc}.elf")
        if (mode == "flash") {
            app.assets.open(c.ablAsset).use { i -> elfFile.outputStream().use { o -> i.copyTo(o) } }
            if (Network.sha256(elfFile) != c.ablSha256) { set(Screen.Failed("The boot menu file is damaged.", "Reinstall the app.", null, key = "elf")); return@launch }
        }
        val ablJob = ScriptKit.AblJob(
            id, root.rootPath(root.statusFile(mode)), c, root.rootPath(elfFile),
            "/data/media/0/${Config.BACKUP_FOLDER}", SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date()),
        )
        val script = when (mode) { "backup" -> ScriptKit.backup(ablJob); "flash" -> ScriptKit.flash(ablJob); else -> ScriptKit.restore(ablJob) }
        set(when (mode) { "backup" -> Screen.BackupRunning; "flash" -> Screen.FlashRunning; else -> Screen.RestoreRunning })
        val st = runRoot(mode, id, script) {} ?: return@launch
        if (st.state == "done") set(when (mode) {
            "backup" -> Screen.BackupDone("the ${Config.BACKUP_FOLDER} folder on this device")
            "flash" -> Screen.Ready
            else -> Screen.RestoreDone
        }) else fail(st, when (mode) {
            "backup" -> "Nothing was changed. Try again."
            else -> "Your saved copy is kept. If the device acts oddly, use Restore from the last screen."
        })
    }

    private fun fail(st: JobStatus, advice: String) {
        set(Screen.Failed(st.message.ifBlank { "That didn't work." }, advice, st.values.entries.joinToString("\n") { "${it.key}=${it.value}" }))
    }

    /**
     * Runs one root job and follows its status file. Null when the user left
     * the wait. Falls back to the saved script when no root route starts it.
     */
    private suspend fun runRoot(name: String, id: String, script: String, onStatus: (JobStatus) -> Unit): JobStatus? {
        var started = withContext(Dispatchers.IO) {
            root.prepare(name, script)
            if (root.route == Route.Manual) false else root.start(name)
        }
        var announced = false
        var sinceStart = 0
        while (true) {
            val st = root.readStatus(name, id)
            if (st != null) {
                if (announced) announced = false
                onStatus(st)
                if (st.finished) return st
                val age = System.currentTimeMillis() - root.statusFile(name).lastModified()
                if (age > 30_000) return JobStatus("failed", 0, 0, "The job stopped answering.", mapOf("state" to "stale"))
            } else if (!started || sinceStart > 12) {
                if (!announced) { announced = true; set(Screen.NeedsManual(withContext(Dispatchers.IO) { root.saveLauncher(name) })) }
            }
            sinceStart++
            delay(1000)
        }
    }
}
