package com.tntlikely.beecount.autobill

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * 引擎二：前台支付完成页无障碍监听服务（仅监听微信、支付宝与银行 App）。
 */
class AutoBillAccessibilityService : AccessibilityService() {
    companion object {
        private const val THROTTLE_MS = 600L
        private const val MAX_NODES = 120
        private val PAYMENT_PAGE_TRIGGERS = listOf(
            "支付成功",
            "付款成功",
            "交易成功",
            "收款成功",
            "付款方式",
            "微信支付凭证",
        )
    }

    private var lastScanTimeMs = 0L
    private var lastContentHash = 0

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val pkg = event.packageName?.toString() ?: return
        if (pkg == applicationContext.packageName) return
        if (!AutoBillRuleEngineNative.isWatchedAccessibilityPackage(applicationContext, pkg)) return
        if (!AutoBillStore.isEnabled(applicationContext)) return

        val now = System.currentTimeMillis()
        if (now - lastScanTimeMs < THROTTLE_MS) return
        lastScanTimeMs = now

        val root = rootInActiveWindow ?: return
        try {
            val lines = ArrayList<String>(48)
            collectText(root, lines, 0)
            if (lines.isEmpty()) return

            val fullText = lines.joinToString("\n")
            if (PAYMENT_PAGE_TRIGGERS.none { fullText.contains(it) }) return

            val hash = fullText.hashCode()
            if (hash == lastContentHash) return
            lastContentHash = hash

            AutoBillCoordinator.onRawCapture(
                context = applicationContext,
                sourceType = "accessibility_screen",
                packageName = pkg,
                title = lines.firstOrNull().orEmpty(),
                text = fullText,
                timestampMs = now,
            )
        } catch (_: Exception) {
        } finally {
            try {
                root.recycle()
            } catch (_: Exception) {
            }
        }
    }

    override fun onInterrupt() {
        // No-op
    }

    private fun collectText(node: AccessibilityNodeInfo?, out: MutableList<String>, depth: Int) {
        if (node == null || out.size >= MAX_NODES || depth > 16) return
        val text = node.text?.toString()?.trim()
        if (!text.isNullOrEmpty() && text.length <= 80) {
            out.add(text)
        } else {
            val desc = node.contentDescription?.toString()?.trim()
            if (!desc.isNullOrEmpty() && desc.length <= 80) {
                out.add(desc)
            }
        }
        val count = node.childCount
        for (i in 0 until count) {
            if (out.size >= MAX_NODES) break
            val child = node.getChild(i) ?: continue
            try {
                collectText(child, out, depth + 1)
            } finally {
                try {
                    child.recycle()
                } catch (_: Exception) {
                }
            }
        }
    }
}
