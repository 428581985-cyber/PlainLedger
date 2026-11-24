/// 无感记账事件来源类型（按精确度/可信度区分）
enum AutoBillSourceType {
  bankSms,
  bankNotification,
  paymentNotification,
  accessibilityScreen,
  manualTest;

  static AutoBillSourceType fromWire(String raw) {
    switch (raw) {
      case 'bank_sms':
        return AutoBillSourceType.bankSms;
      case 'bank_notification':
        return AutoBillSourceType.bankNotification;
      case 'payment_notification':
        return AutoBillSourceType.paymentNotification;
      case 'accessibility_screen':
        return AutoBillSourceType.accessibilityScreen;
      case 'manual_test':
        return AutoBillSourceType.manualTest;
      default:
        return AutoBillSourceType.paymentNotification;
    }
  }

  String get wireName {
    switch (this) {
      case AutoBillSourceType.bankSms:
        return 'bank_sms';
      case AutoBillSourceType.bankNotification:
        return 'bank_notification';
      case AutoBillSourceType.paymentNotification:
        return 'payment_notification';
      case AutoBillSourceType.accessibilityScreen:
        return 'accessibility_screen';
      case AutoBillSourceType.manualTest:
        return 'manual_test';
    }
  }

  int get sourceReliabilityBonus {
    switch (this) {
      case AutoBillSourceType.bankSms:
      case AutoBillSourceType.bankNotification:
        return 15;
      case AutoBillSourceType.paymentNotification:
        return 10;
      case AutoBillSourceType.accessibilityScreen:
        return 5;
      case AutoBillSourceType.manualTest:
        return 10;
    }
  }
}

/// 从 Android 原生双引擎捕获并传来的单条原始事件
class AutoBillRawEvent {
  const AutoBillRawEvent({
    required this.eventId,
    required this.sourceType,
    required this.packageName,
    required this.title,
    required this.text,
    required this.timestampMs,
    this.isUpdate = false,
  });

  final String eventId;
  final AutoBillSourceType sourceType;
  final String packageName;
  final String title;
  final String text;
  final int timestampMs;
  final bool isUpdate;

  DateTime get timestamp => DateTime.fromMillisecondsSinceEpoch(timestampMs);

  factory AutoBillRawEvent.fromMap(Map<String, dynamic> map) {
    return AutoBillRawEvent(
      eventId: (map['eventId'] as String?) ?? '',
      sourceType:
          AutoBillSourceType.fromWire((map['sourceType'] as String?) ?? ''),
      packageName: (map['packageName'] as String?) ?? '',
      title: (map['title'] as String?) ?? '',
      text: (map['text'] as String?) ?? '',
      timestampMs: (map['timestampMs'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      isUpdate: (map['isUpdate'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toMap() => {
        'eventId': eventId,
        'sourceType': sourceType.wireName,
        'packageName': packageName,
        'title': title,
        'text': text,
        'timestampMs': timestampMs,
        'isUpdate': isUpdate,
      };
}

/// 本地规则引擎解析出的结构化记账草稿
class ParsedAutoBill {
  const ParsedAutoBill({
    required this.amount,
    required this.type,
    required this.precisionScore,
    required this.sourceType,
    required this.packageName,
    required this.rawText,
    required this.timestamp,
    this.merchant,
    this.accountHint,
    this.bankName,
    this.cardLastFour,
  });

  final double amount;

  /// 'expense' | 'income' | 'transfer'
  final String type;

  /// 商户或对方名称
  final String? merchant;

  /// 原始支付渠道线索（如「零钱通」「余额宝」「招商银行储蓄卡(8877)」）
  final String? accountHint;

  /// 银行简称/全称（如「招商银行」）
  final String? bankName;

  /// 银行卡后四位（如「8877」）
  final String? cardLastFour;

  /// 来源精确度分值（用于 60s 窗口去重时决定保留/升级哪条来源）
  final int precisionScore;

  final AutoBillSourceType sourceType;
  final String packageName;
  final String rawText;
  final DateTime timestamp;

  ParsedAutoBill copyWith({
    double? amount,
    String? type,
    String? merchant,
    String? accountHint,
    String? bankName,
    String? cardLastFour,
    int? precisionScore,
    AutoBillSourceType? sourceType,
    String? packageName,
    String? rawText,
    DateTime? timestamp,
  }) {
    return ParsedAutoBill(
      amount: amount ?? this.amount,
      type: type ?? this.type,
      merchant: merchant ?? this.merchant,
      accountHint: accountHint ?? this.accountHint,
      bankName: bankName ?? this.bankName,
      cardLastFour: cardLastFour ?? this.cardLastFour,
      precisionScore: precisionScore ?? this.precisionScore,
      sourceType: sourceType ?? this.sourceType,
      packageName: packageName ?? this.packageName,
      rawText: rawText ?? this.rawText,
      timestamp: timestamp ?? this.timestamp,
    );
  }
}

/// 用户自定义「关键词 → 账户」映射规则
class AccountMappingRule {
  const AccountMappingRule({
    required this.id,
    required this.keyword,
    required this.accountId,
    required this.accountName,
    this.priority = 100,
    this.enabled = true,
  });

  final String id;
  final String keyword;
  final int accountId;
  final String accountName;
  final int priority;
  final bool enabled;

  AccountMappingRule copyWith({
    String? id,
    String? keyword,
    int? accountId,
    String? accountName,
    int? priority,
    bool? enabled,
  }) {
    return AccountMappingRule(
      id: id ?? this.id,
      keyword: keyword ?? this.keyword,
      accountId: accountId ?? this.accountId,
      accountName: accountName ?? this.accountName,
      priority: priority ?? this.priority,
      enabled: enabled ?? this.enabled,
    );
  }

  factory AccountMappingRule.fromJson(Map<String, dynamic> json) {
    return AccountMappingRule(
      id: (json['id'] as String?) ?? '',
      keyword: (json['keyword'] as String?) ?? '',
      accountId: (json['accountId'] as num?)?.toInt() ?? 0,
      accountName: (json['accountName'] as String?) ?? '',
      priority: (json['priority'] as num?)?.toInt() ?? 100,
      enabled: (json['enabled'] as bool?) ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'keyword': keyword,
        'accountId': accountId,
        'accountName': accountName,
        'priority': priority,
        'enabled': enabled,
      };
}
