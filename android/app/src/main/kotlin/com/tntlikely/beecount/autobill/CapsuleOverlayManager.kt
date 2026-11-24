package com.tntlikely.beecount.autobill

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
import android.view.View
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.widget.LinearLayout
import android.widget.TextView
import java.util.Locale

/**
 * 荣耀 Magic 8「灵动胶囊」风格顶部悬浮窗。
 *
 * - 定位在屏幕顶部打孔区/状态栏区域居中（自动读取 DisplayCutout 安全高度）
 * - 默认自动入账，4.5 秒后自动收起
 * - 点击胶囊立刻拉起 App 进入该笔账单快速修改
 * - 若 60 秒窗口内收到更精确来源（如银行短信尾号），原地平滑更新胶囊文案
 */
object CapsuleOverlayManager {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var currentView: View? = null
    private var currentEventId: String? = null
    private var dismissRunnable: Runnable? = null

    private var amountView: TextView? = null
    private var subtitleView: TextView? = null
    private var dotView: View? = null

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
        onTapEdit: (String) -> Unit,
    ) {
        val appCtx = context.applicationContext
        if (!canDrawOverlays(appCtx)) return

        mainHandler.post {
            try {
                if (currentView != null && currentEventId == eventId) {
                    updateContent(type, amount, merchant, accountLabel, upgraded)
                    scheduleAutoDismiss(appCtx)
                    return@post
                }

                dismissInternal(appCtx)

                val wm = appCtx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
                val density = appCtx.resources.displayMetrics.density
                fun dp(v: Int): Int = (v * density).toInt()

                val root = LinearLayout(appCtx).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setPadding(dp(14), dp(9), dp(14), dp(9))
                    elevation = dp(10).toFloat()
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.RECTANGLE
                        cornerRadius = dp(24).toFloat()
                        setColor(Color.parseColor("#F2121615"))
                        setStroke(dp(1), Color.parseColor("#33FFFFFF"))
                    }
                }

                val dot = View(appCtx).apply {
                    layoutParams = LinearLayout.LayoutParams(dp(8), dp(8)).apply {
                        marginEnd = dp(8)
                    }
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.OVAL
                        setColor(dotColorFor(type))
                    }
                }
                dotView = dot
                root.addView(dot)

                val amountTv = TextView(appCtx).apply {
                    setTextColor(Color.WHITE)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                    isSingleLine = true
                }
                amountView = amountTv
                root.addView(amountTv)

                val subTv = TextView(appCtx).apply {
                    layoutParams = LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                    ).apply {
                        marginStart = dp(8)
                    }
                    setTextColor(Color.parseColor("#CCECEFEA"))
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                    maxWidth = dp(155)
                    isSingleLine = true
                    ellipsize = TextUtils.TruncateAt.END
                }
                subtitleView = subTv
                root.addView(subTv)

                val actionChip = TextView(appCtx).apply {
                    layoutParams = LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                    ).apply {
                        marginStart = dp(10)
                    }
                    text = "修改"
                    setTextColor(Color.parseColor("#5CE1C6"))
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
                    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                    setPadding(dp(8), dp(3), dp(8), dp(3))
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.RECTANGLE
                        cornerRadius = dp(12).toFloat()
                        setColor(Color.parseColor("#2424B59A"))
                    }
                }
                root.addView(actionChip)

                updateContent(type, amount, merchant, accountLabel, upgraded)

                root.setOnClickListener {
                    val targetId = currentEventId ?: eventId
                    dismissInternal(appCtx)
                    onTapEdit(targetId)
                }

                val topOffset = resolveTopOffset(appCtx, wm, dp(8))
                val lp = WindowManager.LayoutParams(
                    WindowManager.LayoutParams.WRAP_CONTENT,
                    WindowManager.LayoutParams.WRAP_CONTENT,
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                        WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                        WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                    PixelFormat.TRANSLUCENT,
                ).apply {
                    gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                    y = topOffset
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        layoutInDisplayCutoutMode =
                            WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                    }
                }

                root.alpha = 0f
                root.scaleX = 0.82f
                root.scaleY = 0.82f
                wm.addView(root, lp)
                currentView = root
                currentEventId = eventId

                root.animate()
                    .alpha(1f)
                    .scaleX(1f)
                    .scaleY(1f)
                    .setDuration(220L)
                    .setInterpolator(DecelerateInterpolator())
                    .start()

                scheduleAutoDismiss(appCtx)
            } catch (e: Exception) {
                android.util.Log.e("CapsuleOverlay", "显示灵动胶囊失败: ${e.message}", e)
            }
        }
    }

    private fun resolveTopOffset(context: Context, wm: WindowManager, defaultPad: Int): Int {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val cutout = wm.currentWindowMetrics.windowInsets.displayCutout
                if (cutout != null && cutout.safeInsetTop > 0) {
                    // 荣耀 Magic 8 居中挖孔胶囊区：紧贴或略微包裹挖孔下方视觉中心
                    return maxOf(defaultPad, cutout.boundingRectTop.top + (defaultPad / 2))
                }
            }
            defaultPad
        } catch (_: Exception) {
            defaultPad
        }
    }

    private fun updateContent(
        type: String,
        amount: Double,
        merchant: String?,
        accountLabel: String?,
        upgraded: Boolean,
    ) {
        val sign = when (type) {
            "income" -> "+"
            "transfer" -> "⇄"
            else -> "-"
        }
        val formatted = String.format(Locale.US, "%.2f", amount)
        amountView?.text = "$sign¥$formatted"

        val parts = mutableListOf<String>()
        if (!merchant.isNullOrBlank()) parts.add(merchant)
        if (!accountLabel.isNullOrBlank()) parts.add(accountLabel)
        if (parts.isEmpty()) {
            parts.add(if (type == "income") "自动记入收入" else "已自动入账")
        }
        val joined = parts.joinToString(" · ")
        subtitleView?.text = if (upgraded) "✓ $joined" else joined

        (dotView?.background as? GradientDrawable)?.setColor(dotColorFor(type))
    }

    private fun dotColorFor(type: String): Int {
        return when (type) {
            "income" -> Color.parseColor("#3987E5")
            "transfer" -> Color.parseColor("#EDA100")
            else -> Color.parseColor("#24B59A")
        }
    }

    private fun scheduleAutoDismiss(context: Context) {
        dismissRunnable?.let { mainHandler.removeCallbacks(it) }
        val r = Runnable { dismissInternal(context) }
        dismissRunnable = r
        mainHandler.postDelayed(r, 4500L)
    }

    private fun dismissInternal(context: Context) {
        dismissRunnable?.let { mainHandler.removeCallbacks(it) }
        dismissRunnable = null
        val view = currentView ?: return
        currentView = null
        currentEventId = null
        amountView = null
        subtitleView = null
        dotView = null
        try {
            val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            wm.removeViewImmediate(view)
        } catch (_: Exception) {
        }
    }
}
