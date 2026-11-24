package com.tntlikely.beecount.autobill

import android.content.Context
import org.json.JSONObject
import kotlin.math.abs

data class NativeParsedBill(
    val amount: Double,
    val type: String, // "expense" | "income" | "transfer"
    val merchant: String?,
    val accountHint: String?,
    val bankName: String?,
    val cardLastFour: String?,
    val precisionScore: Int,
    val sourceType: String,
    val packageName: String,
    val rawText: String,
    val timestampMs: Long,
)

private data class NativeRuleSpec(
    val id: String,
    val channel: String,
    val sourceType: String,
    val packages: Set<String>,
    val titleWhitelist: List<String>,
    val anchors: List<String>,
    val requireBankOrCard: Boolean,
    val type: String,
    val regex: Regex,
    val amountGroup: Int,
    val merchantGroup: Int?,
    val defaultAccount: String?,
)

/**
 * 原生侧单一规则源引擎：直接读取打包在 APK 内的 `flutter_assets/assets/auto_bill_rules.json`，
 * 与 Dart 层 `AutoBillRuleEngine` 共享同一份规则库，避免双份正则漂移。
 */
object AutoBillRuleEngineNative {
    @Volatile
    private var loaded = false
    private val lock = Any()

    private var noiseKeywords: List<String> = emptyList()
    private var intermediaryMerchants: Set<String> = emptySet()
    private var genericTitles: Set<String> = emptySet()
    private var balanceStripRegex: Regex = Regex(
        "(?:当前|可用|账户|活期|卡内|剩余)?(?:余额|额度)[为是:\\s]*(?:人民币|RMB|CNY|¥)?\\s*[\\d,]+(?:\\.\\d{1,2})?\\s*元?"
    )
    private var bankAliases: LinkedHashMap<String, String> = linkedMapOf()
    private var smsPackages: Set<String> = emptySet()
    private var bankPackages: Set<String> = emptySet()
    private var rules: List<NativeRuleSpec> = emptyList()

    private val cardPatterns = listOf(
        Regex("尾号(?:为)?\\s*(\\d{4})"),
        Regex("(?:储蓄卡|借记卡|信用卡|贷记卡|银行卡|账户|账号)\\s*[\\(\\*]*(\\d{4})\\)?"),
        Regex("银行\\s*\\((\\d{4})\\)"),
        Regex("\\*{2,4}(\\d{4})"),
    )

    private val foreignCurrencyAmountRegex = Regex(
        "(?<![A-Za-z])(?:USD|SGD|EUR|GBP|JPY|HKD|CAD|AUD|KRW|CHF|NZD|TWD|THB|MYR|MOP)\\s*[\\d,]+(?:\\.\\d{1,2})?",
        RegexOption.IGNORE_CASE,
    )

    private val rmbAmountRegex = Regex(
        "(?:人民币|RMB|CNY|¥)\\s*[\\d,]+(?:\\.\\d{1,2})?|[\\d,]+(?:\\.\\d{1,2})?\\s*元"
    )

    private val fallbackMerchantPatterns = listOf(
        Regex("(?:收款方|商户名称|商家|商品|对方账户|交易对方)[:\\s]+([^\\n,，。;；()（）]{2,28})"),
        Regex("在\\s*[【\\[]?([^\\n,，。;；\\]】()（）]{2,24}?)[】\\]]?\\s*(?:消费|支付|付款|刷卡)"),
    )

    fun ensureLoaded(context: Context) {
        if (loaded) return
        synchronized(lock) {
            if (loaded) return
            try {
                val jsonStr = context.applicationContext.assets
                    .open("flutter_assets/assets/auto_bill_rules.json")
                    .bufferedReader(Charsets.UTF_8)
                    .use { it.readText() }
                loadFromJson(jsonStr)
                loaded = true
            } catch (e: Exception) {
                android.util.Log.e("AutoBillRules", "加载 auto_bill_rules.json 失败: ${e.message}", e)
            }
        }
    }

    private fun loadFromJson(jsonStr: String) {
        val root = JSONObject(jsonStr)
        val smsSet = mutableSetOf<String>()
        root.optJSONArray("smsPackages")?.let { arr ->
            for (i in 0 until arr.length()) smsSet.add(arr.optString(i))
        }
        val bankSet = mutableSetOf<String>()
        root.optJSONArray("bankPackages")?.let { arr ->
            for (i in 0 until arr.length()) bankSet.add(arr.optString(i))
        }
        smsPackages = smsSet
        bankPackages = bankSet

        val noises = mutableListOf<String>()
        root.optJSONArray("noiseKeywords")?.let { arr ->
            for (i in 0 until arr.length()) noises.add(arr.optString(i))
        }
        noiseKeywords = noises

        val intermediaries = mutableSetOf<String>()
        root.optJSONArray("intermediaryMerchants")?.let { arr ->
            for (i in 0 until arr.length()) intermediaries.add(arr.optString(i))
        }
        intermediaryMerchants = intermediaries

        val generics = mutableSetOf<String>()
        root.optJSONArray("genericTitles")?.let { arr ->
            for (i in 0 until arr.length()) generics.add(arr.optString(i))
        }
        genericTitles = generics

        root.optString("balanceStripRegex").takeIf { it.isNotEmpty() }?.let {
            balanceStripRegex = Regex(it)
        }

        val aliases = linkedMapOf<String, String>()
        root.optJSONObject("bankAliases")?.let { obj ->
            val keys = obj.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                aliases[k] = obj.optString(k)
            }
        }
        bankAliases = aliases

