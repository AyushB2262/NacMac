package com.nactore.nacmac.ui

import android.content.Context
import android.graphics.*
import android.util.AttributeSet
import android.view.View

class NacMacViewfinderView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private val scrimColor = 0x99000000.toInt()
    private val erasePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR)
    }

    private val density = context.resources.displayMetrics.density
    private val cornerRadius = 24f * density
    private val cornerLength = 38f * density
    private val strokeWidth = 4.5f * density

    // NacMac Theme Dimmed Premium Orange
    private val nacmacOrange = 0xFFEA580C.toInt()

    // 1. Full Frame Subtle Boundary Paint
    private val fullFramePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.5f * density
        color = 0x30EA580C.toInt()
    }

    // 2. Outer Glow Layer 1 (Soft Warm Aura)
    private val glowOuterPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 12f * density
        color = 0x18EA580C.toInt()
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    // 3. Mid Glow Layer 2 (Warm Radiance)
    private val glowMidPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 7f * density
        color = 0x40EA580C.toInt()
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    // 4. Solid Core Corner Paint (Refined NacMac Orange)
    private val cornerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = this@NacMacViewfinderView.strokeWidth
        color = nacmacOrange
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    val frameRect = RectF()

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)

        val boxSize = (270f * density).coerceAtMost(w * 0.78f)
        val left = (w - boxSize) / 2f
        val top = (h - boxSize) * 0.38f
        frameRect.set(left, top, left + boxSize, top + boxSize)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (frameRect.isEmpty) return

        // 1. Draw Dark Scrim with Clear Viewfinder Cutout
        val saveCount = canvas.saveLayer(0f, 0f, width.toFloat(), height.toFloat(), null)
        canvas.drawColor(scrimColor)
        canvas.drawRoundRect(frameRect, cornerRadius, cornerRadius, erasePaint)
        canvas.restoreToCount(saveCount)

        // 2. Draw Subtle Full Rounded Boundary in Soft Orange
        canvas.drawRoundRect(frameRect, cornerRadius, cornerRadius, fullFramePaint)

        // 3. Draw Corner Geometry (Top-Left, Top-Right, Bottom-Left, Bottom-Right)
        val l = frameRect.left
        val t = frameRect.top
        val r = frameRect.right
        val b = frameRect.bottom

        val cornerPath = Path().apply {
            // Top-Left
            moveTo(l, t + cornerLength)
            lineTo(l, t + cornerRadius)
            quadTo(l, t, l + cornerRadius, t)
            lineTo(l + cornerLength, t)

            // Top-Right
            moveTo(r - cornerLength, t)
            lineTo(r - cornerRadius, t)
            quadTo(r, t, r, t + cornerRadius)
            lineTo(r, t + cornerLength)

            // Bottom-Left
            moveTo(l, b - cornerLength)
            lineTo(l, b - cornerRadius)
            quadTo(l, b, l + cornerRadius, b)
            lineTo(l + cornerLength, b)

            // Bottom-Right
            moveTo(r - cornerLength, b)
            lineTo(r - cornerRadius, b)
            quadTo(r, b, r, b - cornerRadius)
            lineTo(r, b - cornerLength)
        }

        // Draw Layered Glowing Orange Corners
        canvas.drawPath(cornerPath, glowOuterPaint)
        canvas.drawPath(cornerPath, glowMidPaint)
        canvas.drawPath(cornerPath, cornerPaint)
    }
}

typealias GPayViewfinderView = NacMacViewfinderView
