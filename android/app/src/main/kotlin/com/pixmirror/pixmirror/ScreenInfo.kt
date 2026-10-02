package com.pixmirror.pixmirror

import android.content.Context
import android.graphics.RectF
import android.hardware.display.DisplayManager
import android.os.Build
import android.util.DisplayMetrics
import android.view.Display
import android.view.RoundedCorner

/** Physical screen geometry, so the PC can draw a true-to-life phone frame. */
object ScreenInfo {

    private fun display(context: Context): Display =
        (context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager)
            .getDisplay(Display.DEFAULT_DISPLAY)

    fun realMetrics(context: Context): DisplayMetrics {
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        display(context).getRealMetrics(metrics)
        return metrics
    }

    /**
     * Sizes are in physical pixels for the current rotation. Corner radius and
     * cutout rects let the viewer reproduce the exact screen shape.
     */
    fun describe(context: Context): Map<String, Any> {
        val d = display(context)
        val m = realMetrics(context)
        val info = mutableMapOf<String, Any>(
            "w" to m.widthPixels,
            "h" to m.heightPixels,
            "dpi" to m.densityDpi,
            "model" to (Build.MODEL ?: ""),
            "maker" to (Build.MANUFACTURER ?: ""),
        )
        if (Build.VERSION.SDK_INT >= 31) {
            val r = d.getRoundedCorner(RoundedCorner.POSITION_TOP_LEFT)?.radius
                ?: d.getRoundedCorner(RoundedCorner.POSITION_BOTTOM_LEFT)?.radius
            if (r != null) info["corner"] = r
        }
        if (Build.VERSION.SDK_INT >= 29) {
            val cutout = d.cutout
            if (cutout != null) {
                // Padded safe zones; only a fallback for drawing.
                info["cutouts"] = cutout.boundingRects.flatMap {
                    listOf(it.left, it.top, it.right, it.bottom)
                }
                // The camera's actual outline (Android 12+), e.g. the round
                // punch hole itself rather than the band around it.
                if (Build.VERSION.SDK_INT >= 31) {
                    cutout.cutoutPath?.let { path ->
                        val b = RectF()
                        path.computeBounds(b, true)
                        if (!b.isEmpty) {
                            info["holes"] = listOf(b.left.toDouble(), b.top.toDouble(), b.right.toDouble(), b.bottom.toDouble())
                        }
                    }
                }
            }
        }
        return info
    }
}
