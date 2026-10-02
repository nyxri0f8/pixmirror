package com.pixmirror.pixmirror

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Accessibility service that turns remote input into real touches.
 * Android does not let normal apps inject input; this is the supported way.
 */
class InputService : AccessibilityService() {

    companion object {
        @Volatile var instance: InputService? = null
        val isEnabled: Boolean get() = instance != null
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    private fun screenSize(): Pair<Int, Int> {
        val m = ScreenInfo.realMetrics(this)
        return Pair(m.widthPixels, m.heightPixels)
    }

    // ---- Live touch: a finger that follows the remote pointer -------------
    //
    // Built from continued strokes (API 26+): each segment is dispatched once
    // the previous one completes, so the finger stays down between segments
    // and apps see a real, continuous drag.

    private var live: GestureDescription.StrokeDescription? = null
    private var inFlight = false
    private var lastX = 0f
    private var lastY = 0f
    private var pendingX: Float? = null
    private var pendingY = 0f
    private var pendingUp = false
    private var jitter = 0.5f

    private fun toScreen(nx: Double, ny: Double): Pair<Float, Float> {
        val (w, h) = screenSize()
        return Pair((nx * w).toFloat().coerceIn(0f, w - 1f), (ny * h).toFloat().coerceIn(0f, h - 1f))
    }

    fun touchDown(nx: Double, ny: Double): Boolean {
        if (live != null) {
            // A previous finger never lifted; release it where it is.
            pendingUp = true
            pump()
        }
        val (x, y) = toScreen(nx, ny)
        // A stroke needs a non-zero length; nudge by half a pixel.
        val path = Path().apply { moveTo(x, y); lineTo(x + 0.5f, y) }
        val stroke = GestureDescription.StrokeDescription(path, 0, 1, true)
        live = stroke
        lastX = x + 0.5f
        lastY = y
        pendingX = null
        pendingUp = false
        dispatch(stroke)
        return true
    }

    fun touchMove(nx: Double, ny: Double) {
        if (live == null) return
        val (x, y) = toScreen(nx, ny)
        pendingX = x
        pendingY = y
        if (!inFlight) pump()
    }

    fun touchUp(nx: Double, ny: Double) {
        if (live == null) return
        val (x, y) = toScreen(nx, ny)
        pendingX = x
        pendingY = y
        pendingUp = true
        if (!inFlight) pump()
    }

    private fun pump() {
        val current = live ?: return
        if (inFlight) return
        var x = pendingX
        var y = pendingY
        if (x == null) {
            if (!pendingUp) return
            x = lastX
            y = lastY
        }
        if (x == lastX && y == lastY) {
            jitter = -jitter
            x += jitter
        }
        val end = pendingUp
        val path = Path().apply { moveTo(lastX, lastY); lineTo(x, y) }
        val next = try {
            current.continueStroke(path, 0, 16, !end)
        } catch (e: Exception) {
            live = null
            return
        }
        pendingX = null
        lastX = x
        lastY = y
        if (end) {
            pendingUp = false
            live = null
        } else {
            live = next
        }
        dispatch(next)
    }

    private fun dispatch(stroke: GestureDescription.StrokeDescription) {
        inFlight = true
        val ok = dispatchGesture(
            GestureDescription.Builder().addStroke(stroke).build(),
            object : GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    inFlight = false
                    pump()
                }

                override fun onCancelled(gestureDescription: GestureDescription?) {
                    inFlight = false
                    live = null
                }
            },
            null
        )
        if (!ok) {
            inFlight = false
            live = null
        }
    }

    /** [points] is a flat list of normalized x,y pairs (0..1). */
    fun gesture(points: List<Double>, durationMs: Long): Boolean {
        if (points.size < 2) return false
        val (w, h) = screenSize()
        val path = Path()
        path.moveTo((points[0] * w).toFloat(), (points[1] * h).toFloat())
        var i = 2
        while (i + 1 < points.size) {
            path.lineTo((points[i] * w).toFloat(), (points[i + 1] * h).toFloat())
            i += 2
        }
        val duration = durationMs.coerceIn(1, GestureDescription.getMaxGestureDuration())
        val stroke = GestureDescription.StrokeDescription(path, 0, duration)
        return dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
    }

    fun globalAction(name: String): Boolean {
        val action = when (name) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
            "quickSettings" -> GLOBAL_ACTION_QUICK_SETTINGS
            "lock" -> if (Build.VERSION.SDK_INT >= 28) GLOBAL_ACTION_LOCK_SCREEN else return false
            "screenshot" -> if (Build.VERSION.SDK_INT >= 28) GLOBAL_ACTION_TAKE_SCREENSHOT else return false
            else -> return false
        }
        return performGlobalAction(action)
    }

    private fun focusedInput(): AccessibilityNodeInfo? =
        rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)

    private fun currentText(node: AccessibilityNodeInfo): String {
        if (Build.VERSION.SDK_INT >= 26 && node.isShowingHintText) return ""
        return node.text?.toString() ?: ""
    }

    private fun setText(node: AccessibilityNodeInfo, text: String): Boolean {
        val args = Bundle()
        args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        val ok = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        val sel = Bundle()
        sel.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, text.length)
        sel.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, text.length)
        node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, sel)
        return ok
    }

    fun typeText(text: String): Boolean {
        val node = focusedInput() ?: return false
        if (text == "\n") return key("enter")
        return setText(node, currentText(node) + text)
    }

    fun key(name: String): Boolean {
        when (name) {
            "back", "escape" -> return globalAction("back")
            "home" -> return globalAction("home")
        }
        val node = focusedInput() ?: return false
        return when (name) {
            "backspace" -> {
                val t = currentText(node)
                if (t.isEmpty()) true else setText(node, t.dropLast(1))
            }
            "enter" -> {
                if (Build.VERSION.SDK_INT >= 30) {
                    node.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
                } else {
                    setText(node, currentText(node) + "\n")
                }
            }
            else -> false
        }
    }
}
