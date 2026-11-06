package org.zaviya.installer

import android.app.Notification
import android.content.Intent
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class DownloadServiceTest {
    @After fun reset() { BackgroundDownload.progress.value = null }

    private fun started() = Robolectric.buildService(DownloadService::class.java, Intent()).create().startCommand(0, 1).get()

    @Test fun goesForegroundAndShowsProgress() {
        BackgroundDownload.progress.value = DownloadProgress("Getting Zaviya.", 40)
        val s = shadowOf(started())
        val n = s.lastForegroundNotification
        assertEquals(BackgroundDownload.RUNNING_ID, s.lastForegroundNotificationId)
        assertEquals("Getting Zaviya.", n.extras.getString(Notification.EXTRA_TITLE))
        assertEquals(40, n.extras.getInt(Notification.EXTRA_PROGRESS))
        assertFalse(s.isStoppedBySelf)
    }

    @Test fun stopsWhenTheDownloadEnds() {
        BackgroundDownload.progress.value = DownloadProgress("Getting Zaviya.", 0)
        val s = shadowOf(started())
        BackgroundDownload.progress.value = null
        org.robolectric.shadows.ShadowLooper.idleMainLooper()
        assertTrue(s.isStoppedBySelf)
    }

    /** A download that fails before the service starts must not leave it running or crash it. */
    @Test fun stopsIfTheDownloadEndedBeforeItStarted() {
        val s = shadowOf(started())
        assertEquals(BackgroundDownload.RUNNING_ID, s.lastForegroundNotificationId)
        assertTrue(s.isStoppedBySelf)
    }
}
