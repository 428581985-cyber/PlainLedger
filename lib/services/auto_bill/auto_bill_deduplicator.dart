import 'auto_bill_models.dart';

enum DedupAction {
  /// 全新交易，直接入库
  insertNew,

  /// 命中跨渠道重复交易，且新来源更精确或补全了缺失字段，升级已有交易
  upgradeExisting,

  /// 命中重复交易，且已有记录已足够精确，直接忽略
  skipDuplicate,
}

class DedupEntry {
  const DedupEntry({
    required this.recordKey,
    required this.bill,
  });

  final String recordKey;
  final ParsedAutoBill bill;
}

class DedupResult {
  const DedupResult({
    required this.action,
    required this.mergedBill,
    this.matchedKey,
  });

  final DedupAction action;
  final ParsedAutoBill mergedBill;
  final String? matchedKey;
}

/// 时间窗口 + 金额 + 跨渠道精确度优先级去重器（融合 AutoAccounting 合并与 SmartLedger 防误杀思路）。
///
/// 规则：
/// 1. **跨渠道去重与合并**（60 秒内，如 无障碍屏幕页 + 微信/支付宝通知 + 银行通知/短信）：
///    合并为同一笔记录，保留更高精度的银行卡尾号/子账户，并优先保留真实商户名（不被「财付通/支付宝」等清算中介名覆盖）。
/// 2. **同渠道防误杀**：
///    同一渠道（相同 `sourceType` + 相同 `packageName`）如果间隔超过 3 秒（例如连续两次扫码买两瓶 3.5 元的水），
///    视为两笔独立消费，不误去重；仅在 3 秒极短抖动窗口内视为系统重复推送去重。
class AutoBillDeduplicator {
  AutoBillDeduplicator({
    this.crossChannelWindow = const Duration(seconds: 60),
    this.sameChannelDebounce = const Duration(seconds: 3),
    this.amountTolerance = 0.005,
    this.intermediaryMerchants = const {
      '财付通',
      '微信支付',
      '支付宝',
      '支付宝(中国)网络技术有限公司',
      '网联',
      '银联',
      '特约商户',
      '快捷支付',
      '网上支付',
      '无卡自助消费',
      '消费',
    },
  });

  final Duration crossChannelWindow;
  final Duration sameChannelDebounce;
  final double amountTolerance;
  final Set<String> intermediaryMerchants;

  final List<DedupEntry> _recent = [];

  DedupResult evaluate({
    required String newRecordKey,
    required ParsedAutoBill incoming,
  }) {
    _evictExpired(incoming.timestamp);

    for (var i = _recent.length - 1; i >= 0; i--) {
      final existing = _recent[i];
      if (!_isDuplicateMatch(existing.bill, incoming)) continue;

      final merged = _merge(existing.bill, incoming);
      if (_isImproved(existing.bill, merged)) {
        _recent[i] = DedupEntry(recordKey: existing.recordKey, bill: merged);
        return DedupResult(
          action: DedupAction.upgradeExisting,
          mergedBill: merged,
          matchedKey: existing.recordKey,
        );
      }
      return DedupResult(
        action: DedupAction.skipDuplicate,
        mergedBill: existing.bill,
        matchedKey: existing.recordKey,
      );
    }

    _recent.add(DedupEntry(recordKey: newRecordKey, bill: incoming));
    return DedupResult(
      action: DedupAction.insertNew,
      mergedBill: incoming,
    );
  }

  void seed(String recordKey, ParsedAutoBill bill) {
    _recent.add(DedupEntry(recordKey: recordKey, bill: bill));
  }

  void clear() => _recent.clear();

  void _evictExpired(DateTime now) {
    _recent.removeWhere(
      (entry) => now.difference(entry.bill.timestamp).abs() > crossChannelWindow,
    );
  }

  bool _isDuplicateMatch(ParsedAutoBill a, ParsedAutoBill b) {
    if (a.type != b.type) return false;
    if ((a.amount - b.amount).abs() > amountTolerance) return false;

    final delta = a.timestamp.difference(b.timestamp).abs();
    final sameChannel =
        a.sourceType == b.sourceType && a.packageName == b.packageName;
    if (sameChannel) {
      // 同渠道：仅防 3 秒内系统重推抖动；超过 3 秒视为真实连续消费，避免误杀
      return delta <= sameChannelDebounce;
    }
    return delta <= crossChannelWindow;
  }

  ParsedAutoBill _merge(ParsedAutoBill existing, ParsedAutoBill incoming) {
    final incomingMorePrecise =
        incoming.precisionScore > existing.precisionScore;

    final bestAccountHint = incomingMorePrecise
        ? (incoming.accountHint ?? existing.accountHint)
        : (existing.accountHint ?? incoming.accountHint);
    final bestBankName = incomingMorePrecise
        ? (incoming.bankName ?? existing.bankName)
        : (existing.bankName ?? incoming.bankName);
    final bestCardLastFour = incomingMorePrecise
        ? (incoming.cardLastFour ?? existing.cardLastFour)
        : (existing.cardLastFour ?? incoming.cardLastFour);

    final bestMerchant = _pickBetterMerchant(
      existing.merchant,
      incoming.merchant,
    );

    final bestPrecision = incomingMorePrecise
        ? incoming.precisionScore
        : existing.precisionScore;

    return existing.copyWith(
      merchant: bestMerchant,
      accountHint: bestAccountHint,
      bankName: bestBankName,
      cardLastFour: bestCardLastFour,
      precisionScore: bestPrecision,
      sourceType:
          incomingMorePrecise ? incoming.sourceType : existing.sourceType,
    );
  }

  bool _isIntermediary(String? m) {
    if (m == null || m.trim().isEmpty) return true;
    final trimmed = m.trim();
    return intermediaryMerchants.any((w) => trimmed == w || trimmed.contains(w));
  }

  String? _pickBetterMerchant(String? a, String? b) {
    final ca = a?.trim();
    final cb = b?.trim();
    if (ca == null || ca.isEmpty) return (cb == null || cb.isEmpty) ? null : cb;
    if (cb == null || cb.isEmpty) return ca;

    final aIsIntermediary = _isIntermediary(ca);
    final bIsIntermediary = _isIntermediary(cb);
    if (aIsIntermediary && !bIsIntermediary) return cb;
    if (!aIsIntermediary && bIsIntermediary) return ca;
    return cb.length > ca.length ? cb : ca;
  }

  bool _isImproved(ParsedAutoBill before, ParsedAutoBill after) {
    if (after.precisionScore > before.precisionScore) return true;
    if ((before.cardLastFour == null || before.cardLastFour!.isEmpty) &&
        (after.cardLastFour != null && after.cardLastFour!.isNotEmpty)) {
      return true;
    }
    if ((before.accountHint == null || before.accountHint!.isEmpty) &&
        (after.accountHint != null && after.accountHint!.isNotEmpty)) {
      return true;
    }
    if (_isIntermediary(before.merchant) && !_isIntermediary(after.merchant)) {
      return true;
    }
    if ((before.merchant == null || before.merchant!.isEmpty) &&
        (after.merchant != null && after.merchant!.isNotEmpty)) {
      return true;
    }
    return false;
  }
}
