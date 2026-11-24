import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'auto_bill_models.dart';

class AutoBillRuleSpec {
  const AutoBillRuleSpec({
    required this.id,
    required this.channel,
    required this.sourceType,
    required this.packages,
    required this.titleWhitelist,
    required this.anchors,
    required this.requireBankOrCard,
    required this.type,
    required this.regex,
    required this.amountGroup,
    this.merchantGroup,
    this.defaultAccount,
  });

  final String id;
  final String channel; // 'notice' | 'sms' | 'accessibility'
  final String sourceType;
  final Set<String> packages;
  final List<String> titleWhitelist;
  final List<String> anchors;
  final bool requireBankOrCard;
  final String type; // 'expense' | 'income' | 'transfer'
  final RegExp regex;
  final int amountGroup;
  final int? merchantGroup;
  final String? defaultAccount;
}

/// 单一规则源解析引擎（直接加载 `assets/auto_bill_rules.json`）。
///
/// Android 原生层 `AutoBillRuleEngineNative.kt` 读取同一份 JSON 文件，
/// 保证前后端规则行为完全一致、无双份正则漂移。
class AutoBillRuleEngine {
  AutoBillRuleEngine._({
    required this.noiseKeywords,
    required this.intermediaryMerchants,
    required this.genericTitles,
    required this.balanceStripRegex,
    required this.bankAliases,
    required this.smsPackages,
    required this.bankPackages,
    required this.rules,
  });

  final List<String> noiseKeywords;
  final Set<String> intermediaryMerchants;
  final Set<String> genericTitles;
  final RegExp balanceStripRegex;
  final Map<String, String> bankAliases;
  final Set<String> smsPackages;
  final Set<String> bankPackages;
  final List<AutoBillRuleSpec> rules;

  static AutoBillRuleEngine? _cached;

  static Future<AutoBillRuleEngine> loadFromAssets({
    String assetPath = 'assets/auto_bill_rules.json',
  }) async {
    if (_cached != null) return _cached!;
    final raw = await rootBundle.loadString(assetPath);
    _cached = fromJsonString(raw);
    return _cached!;
  }

