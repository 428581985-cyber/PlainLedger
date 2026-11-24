import '../../data/db.dart' show Account;

/// 支付方式原始值规整后的账户线索。
class PaymentAccountHint {
  const PaymentAccountHint({
    required this.name,
    required this.type,
    this.matchedId,
    this.bankName,
    this.cardLastFour,
  });

  /// 规整后的账户名（导入时按名字复用/创建账户）
  final String name;

  /// cash / bank_card / credit_card / wechat / alipay，与 Accounts.type 取值一致
  final String type;

  /// 命中已有账户（按开户行 + 卡号后四位）时给出其 id
  final int? matchedId;

  /// 仅银行卡：开户行（已去掉「储蓄卡/信用卡」后缀）
  final String? bankName;

  /// 仅银行卡：卡号后四位
  final String? cardLastFour;

  @override
  String toString() =>
      'PaymentAccountHint(name: $name, type: $type, matchedId: $matchedId)';
}

/// 账单「支付方式」列 → 账户
///
/// 微信账单的「支付方式」、支付宝账单的「收/付款方式」记录的是这笔钱的出资渠道，
/// 例如「零钱」「零钱通」「招商银行储蓄卡(8877)」「账户余额」「花呗」。
/// 本类把这些原始值规整成可落库的账户名 + 账户类型，纯函数、无 IO，便于单测。
class PaymentMethodMapper {
  const PaymentMethodMapper._();

  /// 视为「没有出资渠道」的占位值：转账/红包/提现类交易常见
  static const Set<String> _noChannel = {'/', '－', '-', '--', '—', '无'};

  /// 银行卡：`招商银行储蓄卡(8877)` / `建设银行信用卡(1234)`
  /// 主体用非贪婪匹配，允许「储蓄卡/信用卡」后缀缺省（如 `招商银行(8877)`）。
  static final RegExp _bankCard = RegExp(r'^(.+?)(?:储蓄卡|信用卡)?\((\d{4})\)$');

  /// [raw] 原始值 → 账户线索。返回 null 表示「这笔没有出资渠道」，不该建账户。
  ///
  /// [bankAccounts] 现有账户，用于按开户行 + 卡号后四位精确匹配已有账户。
  static PaymentAccountHint? resolve(
    String raw, {
    List<Account> bankAccounts = const [],
  }) {
    // 全角括号 / 全角空格统一成半角，避免正则失配
    final value = raw
        .replaceAll('（', '(')
        .replaceAll('）', ')')
        .replaceAll('\u3000', ' ')
        .trim();

    // 1. 空值 / 无渠道占位：绝不能建出叫「/」的账户
    if (value.isEmpty || _noChannel.contains(value)) return null;

    // 2. 组合渠道（支付宝常见）：只取第一段作为主出资渠道，
    //    「建设银行储蓄卡(8877)&支付宝立减&红包」→「建设银行储蓄卡(8877)」
    final first = value.split('&').first.trim();
    if (first.isEmpty || _noChannel.contains(first)) return null;

    // 3. 微信系：保留具体渠道名（零钱 / 零钱通）。
    //    合并成一个「微信」账户会让用户看不到零钱和零钱通各自的余额，
    //    而这两个是不同资金池（零钱通是货币基金）。账户页本来就按 type 分组，
    //    两者的 type 都是 wechat，会自动归到同一个「微信」分组下并显示合计。
    if (first.contains('零钱通')) {
      return const PaymentAccountHint(name: '零钱通', type: 'wechat');
    }
    if (first.contains('零钱')) {
      return const PaymentAccountHint(name: '零钱', type: 'wechat');
    }
    if (first.contains('微信')) {
      return const PaymentAccountHint(name: '微信', type: 'wechat');
    }

    // 4. 支付宝系：同样保留具体渠道名（余额 / 余额宝 / 花呗）
    if (first.contains('余额宝')) {
      return const PaymentAccountHint(name: '余额宝', type: 'alipay');
    }
    if (first.contains('账户余额')) {
      return const PaymentAccountHint(name: '余额', type: 'alipay');
    }
    if (first.contains('花呗')) {
      return const PaymentAccountHint(name: '花呗', type: 'alipay');
    }
    if (first.contains('支付宝')) {
      return const PaymentAccountHint(name: '支付宝', type: 'alipay');
    }

    // 5. 银行卡：拆出开户行主体 + 卡号后四位
    final m = _bankCard.firstMatch(first);
    if (m != null) {
      final body = m.group(1)!.trim();
      final last4 = m.group(2)!;
      final isCredit = first.contains('信用卡');
      final matched = _matchExisting(body, last4, bankAccounts);
      return PaymentAccountHint(
        name: body,
        type: isCredit ? 'credit_card' : 'bank_card',
        matchedId: matched?.id,
        bankName: body,
        cardLastFour: last4,
      );
    }

    // 6. 兜底：认不出的渠道按现金账户保留原名，不丢数据
    return PaymentAccountHint(name: first, type: 'cash');
  }

  /// 在现有账户里找「开户行 + 卡号后四位」都对得上的那个。
  static Account? _matchExisting(
    String bankName,
    String last4,
    List<Account> accounts,
  ) {
    for (final a in accounts) {
      if (a.cardLastFour != last4) continue;
      final existed = a.bankName;
      if (existed == null || existed.isEmpty) continue;
      // 双向包含：账单写「招商银行」、账户写「招商银行股份有限公司」都能命中
      if (existed.contains(bankName) || bankName.contains(existed)) return a;
    }
    return null;
  }
}
