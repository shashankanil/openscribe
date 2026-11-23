package org.opensource.openscribe.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.layout.size
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * The Mac app's palette (Sources/OpenScribe/FlowTheme.swift): warm paper, ink, an amber accent, and the same
 * recording red and success green. No dynamic color, so OpenScribe looks the same on every phone and on the Mac.
 */
@Immutable
data class FlowColors(val success: Color, val warning: Color, val recording: Color, val line: Color)

private val LightFlow = FlowColors(
    success = Color(0xFF219E61), warning = Color(0xFFCC800D), recording = Color(0xFFE83D45), line = Color(0xFFDFDED9),
)
private val DarkFlow = FlowColors(
    success = Color(0xFF4DD18C), warning = Color(0xFFFFB847), recording = Color(0xFFFF6366), line = Color(0xFF2A2B29),
)

val LocalFlowColors = staticCompositionLocalOf { LightFlow }

object Flow {
    val colors: FlowColors @Composable get() = LocalFlowColors.current
}

private val Light = lightColorScheme(
    primary = Color(0xFFAD521A),
    onPrimary = Color(0xFFFFFCF5),
    primaryContainer = Color(0xFFF4E9E1),
    onPrimaryContainer = Color(0xFF6B3008),
    secondary = Color(0xFF1F241C),
    onSecondary = Color(0xFFFFFCF5),
    secondaryContainer = Color(0xFFEFEEE9),
    onSecondaryContainer = Color(0xFF1F241C),
    tertiary = Color(0xFF219E61),
    tertiaryContainer = Color(0xFFE4F2E9),
    onTertiaryContainer = Color(0xFF15633D),
    background = Color(0xFFF9F7F3),
    onBackground = Color(0xFF1F241C),
    surface = Color(0xFFF9F7F3),
    onSurface = Color(0xFF1F241C),
    surfaceVariant = Color(0xFFEFEEE9),
    onSurfaceVariant = Color(0xFF6B6E67),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFFCFBF8),
    surfaceContainer = Color(0xFFFEFEFC),
    surfaceContainerHigh = Color(0xFFF3F1EB),
    surfaceContainerHighest = Color(0xFFFEFEFC),
    outline = Color(0xFFC9C8C2),
    outlineVariant = Color(0xFFDFDED9),
    error = Color(0xFFE83D45),
    onError = Color(0xFFFFFFFF),
    errorContainer = Color(0xFFFBE4E4),
    onErrorContainer = Color(0xFF8C1D22),
)

private val Dark = darkColorScheme(
    primary = Color(0xFFF0B863),
    onPrimary = Color(0xFF1F241C),
    primaryContainer = Color(0xFF3E3727),
    onPrimaryContainer = Color(0xFFF0B863),
    secondary = Color(0xFFF5F2E8),
    onSecondary = Color(0xFF1F241C),
    secondaryContainer = Color(0xFF2A2C29),
    onSecondaryContainer = Color(0xFFF5F2E8),
    tertiary = Color(0xFF4DD18C),
    tertiaryContainer = Color(0xFF23372C),
    onTertiaryContainer = Color(0xFF4DD18C),
    background = Color(0xFF111211),
    onBackground = Color(0xFFF5F2E8),
    surface = Color(0xFF111211),
    onSurface = Color(0xFFF5F2E8),
    surfaceVariant = Color(0xFF2A2C29),
    onSurfaceVariant = Color(0xFFA5A49D),
    surfaceContainerLowest = Color(0xFF0D0E0D),
    surfaceContainerLow = Color(0xFF171917),
    surfaceContainer = Color(0xFF1C1E1C),
    surfaceContainerHigh = Color(0xFF1F211F),
    surfaceContainerHighest = Color(0xFF1C1E1C),
    outline = Color(0xFF3A3B38),
    outlineVariant = Color(0xFF2A2B29),
    error = Color(0xFFFF6366),
    onError = Color(0xFF1F241C),
    errorContainer = Color(0xFF3A2122),
    onErrorContainer = Color(0xFFFF9A9C),
)

private val base = Typography()
private val FlowTypography = base.copy(
    titleLarge = base.titleLarge.copy(fontWeight = FontWeight.SemiBold),
    titleMedium = base.titleMedium.copy(fontWeight = FontWeight.SemiBold),
    titleSmall = base.titleSmall.copy(fontWeight = FontWeight.SemiBold),
)

@Composable
fun OpenScribeTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    CompositionLocalProvider(LocalFlowColors provides if (dark) DarkFlow else LightFlow) {
        MaterialTheme(colorScheme = if (dark) Dark else Light, typography = FlowTypography, content = content)
    }
}

/** The 1 pt hairline the Mac app draws around cards. */
@Composable
fun flowBorder() = androidx.compose.foundation.BorderStroke(1.dp, Flow.colors.line)

/** The Whisperlight mark from the Mac app: a cream wave on a dark rounded tile. */
@Composable
fun WhisperlightLogo(size: androidx.compose.ui.unit.Dp = 64.dp) {
    androidx.compose.foundation.Canvas(androidx.compose.ui.Modifier.size(size)) {
        val s = this.size.minDimension
        drawRoundRect(Color(0xFF14171F), cornerRadius = androidx.compose.ui.geometry.CornerRadius(s * 0.28f))
        val inset = s * 0.23f
        val left = inset
        val width = s - inset * 2
        val top = inset
        val bottom = s - inset
        val mid = s / 2
        val q = width / 4
        val path = androidx.compose.ui.graphics.Path().apply {
            moveTo(left, mid)
            for (i in 0 until 4) {
                val start = left + q * i
                val peak = if (i % 2 == 0) top else bottom
                cubicTo(start + q * 0.34f, peak, start + q * 0.66f, peak, start + q, mid)
            }
        }
        drawPath(
            path, Color(0xFFFFFAE6),
            style = androidx.compose.ui.graphics.drawscope.Stroke(
                width = maxOf(1.6f, s * 0.075f),
                cap = androidx.compose.ui.graphics.StrokeCap.Round,
                join = androidx.compose.ui.graphics.StrokeJoin.Round,
            ),
        )
    }
}
