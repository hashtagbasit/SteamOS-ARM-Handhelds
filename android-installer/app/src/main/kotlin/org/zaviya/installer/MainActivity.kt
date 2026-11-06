package org.zaviya.installer

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import org.zaviya.installer.ui.ActionId
import org.zaviya.installer.ui.ZaviyaScreen
import org.zaviya.installer.ui.toModel

class MainActivity : ComponentActivity() {
    private val vm: InstallerViewModel by viewModels()
    private val askNotifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContent {
            val screen by vm.screen.collectAsState()
            val close by vm.close.collectAsState()
            LaunchedEffect(close) { if (close) finish() }
            BackHandler { vm.back() }
            ZaviyaScreen(screen.toModel(), ::onAction, vm::back)
        }
    }

    override fun onStart() {
        super.onStart()
        BackgroundDownload.appVisible = true
        BackgroundDownload.clearResult(this)
    }

    override fun onStop() {
        BackgroundDownload.appVisible = false
        super.onStop()
    }

    private fun onAction(id: ActionId) {
        // Only for the notification: the download runs whatever the answer is.
        if (id == ActionId.Download && Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        vm.onAction(id)
    }
}
