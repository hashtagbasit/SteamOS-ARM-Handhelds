package org.zaviya.installer.root

import android.content.ContentValues
import android.content.Context
import android.os.IBinder
import android.os.Parcel
import android.provider.MediaStore
import java.io.File
import java.util.UUID

enum class Route { Xsu, Binder, Su, Manual }

/**
 * Starts the generated scripts as root and reads their status files.
 * Order of routes: /product/bin/xsu, the vendor binder service, plain su,
 * and last a saved script for the settings tool that runs scripts as root.
 */
class RootRunner(private val context: Context) {
    private val jobsDir = File(context.getExternalFilesDir(null), "jobs").apply { mkdirs() }

    val route: Route by lazy { detectRoute() }

    fun scriptFile(name: String) = File(jobsDir, "zaviya-$name.sh")
    fun statusFile(name: String) = File(jobsDir, "zaviya-$name.status")
    fun newId() = UUID.randomUUID().toString().take(12)

    /** Shared storage as root reaches it underneath Android's storage layer. */
    fun rootPath(f: File): String = f.absolutePath.replace(Regex("^/storage/emulated/0(?=/)"), "/data/media/0")

    private fun detectRoute(): Route = when {
        File(XSU).exists() && runXsu("id -u")?.trim() == "0" -> Route.Xsu
        binderRun("id -u")?.trim() == "0" -> Route.Binder
        suWorks() -> Route.Su
        else -> Route.Manual
    }

    private fun runXsu(cmd: String): String? = runCatching {
        val p = ProcessBuilder(XSU, "sh", "-c", cmd).redirectErrorStream(true).start()
        p.inputStream.bufferedReader().readText().also { p.waitFor() }
    }.getOrNull()

    private fun suWorks(): Boolean = runCatching {
        val p = ProcessBuilder("su", "-c", "id -u").redirectErrorStream(true).start()
        p.inputStream.bufferedReader().readText().trim() == "0" && p.waitFor() == 0
    }.getOrDefault(false)

    private fun binderRun(command: String): String? {
        val b: IBinder = runCatching {
            Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java)
                .invoke(null, "PServerBinder") as IBinder?
        }.getOrNull()?.takeIf { it.isBinderAlive } ?: return null
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeStringArray(arrayOf(command, "1"))
            if (b.transact(0, data, reply, 0)) String(reply.createByteArray() ?: ByteArray(0)) else null
        } catch (e: Exception) {
            null
        } finally {
            data.recycle(); reply.recycle()
        }
    }

    /** Saves the script. Returns the name of the launcher in Downloads for the manual route, else null. */
    fun prepare(name: String, script: String): String? {
        statusFile(name).delete()
        scriptFile(name).writeText(script)
        return if (route == Route.Manual) saveLauncher(name) else null
    }

    /** Starts the saved script as root. The script detaches, so this returns quickly. */
    fun start(name: String): Boolean {
        val path = ScriptKit.quote(rootPath(scriptFile(name)))
        return when (route) {
            Route.Xsu -> runXsu("sh $path") != null
            Route.Binder -> binderRun("sh $path") != null
            Route.Su -> runCatching {
                val p = ProcessBuilder("su", "-c", "sh $path").redirectErrorStream(true).start()
                p.inputStream.readBytes(); p.waitFor() == 0
            }.getOrDefault(false)
            Route.Manual -> false
        }
    }

    fun readStatus(name: String, id: String): JobStatus? =
        runCatching { JobStatus.parse(statusFile(name).readText(), id) }.getOrNull()

    fun saveLauncher(name: String): String {
        val file = "zaviya-$name.sh"
        val resolver = context.contentResolver
        val downloads = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        runCatching { resolver.delete(downloads, "${MediaStore.MediaColumns.DISPLAY_NAME} = ?", arrayOf(file)) }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, file)
            put(MediaStore.MediaColumns.MIME_TYPE, "application/x-sh")
            put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(downloads, values) ?: error("Couldn't save the script to Downloads.")
        resolver.openOutputStream(uri)!!.use { it.write("sh ${ScriptKit.quote(rootPath(scriptFile(name)))}\n".toByteArray()) }
        resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        return file
    }

    companion object {
        const val XSU = "/product/bin/xsu"
    }
}