        val parsedRules = mutableListOf<NativeRuleSpec>()
        root.optJSONArray("rules")?.let { arr ->
            for (i in 0 until arr.length()) {
                val obj = arr.optJSONObject(i) ?: continue
                val pkgs = mutableSetOf<String>()
                obj.optJSONArray("packages")?.let { pArr ->
                    for (j in 0 until pArr.length()) {
                        when (val p = pArr.optString(j)) {
                            "@BANK_PACKAGES" -> pkgs.addAll(bankSet)
                            "@SMS_PACKAGES" -> pkgs.addAll(smsSet)
                            else -> pkgs.add(p)
                        }
                    }
                }
                val titles = mutableListOf<String>()
                obj.optJSONArray("titleWhitelist")?.let { tArr ->
                    for (j in 0 until tArr.length()) titles.add(tArr.optString(j))
                }
                val anchors = mutableListOf<String>()
                obj.optJSONArray("anchors")?.let { aArr ->
                    for (j in 0 until aArr.length()) anchors.add(aArr.optString(j))
                }
                val merchantGroup = if (obj.has("merchantGroup") && !obj.isNull("merchantGroup")) {
                    obj.optInt("merchantGroup")
                } else {
                    null
                }
                parsedRules.add(
                    NativeRuleSpec(
                        id = obj.optString("id"),
                        channel = obj.optString("channel", "notice"),
                        sourceType = obj.optString("sourceType", "payment_notification"),
                        packages = pkgs,
                        titleWhitelist = titles,
                        anchors = anchors,
                        requireBankOrCard = obj.optBoolean("requireBankOrCard", false),
                        type = obj.optString("type", "expense"),
                        regex = Regex(obj.optString("regex"), setOf(RegexOption.DOT_MATCHES_ALL)),
                        amountGroup = obj.optInt("amountGroup", 1),
                        merchantGroup = merchantGroup,
                        defaultAccount = obj.optString("defaultAccount").takeIf { it.isNotEmpty() },
                    )
                )
            }
        }
        rules = parsedRules
    }

    fun classifyNotificationSource(context: Context, packageName: String): String? {
        ensureLoaded(context)
        return when {
            smsPackages.contains(packageName) -> "bank_sms"
            bankPackages.contains(packageName) -> "bank_notification"
            packageName == "com.tencent.mm" || packageName == "com.eg.android.AlipayGphone" ->
                "payment_notification"
            else -> null
        }
    }

    fun isWatchedAccessibilityPackage(context: Context, packageName: String): Boolean {
        ensureLoaded(context)
        return packageName == "com.tencent.mm" ||
            packageName == "com.eg.android.AlipayGphone" ||
            bankPackages.contains(packageName)
    }

    fun isIntermediaryMerchant(name: String?): Boolean {
        if (name.isNullOrBlank()) return true
        val trimmed = name.trim()
        return intermediaryMerchants.any { trimmed == it || trimmed.contains(it) }
    }

    fun parse(
        context: Context,
        sourceType: String,
        packageName: String,
        title: String,
        text: String,
        timestampMs: Long,
    ): NativeParsedBill? {
        ensureLoaded(context)
        val normTitle = normalize(title)
        val normText = normalize(text)
        val combined = when {
            normTitle.isEmpty() -> normText
            normText.isEmpty() -> normTitle
            else -> "$normTitle\n$normText"
        }
        if (combined.isEmpty()) return null

        if (sourceType != "manual_test") {
            if (noiseKeywords.any { combined.contains(it) }) return null
        }

        val bankName = bankAliases.entries.firstOrNull { combined.contains(it.key) }?.value
        val cardLastFour = cardPatterns.firstNotNullOfOrNull { it.find(combined)?.groupValues?.getOrNull(1) }
        val withoutBalance = balanceStripRegex.replace(combined, " ")
        val parseText = if (foreignCurrencyAmountRegex.containsMatchIn(withoutBalance)) {
            if (!rmbAmountRegex.containsMatchIn(withoutBalance)) {
                return null
            }
            foreignCurrencyAmountRegex.replace(withoutBalance, " ")
        } else {
            withoutBalance
        }
        val channel = when (sourceType) {
            "bank_sms" -> "sms"
            "accessibility_screen" -> "accessibility"
            else -> "notice"
        }

        for (rule in rules) {
            if (sourceType != "manual_test") {
                if (rule.channel != channel) continue
                if (rule.packages.isNotEmpty() && !rule.packages.contains(packageName)) continue
                if (rule.titleWhitelist.isNotEmpty() && rule.titleWhitelist.none { normTitle.contains(it) }) continue
                if (rule.anchors.isNotEmpty() && rule.anchors.none { combined.contains(it) }) continue
                if (rule.requireBankOrCard && bankName == null && cardLastFour == null) continue
            } else {
                if (rule.channel != "notice") continue
                if (rule.packages.isNotEmpty() && !rule.packages.contains(packageName)) continue
            }

            val match = rule.regex.find(parseText) ?: continue
            val amountRaw = match.groupValues.getOrNull(rule.amountGroup)?.replace(",", "")
            val amount = amountRaw?.toDoubleOrNull() ?: continue
            if (amount <= 0.0 || amount >= 10_000_000.0) continue

            val rawMerchant = rule.merchantGroup?.let { match.groupValues.getOrNull(it) }
            val merchant = cleanMerchant(rawMerchant, bankName)
                ?: extractMerchantFallback(combined, bankName)
                ?: cleanMerchant(normTitle, bankName)

            val accountHint = extractAccountHint(combined, bankName, cardLastFour, rule.defaultAccount)
            val precision = computePrecisionScore(sourceType, cardLastFour, bankName, accountHint)

            return NativeParsedBill(
                amount = amount,
                type = rule.type,
                merchant = merchant,
                accountHint = accountHint,
                bankName = bankName,
                cardLastFour = cardLastFour,
                precisionScore = precision,
                sourceType = sourceType,
                packageName = packageName,
                rawText = combined,
                timestampMs = timestampMs,
            )
        }
        return null
    }

    private fun normalize(raw: String): String {
        return raw
            .replace('（', '(')
            .replace('）', ')')
            .replace('：', ':')
            .replace('￥', '¥')
            .replace('\u00A0', ' ')
            .replace('\u3000', ' ')
            .replace(Regex("[ \\t]+"), " ")
            .trim()
    }

    private fun extractAccountHint(
        text: String,
        bankName: String?,
        cardLastFour: String?,
        defaultAccount: String?,
    ): String? {
        val isCredit = text.contains("信用卡") || text.contains("贷记卡")
        if (bankName != null && cardLastFour != null) {
            return "$bankName${if (isCredit) "信用卡" else "储蓄卡"}($cardLastFour)"
        }
        if (cardLastFour != null) {
            return "${if (isCredit) "信用卡" else "银行卡"}($cardLastFour)"
        }
        if (text.contains("零钱通")) return "零钱通"
        if (text.contains("余额宝")) return "余额宝"
        if (text.contains("花呗")) return "花呗"
        if (text.contains("零钱")) return "零钱"
        if (text.contains("账户余额")) return "账户余额"
        if (bankName != null) return bankName
        return defaultAccount
    }

    private fun extractMerchantFallback(normalized: String, bankName: String?): String? {
        for (p in fallbackMerchantPatterns) {
            val m = p.find(normalized)?.groupValues?.getOrNull(1)
            val cleaned = cleanMerchant(m, bankName)
            if (cleaned != null) return cleaned
        }
        return null
    }

    private fun cleanMerchant(raw: String?, bankName: String?): String? {
        if (raw == null) return null
        val s = raw.trim().trim('【', '】', '[', ']', ':', '：', '-', ' ')
        if (s.length < 2 || s.length > 28) return null
        if (Regex("^[\\d\\.\\-¥￥,元\\s]+$").matches(s)) return null
        if (genericTitles.contains(s)) return null
        if (bankName != null && (s == bankName || s == "${bankName}通知")) return null
        return s
    }

    private fun computePrecisionScore(
        sourceType: String,
        cardLastFour: String?,
        bankName: String?,
        accountHint: String?,
    ): Int {
        var score = when (sourceType) {
            "bank_sms", "bank_notification" -> 15
            "payment_notification", "manual_test" -> 10
            else -> 5
        }
        if (!cardLastFour.isNullOrEmpty()) {
            score += 100
            if (bankName != null) score += 20
        } else if (accountHint in setOf("零钱通", "零钱", "余额宝", "花呗", "账户余额")) {
            score += 60
        } else if (bankName != null) {
            score += 40
        } else if (accountHint != null) {
            score += 20
        }
        return score
    }

    fun isSameAmount(a: Double, b: Double): Boolean = abs(a - b) <= 0.005
}
