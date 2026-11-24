package com.tntlikely.beecount.autobill

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowInsets
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import java.util.Locale
import kotlin.math.abs

/**
 * 平时隐身、来账弹出「侧边吸边悬浮球」与原地展开操作卡：
 *
 * - 停靠屏幕右侧安全区（默认约 34% 高度），完全避开荣耀 Magic 8 顶部挖孔与系统状态栏
 * - 支持上下拖动调位（记忆位置）与右滑直接收起
 * - 收起态停留 8 秒自动隐身（自动入账模式不打扰）
 * - 轻点悬浮球暂停计时，原地展开操作卡，无需跳回 App 即可「撤销删除 / 确认 / 修改 / 忽略」
 */
object CapsuleOverlayManager {
    private const val COLLAPSED_TIMEOUT_MS = 8_000L
    private const val EXPANDED_TIMEOUT_MS = 20_000L

    private data class OverlayState(
        val eventId: String,
        val type: String,
        val amount: Double,
        val merchant: String?,
        val accountLabel: String?,
        val upgraded: Boolean,
        val autoSave: Boolean,
        val onConfirm: (String, Boolean) -> Unit,
        val onCancel: (String) -> Unit,
        val onTapEdit: (String) -> Unit,
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private var rootContainer: FrameLayout? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var currentState: OverlayState? = null
    private var isExpanded: Boolean = false
    private var dismissRunnable: Runnable? = null

    fun canDrawOverlays(context: Context): Boolean {
        return Settings.canDrawOverlays(context)
    }

    fun showOrUpdate(
        context: Context,
        eventId: String,
        type: String,
        amount: Double,
        merchant: String?,
        accountLabel: String?,
        upgraded: Boolean,
        autoSave: Boolean,
        onConfirm: (String, Boolean) -> Unit,
        onCancel: (String) -> Unit,
        onTapEdit: (String) -> Unit,
    ) {
        val appCtx = context.applicationContext
        if (!canDrawOverlays(appCtx)) return

        mainHandler.post {
            try {
                val nextState = OverlayState(
                    eventId = eventId,
                    type = type,
                    amount = amount,
                    merchant = merchant,
                    accountLabel = accountLabel,
                    upgraded = upgraded,
                    autoSave = autoSave,
                    onConfirm = onConfirm,
                    onCancel = onCancel,
                    onTapEdit = onTapEdit,
                )

                val existingContainer = rootContainer
                if (existingContainer != null && currentState?.eventId == eventId) {
                    currentState = nextState
                    renderCurrentState(appCtx, existingContainer)
                    scheduleAutoDismiss(
                        appCtx,
                        if (isExpanded) EXPANDED_TIMEOUT_MS else COLLAPSED_TIMEOUT_MS,
                    )
                    return@post
                }

                dismissInternal(appCtx)

                val wm = appCtx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
                val metrics = resolveScreenMetrics(appCtx, wm)
                val density = appCtx.resources.displayMetrics.density
                fun dp(v: Int): Int = (v * density).toInt()

                val minY = metrics.safeTop + dp(48)
                val maxCollapsedY = maxOf(minY, metrics.height - dp(160))
                val defaultY = ((metrics.height * 0.34f).toInt()).coerceIn(minY, maxCollapsedY)
                val startY = AutoBillStore.getOverlayY(appCtx, defaultY).coerceIn(minY, maxCollapsedY)

                val container = FrameLayout(appCtx)
                val lp = WindowManager.LayoutParams(
                    WindowManager.LayoutParams.WRAP_CONTENT,
                    WindowManager.LayoutParams.WRAP_CONTENT,
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                        WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                    PixelFormat.TRANSLUCENT,
                ).apply {
                    gravity = Gravity.TOP or Gravity.END
                    x = dp(6)
                    y = startY
                }

                currentState = nextState
                isExpanded = false
                rootContainer = container
                layoutParams = lp

                renderCurrentState(appCtx, container)

                container.alpha = 0f
                container.translationX = dp(40).toFloat()
                wm.addView(container, lp)

                container.animate()
                    .alpha(1f)
                    .translationX(0f)
                    .setDuration(220L)
                    .setInterpolator(DecelerateInterpolator())
                    .start()

                scheduleAutoDismiss(appCtx, COLLAPSED_TIMEOUT_MS)
            } catch (e: Exception) {
                android.util.Log.e("CapsuleOverlay", "显示侧边悬浮球失败: ${e.message}", e)
            }
        }
    }

    private fun renderCurrentState(appCtx: Context, container: FrameLayout) {
        val state = currentState ?: return
        container.removeAllViews()
        if (isExpanded) {
            container.addView(buildExpandedCardView(appCtx, state))
        } else {
            container.addView(buildCollapsedBallView(appCtx, state))
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun buildCollapsedBallView(appCtx: Context, state: OverlayState): View {
        val density = appCtx.resources.displayMetrics.density
        fun dp(v: Int): Int = (v * density).toInt()

        val pill = LinearLayout(appCtx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), dp(9), dp(12), dp(9))
            elevation = dp(10).toFloat()
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(24).toFloat()
                setColor(Color.parseColor("#F4121716"))
                setStroke(dp(1), Color.parseColor("#38FFFFFF"))
            }
        }

        val dot = View(appCtx).apply {
            layoutParams = LinearLayout.LayoutParams(dp(8), dp(8)).apply {
                marginEnd = dp(7)
            }
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(dotColorFor(state.type))
            }
        }
        pill.addView(dot)