  static AutoBillRuleEngine fromJsonString(String jsonStr) {
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    final smsPkgs = ((map['smsPackages'] as List?) ?? const [])
        .map((e) => e.toString())
        .toSet();
    final bankPkgs = ((map['bankPackages'] as List?) ?? const [])
        .map((e) => e.toString())
        .toSet();

    final bankAliasRaw = (map['bankAliases'] as Map?) ?? const {};
    final bankAliases = <String, String>{
      for (final e in bankAliasRaw.entries)
        e.key.toString(): e.value.toString(),
    };

    final rawRules = (map['rules'] as List?) ?? const [];
    final parsedRules = <AutoBillRuleSpec>[];
    for (final item in rawRules) {
      if (item is! Map) continue;
      final pkgs = <String>{};
      for (final p in (item['packages'] as List?) ?? const []) {
        final s = p.toString();
        if (s == '@BANK_PACKAGES') {
          pkgs.addAll(bankPkgs);
        } else if (s == '@SMS_PACKAGES') {
          pkgs.addAll(smsPkgs);
        } else {
          pkgs.add(s);
        }
      }
      parsedRules.add(AutoBillRuleSpec(
        id: item['id']?.toString() ?? '',
        channel: item['channel']?.toString() ?? 'notice',
        sourceType: item['sourceType']?.toString() ?? 'payment_notification',
        packages: pkgs,
        titleWhitelist: ((item['titleWhitelist'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        anchors: ((item['anchors'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        requireBankOrCard: (item['requireBankOrCard'] as bool?) ?? false,
        type: item['type']?.toString() ?? 'expense',
        regex: RegExp(item['regex']?.toString() ?? '', dotAll: true),
        amountGroup: (item['amountGroup'] as num?)?.toInt() ?? 1,
        merchantGroup: (item['merchantGroup'] as num?)?.toInt(),
        defaultAccount: item['defaultAccount']?.toString(),
      ));
    }

    return AutoBillRuleEngine._(
      noiseKeywords: ((map['noiseKeywords'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      intermediaryMerchants:
          ((map['intermediaryMerchants'] as List?) ?? const [])
              .map((e) => e.toString())
              .toSet(),
      genericTitles: ((map['genericTitles'] as List?) ?? const [])
          .map((e) => e.toString())
          .toSet(),
      balanceStripRegex: RegExp(
        map['balanceStripRegex']?.toString() ??
            r'(?:当前|可用|账户|活期|卡内|剩余)?(?:余额|额度)[为是:\s]*(?:人民币|RMB|CNY|¥)?\s*[\d,]+(?:\.\d{1,2})?\s*元?',
      ),
      bankAliases: bankAliases,
      smsPackages: smsPkgs,
      bankPackages: bankPkgs,
      rules: parsedRules,
    );
  }

  /// 解析一条原始事件；未命中任何规则或被噪声/白名单拦截则返回 null。
  ParsedAutoBill? parse(AutoBillRawEvent event) {
    final normTitle = _normalize(event.title);
    final normText = _normalize(event.text);
    final combined = normTitle.isEmpty
        ? normText
        : (normText.isEmpty ? normTitle : '$normTitle\n$normText');
    if (combined.isEmpty) return null;

    if (event.sourceType != AutoBillSourceType.manualTest) {
      if (noiseKeywords.any(combined.contains)) return null;
    }

    final bankInfo = _extractBankAndCard(combined);
    final withoutBalance = combined.replaceAll(balanceStripRegex, ' ');
    final channel = _channelForSource(event.sourceType);

    for (final rule in rules) {
      if (event.sourceType != AutoBillSourceType.manualTest) {
        if (rule.channel != channel) continue;
        if (rule.packages.isNotEmpty &&
            !rule.packages.contains(event.packageName)) {
          continue;
        }
        if (rule.titleWhitelist.isNotEmpty &&
            !rule.titleWhitelist.any(normTitle.contains)) {
          continue;
        }
        if (rule.anchors.isNotEmpty &&
            !rule.anchors.any(combined.contains)) {
          continue;
        }
        if (rule.requireBankOrCard &&
            bankInfo.bankName == null &&
            bankInfo.cardLastFour == null) {
          continue;
        }
      } else {
        // manual_test 仍按包名匹配以复用真实规则
        if (rule.channel != 'notice') continue;
        if (rule.packages.isNotEmpty &&
            !rule.packages.contains(event.packageName)) {
          continue;
        }
      }

      final match = rule.regex.firstMatch(withoutBalance);
      if (match == null) continue;

      final amountRaw = rule.amountGroup <= match.groupCount
          ? match.group(rule.amountGroup)
          : null;
      final amount = _parseAmount(amountRaw);
      if (amount == null || amount <= 0 || amount >= 10000000) continue;

      String? rawMerchant;
      if (rule.merchantGroup != null &&
          rule.merchantGroup! <= match.groupCount) {
        rawMerchant = match.group(rule.merchantGroup!);
      }
      final merchant = _cleanMerchant(rawMerchant, bankName: bankInfo.bankName) ??
          _extractMerchantFallback(combined, bankName: bankInfo.bankName) ??
          _cleanMerchant(normTitle, bankName: bankInfo.bankName);

      final accountHint = _extractAccountHint(
        combined,
        bankName: bankInfo.bankName,
        cardLastFour: bankInfo.cardLastFour,
        defaultAccount: rule.defaultAccount,
      );

      final precision = _computePrecisionScore(
        sourceType: event.sourceType,
        cardLastFour: bankInfo.cardLastFour,
        bankName: bankInfo.bankName,
        accountHint: accountHint,
      );

      return ParsedAutoBill(
        amount: amount,
        type: rule.type,
        merchant: merchant,
        accountHint: accountHint,
        bankName: bankInfo.bankName,
        cardLastFour: bankInfo.cardLastFour,
        precisionScore: precision,
        sourceType: event.sourceType,
        packageName: event.packageName,
        rawText: combined,
        timestamp: event.timestamp,
      );
    }

    return null;
  }

  bool isIntermediaryMerchant(String? name) {
    if (name == null || name.trim().isEmpty) return true;
    final trimmed = name.trim();
    return intermediaryMerchants.any(
      (m) => trimmed == m || trimmed.contains(m),
    );
  }

  String _channelForSource(AutoBillSourceType source) {
    switch (source) {
      case AutoBillSourceType.bankSms:
        return 'sms';
      case AutoBillSourceType.accessibilityScreen:
        return 'accessibility';
      case AutoBillSourceType.bankNotification:
      case AutoBillSourceType.paymentNotification:
      case AutoBillSourceType.manualTest:
        return 'notice';
    }
  }

  static String _normalize(String raw) {
    return raw
        .replaceAll('（', '(')
        .replaceAll('）', ')')
        .replaceAll('：', ':')
        .replaceAll('￥', '¥')
        .replaceAll('\u00A0', ' ')
        .replaceAll('\u3000', ' ')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .trim();
  }

  static double? _parseAmount(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return double.tryParse(raw.replaceAll(',', ''));
  }

  ({String? bankName, String? cardLastFour}) _extractBankAndCard(String text) {
    String? bankName;
    for (final entry in bankAliases.entries) {
      if (text.contains(entry.key)) {
        bankName = entry.value;
        break;
      }
    }

    String? lastFour;
    final cardPatterns = <RegExp>[
      RegExp(r'尾号(?:为)?\s*(\d{4})'),
      RegExp(r'(?:储蓄卡|借记卡|信用卡|贷记卡|银行卡|账户|账号)\s*[\(\*]*(\d{4})\)?'),
      RegExp(r'银行\s*\((\d{4})\)'),
      RegExp(r'\*{2,4}(\d{4})'),
    ];
    for (final p in cardPatterns) {
      final m = p.firstMatch(text);
      if (m != null) {
        lastFour = m.group(1);
        break;
      }
    }
    return (bankName: bankName, cardLastFour: lastFour);
  }

  String? _extractAccountHint(
    String text, {
    required String? bankName,
    required String? cardLastFour,
    required String? defaultAccount,
  }) {
    final isCredit = text.contains('信用卡') || text.contains('贷记卡');
    if (bankName != null && cardLastFour != null) {
      return '$bankName${isCredit ? '信用卡' : '储蓄卡'}($cardLastFour)';
    }
    if (cardLastFour != null) {
      return '${isCredit ? '信用卡' : '银行卡'}($cardLastFour)';
    }
    if (text.contains('零钱通')) return '零钱通';
    if (text.contains('余额宝')) return '余额宝';
    if (text.contains('花呗')) return '花呗';
    if (text.contains('零钱')) return '零钱';
    if (text.contains('账户余额')) return '账户余额';
    if (bankName != null) return bankName;
    return defaultAccount;
  }

  String? _extractMerchantFallback(String normalized, {String? bankName}) {
    final patterns = <RegExp>[
      RegExp(r'(?:收款方|商户名称|商家|商品|对方账户|交易对方)[:\s]+([^\n,，。;；()（）]{2,28})'),
      RegExp(r'在\s*[【\[]?([^\n,，。;；\]】()（）]{2,24}?)[】\]]?\s*(?:消费|支付|付款|刷卡)'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(normalized);
      if (m != null) {
        final cleaned = _cleanMerchant(m.group(1), bankName: bankName);
        if (cleaned != null) return cleaned;
      }
    }
    return null;
  }

  String? _cleanMerchant(String? raw, {String? bankName}) {
    if (raw == null) return null;
    final s = raw
        .replaceAll(RegExp(r'^[【\[\s:：\-]+'), '')
        .replaceAll(RegExp(r'[】\]\s:：\-]+$'), '')
        .trim();
    if (s.length < 2 || s.length > 28) return null;
    if (RegExp(r'^[\d\.\-¥￥,元\s]+$').hasMatch(s)) return null;
    if (genericTitles.contains(s)) return null;
    if (bankName != null && (s == bankName || s == '${bankName}通知')) {
      return null;
    }
    return s;
  }

  static int _computePrecisionScore({
    required AutoBillSourceType sourceType,
    required String? cardLastFour,
    required String? bankName,
    required String? accountHint,
  }) {
    var score = sourceType.sourceReliabilityBonus;
    if (cardLastFour != null && cardLastFour.isNotEmpty) {
      score += 100;
      if (bankName != null) score += 20;
    } else if (accountHint == '零钱通' ||
        accountHint == '零钱' ||
        accountHint == '余额宝' ||
        accountHint == '花呗' ||
        accountHint == '账户余额') {
      score += 60;
    } else if (bankName != null) {
      score += 40;
    } else if (accountHint != null) {
      score += 20;
    }
    return score;
  }
}
