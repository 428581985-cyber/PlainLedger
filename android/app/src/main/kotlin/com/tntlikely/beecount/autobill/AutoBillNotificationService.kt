package com.tntlikely.beecount.autobill

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * 引擎一：通知栏与消费短信监听服务（仅监听微信、支付宝与银行推送/短信）。
 *
 * 借鉴 SmartLedger 实战优化：
 * 1. 维护真实绑定状态 [isConnected]，识别 MagicOS 后台“假断开”
 * 2. 跳过 [Notification.FLAG_GROUP_SUMMARY] 折叠摘要，防止重复抓取
 * 3. 展开 [Notification.EXTRA_TEXT_LINES] / [Notification.EXTRA_BIG_TEXT] 还原折叠通知内容
 */
class AutoBillNotificationService : NotificationListenerService() {
    companion object {
        @Volatile
        var isConnected: Boolean = false
            private set
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        isConnected = true
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        isConnected = false
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        val pkg = sbn.packageName ?: return
        if (pkg == applicationContext.packageName) return

        val notification = sbn.notification ?: return
        // 跳过系统聚合摘要通知，避免重复捕获
        if ((notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return

        val sourceType = AutoBillRuleEngineNative.classifyNotificationSource(applicationContext, pkg)
            ?: return
        val extras = notification.extras ?: return

        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        val bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()?.trim()
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim()
        val subText = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString()?.trim()
        val textLines = extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
            ?.mapNotNull { it?.toString()?.trim()?.takeIf { s -> s.isNotEmpty() } }
            .orEmpty()

        val timestampMs = if (sbn.postTime > 0) sbn.postTime else System.currentTimeMillis()

        // 优先处理多行折叠通知（例如微信/银行多条合并时的最后一条最新动账）
        if (textLines.isNotEmpty()) {
            val latestLine = textLines.last()
            AutoBillCoordinator.onRawCapture(
                context = applicationContext,
                sourceType = sourceType,
                packageName = pkg,
                title = title,
                text = latestLine,
                timestampMs = timestampMs,
            )
            return
        }

        val combined = listOfNotNull(
            bigText?.takeIf { it.isNotEmpty() } ?: text?.takeIf { it.isNotEmpty() },
            subText?.takeIf { it.isNotEmpty() },
        ).joinToString("\n")

        if (title.isEmpty() && combined.isEmpty()) return

        AutoBillCoordinator.onRawCapture(
            context = applicationContext,
            sourceType = sourceType,
            packageName = pkg,
            title = title,
            text = combined,
            timestampMs = timestampMs,
        )
    }
}