        val amountTv = TextView(appCtx).apply {
            text = formatSignedAmount(state.type, state.amount)
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            isSingleLine = true
        }
        pill.addView(amountTv)

        val labelText = state.accountLabel?.takeIf { it.isNotBlank() }
            ?: state.merchant?.takeIf { it.isNotBlank() }
            ?: if (state.autoSave) "已记账" else "待确认"
        val subTv = TextView(appCtx).apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply {
                marginStart = dp(6)
            }
            text = if (state.upgraded) "✓ $labelText" else labelText
            setTextColor(Color.parseColor("#CCE0EAE6"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
            maxWidth = dp(96)
            isSingleLine = true
            ellipsize = TextUtils.TruncateAt.END
        }
        pill.addView(subTv)

        val touchSlop = ViewConfiguration.get(appCtx).scaledTouchSlop
        val wm = appCtx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val metrics = resolveScreenMetrics(appCtx, wm)
        val minY = metrics.safeTop + dp(48)
        val maxY = maxOf(minY, metrics.height - dp(160))

        var downRawX = 0f
        var downRawY = 0f
        var startParamY = 0
        var dragging = false

        pill.setOnTouchListener { _, ev ->
            val container = rootContainer ?: return@setOnTouchListener false
            val lp = layoutParams ?: return@setOnTouchListener false
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downRawX = ev.rawX
                    downRawY = ev.rawY
                    startParamY = lp.y
                    dragging = false
                    cancelAutoDismiss()
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = ev.rawX - downRawX
                    val dy = ev.rawY - downRawY
                    if (!dragging && (abs(dx) > touchSlop || abs(dy) > touchSlop)) {
                        dragging = true
                    }
                    if (dragging) {
                        lp.y = (startParamY + dy.toInt()).coerceIn(minY, maxY)
                        container.translationX = if (dx > 0f) dx else 0f
                        try {
                            wm.updateViewLayout(container, lp)
                        } catch (_: Exception) {
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    val dx = ev.rawX - downRawX
                    if (!dragging) {
                        container.translationX = 0f
                        expandCard(appCtx)
                    } else if (dx > dp(48)) {
                        container.animate()
                            .translationX(dp(160).toFloat())
                            .alpha(0f)
                            .setDuration(150L)
                            .withEndAction { dismissInternal(appCtx) }
                            .start()
                    } else {
                        container.translationX = 0f
                        AutoBillStore.saveOverlayY(appCtx, lp.y)
                        scheduleAutoDismiss(appCtx, COLLAPSED_TIMEOUT_MS)
                    }
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    container.translationX = 0f
                    scheduleAutoDismiss(appCtx, COLLAPSED_TIMEOUT_MS)
                    true
                }
                else -> false
            }
        }

        return pill
    }

