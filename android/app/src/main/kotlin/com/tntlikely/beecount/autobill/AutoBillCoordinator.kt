package com.tntlikely.beecount.autobill

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.tntlikely.beecount.MainActivity
import java.util.Locale
import java.util.UUID
import kotlin.math.abs

/**
 * Android 原生无感记账调度中心：
 * 1. 使用单一规则源 [AutoBillRuleEngineNative]（读取 `assets/auto_bill_rules.json`）解析
 * 2. 跨渠道 60 秒窗口合并（银行卡尾号 > 子账户 > 泛渠道，保留真实商户名不被「财付通/支付宝」覆盖）
 * 3. 同渠道仅 3 秒防抖（连续两次扫码不误杀）
 * 4. 弹出/原地升级「侧边吸边悬浮球」，支持自动入账后一键撤销或手动确认入账
 */
object AutoBillCoordinator {
    const val EXTRA_EDIT_EVENT_ID = "extra_edit_auto_bill_event_id"
    private const val CROSS_CHANNEL_WINDOW_MS = 60_000L
    private const val SAME_CHANNEL_DEBOUNCE_MS = 3_000L

    private data class RecentEntry(
        val eventId: String,
        val bill: NativeParsedBill,
        val autoSaved: Boolean,
        val mappedAccount: String?,
    )

    private data class ManualDraft(
        val bill: NativeParsedBill,
        val payload: Map<String, Any>,
        val mappedAccount: String?,
    )

    private val lock = Any()
    private val recentEntries = mutableListOf<RecentEntry>()
    private val pendingManualEvents = mutableMapOf<String, ManualDraft>()
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var liveEventListener: ((Map<String, Any>) -> Unit)? = null

    @Volatile
    private var liveEditListener: ((String) -> Unit)? = null

    @Volatile
    private var liveCancelListener: ((String) -> Unit)? = null

    @Volatile
    var pendingEditEventId: String? = null

    fun attachFlutterListeners(
        onEvent: (Map<String, Any>) -> Unit,
        onEdit: (String) -> Unit,
        onCancel: (String) -> Unit,
    ) {
        liveEventListener = onEvent
        liveEditListener = onEdit
        liveCancelListener = onCancel
    }

    fun detachFlutterListeners() {
        liveEventListener = null
        liveEditListener = null
        liveCancelListener = null
    }

    fun consumePendingEditEventId(): String? {
        val id = pendingEditEventId
        pendingEditEventId = null
        return id
    }

