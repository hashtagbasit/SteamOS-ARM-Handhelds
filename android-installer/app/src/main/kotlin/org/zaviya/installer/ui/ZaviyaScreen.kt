package org.zaviya.installer.ui

import android.provider.Settings
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import org.zaviya.installer.R

@Composable
private fun rememberReducedMotion(): Boolean {
    val ctx = LocalContext.current
    return remember {
        runCatching { Settings.Global.getFloat(ctx.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }.getOrDefault(false)
    }
}

/**
 * The whole app is this one layout: a statement, a line of detail, and the single
 * action. Landscape puts the action to the right, portrait puts it below.
 */
@Composable
fun ZaviyaScreen(
    model: ScreenModel,
    onAction: (ActionId) -> Unit,
    onBack: () -> Unit = {},
    /** Test only: draw the first action as focused. */
    previewFocus: Boolean = false,
    previewHold: Float = 0f,
) {
    val reduced = rememberReducedMotion()
    val latest by androidx.compose.runtime.rememberUpdatedState(model)
    val line by animateFloatAsState(model.line, tween(if (reduced) 0 else 200), label = "line")

    Box(
        Modifier
            .fillMaxSize()
            .background(Palette.Background)
            .onPreviewKeyEvent { e ->
                if (e.key == Key.ButtonB && e.type == KeyEventType.KeyUp) { onBack(); true } else false
            },
    ) {
        AnimatedContent(
            targetState = model,
            contentKey = { it.key },
            transitionSpec = {
                if (reduced) EnterTransition.None togetherWith ExitTransition.None
                else (fadeIn(tween(200)) + slideInVertically(tween(200)) { 14 }) togetherWith fadeOut(tween(200))
            },
            label = "screen",
        ) { shown ->
            // The screen that is staying keeps updating (progress); a leaving one keeps its last state.
            val m = if (shown.key == latest.key) latest else shown
            Content(m, onAction, previewFocus, previewHold)
        }

        Image(
            painterResource(R.drawable.mark), null,
            Modifier.padding(start = 43.dp, top = 28.dp).size(36.dp).align(Alignment.TopStart),
        )

        // The only progress element: a hairline across the bottom.
        Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(2.dp).background(Palette.Track)) {
            Box(Modifier.fillMaxWidth(line).fillMaxHeight().background(Palette.Gold))
        }
    }
}

@Composable
private fun Content(m: ScreenModel, onAction: (ActionId) -> Unit, previewFocus: Boolean, previewHold: Float) {
    val first = remember { FocusRequester() }
    LaunchedEffect(m.key) { if (m.primary != null || m.secondary != null) runCatching { first.requestFocus() } }
    val firstSpec = m.primary ?: m.secondary

    @Composable
    fun Actions(modifier: Modifier = Modifier) {
        Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            m.primary?.let { ActionText(it, onAction, focusRequester = if (firstSpec == it) first else null, previewFocused = previewFocus, previewHold = previewHold) }
            m.secondary?.let { ActionText(it, onAction, focusRequester = if (firstSpec == it) first else null) }
        }
    }

    @Composable
    fun Words() {
        BasicText(m.statement, style = Type.Statement)
        val detail = if (m.showTechnical && m.technical != null) m.technical else m.detail
        if (detail != null) {
            Spacer(Modifier.height(14.dp))
            BasicText(detail, Modifier.widthIn(max = 600.dp), style = Type.Detail)
        }
    }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        if (maxWidth > maxHeight) {
            Row(Modifier.fillMaxSize().padding(start = 48.dp, end = 48.dp, top = 80.dp, bottom = 48.dp)) {
                Column(Modifier.weight(1.5f).fillMaxHeight().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.Center) { Words() }
                Spacer(Modifier.width(56.dp))
                Column(Modifier.weight(1f).fillMaxHeight(), verticalArrangement = Arrangement.Center) {
                    if (m.big != null) {
                        BasicText(m.big, style = Type.Big)
                        Spacer(Modifier.height(24.dp))
                    }
                    Actions()
                }
            }
        } else {
            Column(Modifier.fillMaxSize().padding(start = 40.dp, end = 40.dp, top = 96.dp, bottom = 40.dp)) {
                Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.Center) {
                    Words()
                    if (m.big != null) {
                        Spacer(Modifier.height(32.dp))
                        BasicText(m.big, style = Type.Big)
                    }
                }
                Spacer(Modifier.height(24.dp))
                Actions()
            }
        }
    }
}
