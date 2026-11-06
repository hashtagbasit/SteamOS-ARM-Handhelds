package org.zaviya.installer

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.zaviya.installer.net.ImagePart
import org.zaviya.installer.net.Network
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import kotlin.concurrent.thread

class NetworkTest {
    @get:Rule val tmp = TemporaryFolder()

    private val one = ByteArray(5000) { (it % 251).toByte() }
    private val two = ByteArray(3000) { (it % 241).toByte() }
    private lateinit var server: ServerSocket
    private val ranges = java.util.Collections.synchronizedList(mutableListOf<String?>())
    private var honourRange = true
    private var failSecond = false

    private fun url(name: String) = "http://127.0.0.1:${server.localPort}/$name"
    private fun parts() = listOf(ImagePart(url("1"), one.size.toLong()), ImagePart(url("2"), two.size.toLong()))
    private fun dest() = File(tmp.root, "image.zst")
    private fun partial() = File(tmp.root, "image.zst.part")

    private fun answer(socket: Socket) = socket.use { s ->
        val lines = s.getInputStream().bufferedReader().let { r -> generateSequence { r.readLine() }.takeWhile { it.isNotEmpty() }.toList() }
        val second = lines.first().split(" ")[1] == "/2"
        val body = if (second) two else one
        val range = lines.firstOrNull { it.startsWith("Range:", ignoreCase = true) }?.substringAfter(":")?.trim()
        ranges += range
        val (status, from) = when {
            second && failSecond -> "503 Unavailable" to body.size
            range != null && honourRange -> "206 Partial Content" to range.removePrefix("bytes=").removeSuffix("-").toInt()
            else -> "200 OK" to 0
        }
        val out = s.getOutputStream()
        out.write("HTTP/1.1 $status\r\nContent-Length: ${body.size - from}\r\nConnection: close\r\n\r\n".toByteArray())
        out.write(body, from, body.size - from)
        out.flush()
    }

    @Before fun start() {
        server = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        thread(isDaemon = true) {
            try { while (true) answer(server.accept()) } catch (_: SocketException) {}
        }
    }

    @After fun stop() = server.close()

    @Test fun joinsPartsIntoOneFile() {
        var seen = 0L
        Network.download(parts(), dest()) { seen = it }
        assertArrayEquals(one + two, dest().readBytes())
        assertEquals(8000L, seen)
        assertFalse(partial().exists())
        assertEquals(listOf<String?>(null, null), ranges)
    }

    @Test fun resumesInsideTheFirstPart() {
        partial().writeBytes(one.copyOf(1200))
        Network.download(parts(), dest()) {}
        assertArrayEquals(one + two, dest().readBytes())
        assertEquals(listOf("bytes=1200-", null), ranges)
    }

    @Test fun resumesInsideTheSecondPartWithItsOwnOffset() {
        partial().writeBytes(one + two.copyOf(700))
        Network.download(parts(), dest()) {}
        assertArrayEquals(one + two, dest().readBytes())
        assertEquals(listOf<String?>("bytes=700-"), ranges)
    }

    @Test fun startsThePartAgainWhenTheServerIgnoresTheRange() {
        honourRange = false
        partial().writeBytes(one + two.copyOf(700))
        Network.download(parts(), dest()) {}
        assertArrayEquals(one + two, dest().readBytes())
    }

    @Test fun keepsFinishedPartsWhenALaterOneFails() {
        failSecond = true
        assertThrows(IOException::class.java) { Network.download(parts(), dest()) {} }
        assertFalse(dest().exists())
        assertArrayEquals(one, partial().readBytes())
    }

    @Test fun finishedFileIsNotFetchedAgain() {
        dest().writeBytes(one + two)
        Network.download(parts(), dest()) {}
        assertTrue(ranges.isEmpty())
    }
}
