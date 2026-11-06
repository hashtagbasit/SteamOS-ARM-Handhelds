package org.zaviya.installer.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import org.zaviya.installer.R

object Palette {
    val Background = Color(0xFF0C0C0E)
    val Text = Color(0xFFF3F2EE)
    val Muted = Color(0xFF8E8E96)
    val Track = Color(0xFF222226)
    val Rule = Color(0xFF3A3A40)
    val Gold = Color(0xFFC9A24D)
}

val Jost = FontFamily(
    Font(R.font.jost_light, FontWeight.Light),
    Font(R.font.jost_regular, FontWeight.Normal),
)

object Type {
    val Statement = TextStyle(fontFamily = Jost, fontWeight = FontWeight.Light, fontSize = 40.sp, lineHeight = 48.sp, letterSpacing = (-0.4).sp, color = Palette.Text)
    val Detail = TextStyle(fontFamily = Jost, fontWeight = FontWeight.Normal, fontSize = 19.sp, lineHeight = 27.sp, color = Palette.Muted)
    val Action = TextStyle(fontFamily = Jost, fontWeight = FontWeight.Normal, fontSize = 20.sp, color = Palette.Text)
    val Big = TextStyle(fontFamily = Jost, fontWeight = FontWeight.Light, fontSize = 72.sp, lineHeight = 80.sp, color = Palette.Text)
}