    fun onRawCapture(
        context: Context,
        sourceType: String,
        packageName: String,
        title: String,
        text: String,
        timestampMs: Long = System.currentTimeMillis(),
    ) {
        val appCtx = context.applicationContext
        if (sourceType != "manual_test" && !AutoBillStore.isEnabled(appCtx)) {
            return
        }

        val parsed = AutoBillRuleEngineNative.parse(
            context = appCtx,
            sourceType = sourceType,
            packageName = packageName,
            title = title,
            text = text,
            timestampMs = timestampMs,
        ) ?: return

        val mappedAccountHint = AutoBillStore.resolveMappedAccountLabel(
            context = appCtx,
            rawText = parsed.rawText,
            accountHint = parsed.accountHint,
            cardLastFour = parsed.cardLastFour,
        )

        var targetEventId: String
        var isUpdate = false
        var effectiveBill = parsed
        var effectiveAutoSave: Boolean

        synchronized(lock) {
            recentEntries.removeAll { abs(timestampMs - it.bill.timestampMs) > CROSS_CHANNEL_WINDOW_MS }

            val matchedIndex = recentEntries.indexOfLast { entry ->
                if (entry.bill.type != parsed.type) return@indexOfLast false
                if (!AutoBillRuleEngineNative.isSameAmount(entry.bill.amount, parsed.amount)) {
                    return@indexOfLast false
                }
                val delta = abs(timestampMs - entry.bill.timestampMs)
                val sameChannel = entry.bill.sourceType == parsed.sourceType &&
                    entry.bill.packageName == parsed.packageName
                if (sameChannel) {
                    delta <= SAME_CHANNEL_DEBOUNCE_MS
                } else {
                    delta <= CROSS_CHANNEL_WINDOW_MS
                }
            }

            if (matchedIndex >= 0) {
                val existing = recentEntries[matchedIndex]
                val merged = mergeBills(existing.bill, parsed)
                if (!isImproved(existing.bill, merged)) {
                    AutoBillStore.appendLog(
                        appCtx,
                        sourceType,
                        "去重跳过 ¥${String.format(Locale.US, "%.2f", parsed.amount)} (${parsed.accountHint ?: packageName})",
                    )
                    return
                }
                targetEventId = existing.eventId
                isUpdate = true
                effectiveBill = merged
                effectiveAutoSave = existing.autoSaved && !pendingManualEvents.containsKey(targetEventId)
                val mergedAccount = AutoBillStore.resolveMappedAccountLabel(
                    context = appCtx,
                    rawText = merged.rawText,
                    accountHint = merged.accountHint,
                    cardLastFour = merged.cardLastFour,
                )
                recentEntries[matchedIndex] = RecentEntry(
                    eventId = targetEventId,
                    bill = merged,
                    autoSaved = effectiveAutoSave,
                    mappedAccount = mergedAccount,
                )
            } else {
                targetEventId = UUID.randomUUID().toString()
                effectiveAutoSave = AutoBillStore.isAutoSaveEnabled(appCtx)
                recentEntries.add(
                    RecentEntry(
                        eventId = targetEventId,
                        bill = parsed,
                        autoSaved = effectiveAutoSave,
                        mappedAccount = mappedAccountHint,
                    )
                )
            }
        }

        val mappedAccount = AutoBillStore.resolveMappedAccountLabel(
            context = appCtx,
            rawText = effectiveBill.rawText,
            accountHint = effectiveBill.accountHint,
            cardLastFour = effectiveBill.cardLastFour,
        )

        val payload = mapOf<String, Any>(
            "eventId" to targetEventId,
            "sourceType" to effectiveBill.sourceType,
            "packageName" to effectiveBill.packageName,
            "title" to title,
            "text" to effectiveBill.rawText,
            "timestampMs" to effectiveBill.timestampMs,
            "isUpdate" to isUpdate,
        )

        val amountStr = String.format(Locale.US, "%.2f", effectiveBill.amount)
        val merchantLabel = effectiveBill.merchant ?: "未命名商户"
        val accountLabel = mappedAccount ?: "默认账户"

        if (effectiveAutoSave) {
            AutoBillStore.upsertPendingEvent(appCtx, payload)
            AutoBillStore.appendLog(
                appCtx,
                effectiveBill.sourceType,
                "${if (isUpdate) "合并升级" else "自动入账"} ¥$amountStr · $merchantLabel · $accountLabel",
            )
            liveEventListener?.let { listener ->
                mainHandler.post { listener(payload) }
            }
        } else {
            synchronized(lock) {
                pendingManualEvents[targetEventId] = ManualDraft(effectiveBill, payload, mappedAccount)
            }
            AutoBillStore.appendLog(
                appCtx,
                effectiveBill.sourceType,
                "${if (isUpdate) "更新待确认" else "待确认"} ¥$amountStr · $merchantLabel · $accountLabel",
            )
        }

        CapsuleOverlayManager.showOrUpdate(
            context = appCtx,
            eventId = targetEventId,
            type = effectiveBill.type,
            amount = effectiveBill.amount,
            merchant = effectiveBill.merchant,
            accountLabel = mappedAccount,
            upgraded = isUpdate,
            autoSave = effectiveAutoSave,
            onConfirm = { id, openEditor ->
                confirmManualBill(appCtx, id, openEditor)
            },
            onCancel = { id ->
                cancelBill(appCtx, id)
            },
            onTapEdit = { tappedId ->
                openAppForEdit(appCtx, tappedId)
            },
        )
    }

    fun confirmManualBill(context: Context, eventId: String, openEditor: Boolean) {
        val appCtx = context.applicationContext
        val draft = synchronized(lock) {
            val popped = pendingManualEvents.remove(eventId)
            val idx = recentEntries.indexOfLast { it.eventId == eventId }
            if (idx >= 0) {
                recentEntries[idx] = recentEntries[idx].copy(autoSaved = true)
            }
            popped
        } ?: return

        val amountStr = String.format(Locale.US, "%.2f", draft.bill.amount)
        val merchantLabel = draft.bill.merchant ?: "未命名商户"
        val accountLabel = draft.mappedAccount ?: "默认账户"

        AutoBillStore.upsertPendingEvent(appCtx, draft.payload)
        AutoBillStore.appendLog(
            appCtx,
            draft.bill.sourceType,
            "确认入账 ¥$amountStr · $merchantLabel · $accountLabel",
        )

        liveEventListener?.let { listener ->
            mainHandler.post { listener(draft.payload) }
        }
        if (openEditor) {
            mainHandler.postDelayed({ openAppForEdit(appCtx, eventId) }, 150L)
        }
    }