    private fun expandCard(appCtx: Context) {
        val container = rootContainer ?: return
        val lp = layoutParams ?: return
        val wm = appCtx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val density = appCtx.resources.displayMetrics.density
        fun dp(v: Int): Int = (v * density).toInt()
        val metrics = resolveScreenMetrics(appCtx, wm)
        val minY = metrics.safeTop + dp(48)
        val maxExpandedY = maxOf(minY, metrics.height - dp(230))

        isExpanded = true
        lp.x = dp(12)
        lp.y = lp.y.coerceIn(minY, maxExpandedY)
        renderCurrentState(appCtx, container)
        try {
            wm.updateViewLayout(container, lp)
        } catch (_: Exception) {
        }
        scheduleAutoDismiss(appCtx, EXPANDED_TIMEOUT_MS)
    }

    private fun buildExpandedCardView(appCtx: Context, state: OverlayState): View {
        val wm = appCtx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val metrics = resolveScreenMetrics(appCtx, wm)
        val density = appCtx.resources.displayMetrics.density
        fun dp(v: Int): Int = (v * density).toInt()

        val cardWidth = minOf(metrics.width - dp(24), dp(296))
        val card = LinearLayout(appCtx).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = FrameLayout.LayoutParams(
                cardWidth,
                FrameLayout.LayoutParams.WRAP_CONTENT,
            )
            setPadding(dp(16), dp(14), dp(16), dp(14))
            elevation = dp(14).toFloat()
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(20).toFloat()
                setColor(Color.parseColor("#F5141918"))
                setStroke(dp(1), Color.parseColor("#3DFFFFFF"))
            }
        }

        // 顶部状态行 + 关闭按钮
        val header = LinearLayout(appCtx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val dot = View(appCtx).apply {
            layoutParams = LinearLayout.LayoutParams(dp(8), dp(8)).apply {
                marginEnd = dp(7)
            }
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(dotColorFor(state.type))
            }
        }
        header.addView(dot)

        val badgeTv = TextView(appCtx).apply {
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            text = when {
                state.autoSave && state.upgraded -> "✓ 已自动合并账单"
                state.autoSave -> "已自动记账"
                state.upgraded -> "✓ 待确认账单（已合并）"
                else -> "待确认记账"
            }
            setTextColor(Color.parseColor("#B5C4BF"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        header.addView(badgeTv)

        val closeBtn = TextView(appCtx).apply {
            text = "✕"
            setTextColor(Color.parseColor("#889994"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setPadding(dp(8), dp(2), dp(2), dp(2))
            setOnClickListener { dismissInternal(appCtx) }
        }
        header.addView(closeBtn)
        card.addView(header)

        // 大号金额
        val amountTv = TextView(appCtx).apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply {
                topMargin = dp(8)
            }
            text = formatSignedAmount(state.type, state.amount)
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        card.addView(amountTv)

        // 商户与账户明细
        val details = buildList {
            state.merchant?.takeIf { it.isNotBlank() }?.let { add(it) }
            state.accountLabel?.takeIf { it.isNotBlank() }?.let { add(it) }
        }.joinToString(" · ").ifEmpty { "素帐无感记账" }

        val detailTv = TextView(appCtx).apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply {
                topMargin = dp(4)
                bottomMargin = dp(14)
            }
            text = details
            setTextColor(Color.parseColor("#CCE0EAE6"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
        }
        card.addView(detailTv)

        // 底部 3 个操作按钮
        val actions = LinearLayout(appCtx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        fun makeActionButton(
            label: String,
            bgHex: String,
            textHex: String,
            weight: Float,
            endMarginDp: Int,
            onClick: () -> Unit,
        ): TextView {
            return TextView(appCtx).apply {
                layoutParams = LinearLayout.LayoutParams(
                    0,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    weight,
                ).apply {
                    marginEnd = dp(endMarginDp)
                }
                text = label
                gravity = Gravity.CENTER
                setTextColor(Color.parseColor(textHex))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                setPadding(dp(6), dp(9), dp(6), dp(9))
                isSingleLine = true
                background = GradientDrawable().apply {
                    shape = GradientDrawable.RECTANGLE
                    cornerRadius = dp(12).toFloat()
                    setColor(Color.parseColor(bgHex))
                }
                setOnClickListener { onClick() }
            }
        }

        if (state.autoSave) {
            actions.addView(
                makeActionButton("撤销删除", "#4DD94343", "#FFFF8A80", 1.15f, 6) {
                    val targetId = state.eventId
                    dismissInternal(appCtx)
                    Toast.makeText(appCtx, "已撤销该笔记账", Toast.LENGTH_SHORT).show()
                    state.onCancel(targetId)
                }
            )
            actions.addView(
                makeActionButton("修改", "#2E24B59A", "#FF5CE1C6", 0.9f, 6) {
                    val targetId = state.eventId
                    dismissInternal(appCtx)
                    state.onTapEdit(targetId)
                }
            )
            actions.addView(
                makeActionButton("保留", "#FF242B29", "#FFE0EAE6", 0.9f, 0) {
                    dismissInternal(appCtx)
                }
            )
        } else {
            actions.addView(
                makeActionButton("忽略", "#FF242B29", "#FFB0BEB9", 0.85f, 6) {
                    val targetId = state.eventId
                    dismissInternal(appCtx)
                    state.onCancel(targetId)
                }
            )
            actions.addView(
                makeActionButton("确认并修改", "#2E24B59A", "#FF5CE1C6", 1.15f, 6) {
                    val targetId = state.eventId
                    dismissInternal(appCtx)
                    state.onConfirm(targetId, true)
                }
            )
            actions.addView(
                makeActionButton("确认入账", "#FF1C9E85", "#FFFFFFFF", 1.0f, 0) {
                    val targetId = state.eventId
                    dismissInternal(appCtx)
                    Toast.makeText(appCtx, "已入账", Toast.LENGTH_SHORT).show()
                    state.onConfirm(targetId, false)
                }
            )
        }

        card.addView(actions)
        return card
    }

    private data class ScreenMetrics(
        val width: Int,
        val height: Int,
        val safeTop: Int,
    )

    private fun resolveScreenMetrics(context: Context, wm: WindowManager): ScreenMetrics {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val metrics = wm.currentWindowMetrics
                val bounds = metrics.bounds
                val insets = metrics.windowInsets.getInsetsIgnoringVisibility(
                    WindowInsets.Type.statusBars() or WindowInsets.Type.displayCutout()
                )
                ScreenMetrics(bounds.width(), bounds.height(), insets.top)
            } else {
                val dm = context.resources.displayMetrics
                ScreenMetrics(dm.widthPixels, dm.heightPixels, (28 * dm.density).toInt())
            }
        } catch (_: Exception) {
            val dm = context.resources.displayMetrics
            ScreenMetrics(dm.widthPixels, dm.heightPixels, (32 * dm.density).toInt())
        }
    }

    private fun formatSignedAmount(type: String, amount: Double): String {
        val sign = when (type) {
            "income" -> "+"
            "transfer" -> "⇄"
            else -> "-"
        }
        return "$sign¥${String.format(Locale.US, "%.2f", amount)}"
    }

    private fun dotColorFor(type: String): Int {
        return when (type) {
            "income" -> Color.parseColor("#3987E5")
            "transfer" -> Color.parseColor("#EDA100")
            else -> Color.parseColor("#24B59A")
        }
    }

    private fun cancelAutoDismiss() {
        dismissRunnable?.let { mainHandler.removeCallbacks(it) }
        dismissRunnable = null
    }

    private fun scheduleAutoDismiss(context: Context, delayMs: Long) {
        cancelAutoDismiss()
        val r = Runnable { dismissInternal(context) }
        dismissRunnable = r
        mainHandler.postDelayed(r, delayMs)
    }

    private fun dismissInternal(context: Context) {
        cancelAutoDismiss()
        val view = rootContainer ?: return
        rootContainer = null
        layoutParams = null
        currentState = null
        isExpanded = false
        try {
            val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            wm.removeViewImmediate(view)
        } catch (_: Exception) {
        }
    }
}
