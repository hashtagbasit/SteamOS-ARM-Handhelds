package org.zaviya.installer.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import android.view.HapticFeedbackConstants
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

const val HOLD_MS = 1500

private val CONFIRM_KEYS = setOf(Key.ButtonA, Key.DirectionCenter, Key.Enter, Key.NumPadEnter)

/**
 * An action drawn as text with a hairline under it. Gold when focused or pressed.
 * A hold action fills the line in gold over 1.5 s; letting go early cancels.
 */
@Composable
fun ActionText(
    spec: ActionSpec,
    onTrigger: (ActionId) -> Unit,
    modifier: Modifier = Modifier,
    focusRequester: FocusRequester? = null,
    /** Test only: draw as if focused / held this far. */
    previewFocused: Boolean = false,
    previewHold: Float = 0f,
) {
    var focused by remember { mutableStateOf(previewFocused) }
    var pressed by remember { mutableStateOf(false) }
    val hold = remember { Animatable(previewHold) }
    val scope = rememberCoroutineScope()
    val view = LocalView.current
    var holdJob by remember { mutableStateOf<Job?>(null) }

    fun startHold() {
        if (holdJob?.isActive == true) return
        holdJob = scope.launch {
            hold.snapTo(0f)
            hold.animateTo(1f, tween(HOLD_MS, easing = LinearEasing))
            view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
            onTrigger(spec.id)
        }
    }
    fun cancelHold() {
        val running = holdJob?.isActive == true
        holdJob?.cancel()
        if (running) scope.launch { hold.animateTo(0f, tween(120)) }
    }

    val active = focused || pressed
    val labelColor = if (active) Palette.Gold else Palette.Text

    Box(
        modifier
            .fillMaxWidth()
            .height(64.dp)
            .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier)
            .onFocusChanged { focused = it.isFocused || previewFocused }
            .focusable()
            .onKeyEvent { e ->
                if (e.key !in CONFIRM_KEYS) return@onKeyEvent false
                when (e.type) {
                    KeyEventType.KeyDown -> {
                        if (e.nativeKeyEventRepeat() == 0) {
                            pressed = true
                            if (spec.hold) startHold()
                        }
                        true
                    }
                    KeyEventType.KeyUp -> {
                        pressed = false
                        if (spec.hold) cancelHold() else onTrigger(spec.id)
                        true
                    }
                    else -> false
                }
            }
            .pointerInput(spec) {
                detectTapGestures(
                    onPress = {
                        pressed = true
                        if (spec.hold) startHold()
                        tryAwaitRelease()
                        pressed = false
                        if (spec.hold) cancelHold()
                    },
                    onTap = { if (!spec.hold) onTrigger(spec.id) },
                )
            }
            .semantics(mergeDescendants = true) {
                role = Role.Button
                onClick(label = spec.label) { onTrigger(spec.id); true }
            }
            .drawBehind {
                val h = size.height
                // The resting hairline.
                drawLine(Palette.Rule, Offset(0f, h - 0.5.dp.toPx()), Offset(size.width, h - 0.5.dp.toPx()), 1.dp.toPx())
                if (spec.hold) {
                    if (active) drawLine(Palette.Gold.copy(alpha = 0.4f), Offset(0f, h - 1.dp.toPx()), Offset(size.width, h - 1.dp.toPx()), 2.dp.toPx())
                    if (hold.value > 0f) drawLine(Palette.Gold, Offset(0f, h - 1.dp.toPx()), Offset(size.width * hold.value, h - 1.dp.toPx()), 2.dp.toPx())
                } else if (active) {
                    drawLine(Palette.Gold, Offset(0f, h - 1.dp.toPx()), Offset(size.width, h - 1.dp.toPx()), 2.dp.toPx())
                }
            },
        contentAlignment = Alignment.CenterStart,
    ) {
        BasicText(spec.label, Modifier.padding(bottom = 2.dp), style = Type.Action.copy(color = labelColor))
    }
}

private fun androidx.compose.ui.input.key.KeyEvent.nativeKeyEventRepeat(): Int = nativeKeyEvent.repeatCount