    fun cancelBill(context: Context, eventId: String) {
        val appCtx = context.applicationContext
        var logSummary: String? = null
        var logSource = "auto_bill"

        synchronized(lock) {
            val draft = pendingManualEvents.remove(eventId)
            val entry = recentEntries.firstOrNull { it.eventId == eventId }
            recentEntries.removeAll { it.eventId == eventId }
            val bill = draft?.bill ?: entry?.bill
            if (bill != null) {
                logSource = bill.sourceType
                val amountStr = String.format(Locale.US, "%.2f", bill.amount)
                val acct = draft?.mappedAccount ?: entry?.mappedAccount ?: bill.accountHint ?: "默认账户"
                logSummary = "已撤销/忽略 ¥$amountStr ($acct)"
            }
        }

        AutoBillStore.removePendingEvent(appCtx, eventId)
        AutoBillStore.addPendingCancelEventId(appCtx, eventId)
        AutoBillStore.appendLog(appCtx, logSource, logSummary ?: "已撤销/忽略 ($eventId)")

        liveCancelListener?.let { listener ->
            mainHandler.post { listener(eventId) }
        }
    }

    fun triggerTestCapsule(context: Context) {
        onRawCapture(
            context = context,
            sourceType = "manual_test",
            packageName = "com.tencent.mm",
            title = "微信支付",
            text = "微信支付凭证：你已使用零钱通向瑞幸咖啡付款¥28.50",
            timestampMs = System.currentTimeMillis(),
        )
    }

    private fun openAppForEdit(context: Context, eventId: String) {
        pendingEditEventId = eventId
        val intent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra(EXTRA_EDIT_EVENT_ID, eventId)
        }
        context.startActivity(intent)
        liveEditListener?.let { listener ->
            mainHandler.postDelayed({ listener(eventId) }, 250L)
        }
    }

    private fun mergeBills(existing: NativeParsedBill, incoming: NativeParsedBill): NativeParsedBill {
        val incomingMorePrecise = incoming.precisionScore > existing.precisionScore
        val bestMerchant = pickBetterMerchant(existing.merchant, incoming.merchant)
        return existing.copy(
            merchant = bestMerchant,
            accountHint = if (incomingMorePrecise) incoming.accountHint ?: existing.accountHint else existing.accountHint ?: incoming.accountHint,
            bankName = if (incomingMorePrecise) incoming.bankName ?: existing.bankName else existing.bankName ?: incoming.bankName,
            cardLastFour = if (incomingMorePrecise) incoming.cardLastFour ?: existing.cardLastFour else existing.cardLastFour ?: incoming.cardLastFour,
            precisionScore = if (incomingMorePrecise) incoming.precisionScore else existing.precisionScore,
            sourceType = if (incomingMorePrecise) incoming.sourceType else existing.sourceType,
            rawText = if (incomingMorePrecise) "${existing.rawText}\n${incoming.rawText}" else existing.rawText,
        )
    }

    private fun pickBetterMerchant(a: String?, b: String?): String? {
        val ca = a?.trim().orEmpty()
        val cb = b?.trim().orEmpty()
        if (ca.isEmpty()) return cb.takeIf { it.isNotEmpty() }
        if (cb.isEmpty()) return ca
        val aInter = AutoBillRuleEngineNative.isIntermediaryMerchant(ca)
        val bInter = AutoBillRuleEngineNative.isIntermediaryMerchant(cb)
        if (aInter && !bInter) return cb
        if (!aInter && bInter) return ca
        return if (cb.length > ca.length) cb else ca
    }

    private fun isImproved(before: NativeParsedBill, after: NativeParsedBill): Boolean {
        if (after.precisionScore > before.precisionScore) return true
        if (before.cardLastFour.isNullOrEmpty() && !after.cardLastFour.isNullOrEmpty()) return true
        if (before.accountHint.isNullOrEmpty() && !after.accountHint.isNullOrEmpty()) return true
        if (AutoBillRuleEngineNative.isIntermediaryMerchant(before.merchant) &&
            !AutoBillRuleEngineNative.isIntermediaryMerchant(after.merchant)
        ) {
            return true
        }
        if (before.merchant.isNullOrEmpty() && !after.merchant.isNullOrEmpty()) return true
        return false
    }
}
