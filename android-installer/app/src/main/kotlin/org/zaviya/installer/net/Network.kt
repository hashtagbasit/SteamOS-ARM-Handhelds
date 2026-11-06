package org.zaviya.installer.net

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

object Network {
    private const val AGENT = "ZaviyaInstaller/0.1"

    private fun open(url: String): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15_000
            readTimeout = 30_000
            setRequestProperty("User-Agent", AGENT)
            instanceFollowRedirects = true
        }

    fun getText(url: String, accept: String = "application/json"): String {
        val c = open(url)
        c.setRequestProperty("Accept", accept)
        try {
            if (c.responseCode !in 200..299) throw IOException("HTTP ${c.responseCode}")
            return c.inputStream.bufferedReader().readText()
        } finally {
            c.disconnect()
        }
    }

    /**
     * Downloads to [dest] through a ".part" file and resumes one left from before.
     * [onProgress] gets bytes so far. Throws IOException on failure.
     */
    fun download(url: String, dest: File, expectedBytes: Long, onProgress: (Long) -> Unit) {
        val part = File(dest.path + ".part")
        if (dest.exists() && dest.length() == expectedBytes) { onProgress(expectedBytes); return }
        var have = if (part.exists()) part.length() else 0L
        if (have > expectedBytes) { part.delete(); have = 0 }
        if (have < expectedBytes) {
            val c = open(url)
            if (have > 0) c.setRequestProperty("Range", "bytes=$have-")
            try {
                val code = c.responseCode
                if (code == 200 && have > 0) { part.delete(); have = 0 } // server ignored the range
                else if (code != 200 && code != 206) throw IOException("HTTP $code")
                RandomAccessFile(part, "rw").use { out ->
                    out.seek(have)
                    c.inputStream.use { input ->
                        val buf = ByteArray(1 shl 16)
                        var last = 0L
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            have += n
                            val now = System.nanoTime()
                            if (now - last > 250_000_000L) { onProgress(have); last = now }
                        }
                    }
                }
            } finally {
                c.disconnect()
            }
        }
        onProgress(have)
        if (have != expectedBytes) throw IOException("The download stopped early.")
        if (!part.renameTo(dest)) throw IOException("Couldn't save the download.")
    }

    fun sha256(file: File, onProgress: (Long) -> Unit = {}): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(1 shl 20)
            var total = 0L
            var last = 0L
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
                total += n
                val now = System.nanoTime()
                if (now - last > 250_000_000L) { onProgress(total); last = now }
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}
