import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../data/db.dart' show Account;
import '../import/payment_method_mapper.dart';
import 'auto_bill_models.dart';

/// 自定义「关键词 → 子账户」映射规则存储与解析服务。
class AccountMappingService {
  static const String _prefsKey = 'auto_bill_account_mappings_v1';

  Future<List<AccountMappingRule>> loadRules() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final rules = decoded
          .whereType<Map<String, dynamic>>()
          .map(AccountMappingRule.fromJson)
          .where((r) => r.keyword.trim().isNotEmpty && r.accountId > 0)
          .toList();
      rules.sort((a, b) => a.priority.compareTo(b.priority));
      return rules;
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveRules(List<AccountMappingRule> rules) async {
    final prefs = await SharedPreferences.getInstance();
    final sorted = [...rules]..sort((a, b) => a.priority.compareTo(b.priority));
    await prefs.setString(
      _prefsKey,
      jsonEncode(sorted.map((r) => r.toJson()).toList()),
    );
  }

  /// 按优先级解析最匹配的账户 ID：
  /// 1. 用户自定义「关键词 → 账户」规则（匹配 rawText / accountHint / cardLastFour / bankName）
  /// 2. 按银行卡尾号（+ 开户行）精确匹配已有账户
  /// 3. 通过 [PaymentMethodMapper] 匹配已有子账户名或平台类型
  /// 4. 回退到默认账户 ID
  static Account? resolveAccount({
    required ParsedAutoBill bill,
    required List<Account> accounts,
    required List<AccountMappingRule> customRules,
    int? fallbackAccountId,
  }) {
    final visibleAccounts = accounts.where((a) => !a.hidden).toList();
    final byId = {for (final a in visibleAccounts) a.id: a};

    // 1. 用户自定义规则优先
    final sortedRules = [...customRules]
      ..sort((a, b) => a.priority.compareTo(b.priority));
    final searchHaystack = [
      bill.accountHint ?? '',
      bill.bankName ?? '',
      bill.cardLastFour ?? '',
      bill.rawText,
    ].join('\n').toLowerCase();

    for (final rule in sortedRules) {
      if (!rule.enabled) continue;
      final kw = rule.keyword.trim().toLowerCase();
      if (kw.isEmpty) continue;
      if (searchHaystack.contains(kw)) {
        final matched = byId[rule.accountId];
        if (matched != null) return matched;
      }
    }

    // 2. 银行卡后四位精确匹配
    if (bill.cardLastFour != null && bill.cardLastFour!.isNotEmpty) {
      final last4 = bill.cardLastFour!;
      final bank = bill.bankName;
      // 优先同时匹配开户行 + 尾号
      if (bank != null) {
        for (final a in visibleAccounts) {
          if (a.cardLastFour == last4 &&
              ((a.bankName != null &&
                      (a.bankName!.contains(bank) ||
                          bank.contains(a.bankName!))) ||
                  a.name.contains(bank))) {
            return a;
          }
        }
      }
      // 其次仅匹配尾号
      for (final a in visibleAccounts) {
        if (a.cardLastFour == last4 || a.name.contains(last4)) {
          return a;
        }
      }
    }

    // 3. 通过 PaymentMethodMapper 匹配子账户名（如 零钱通 / 零钱 / 余额宝 / 花呗）
    if (bill.accountHint != null && bill.accountHint!.isNotEmpty) {
      final hint = PaymentMethodMapper.resolve(
        bill.accountHint!,
        bankAccounts: visibleAccounts,
      );
      if (hint != null) {
        if (hint.matchedId != null && byId.containsKey(hint.matchedId)) {
          return byId[hint.matchedId];
        }
        // 精确同名或包含匹配
        for (final a in visibleAccounts) {
          if (a.name == hint.name || a.name.contains(hint.name)) {
            return a;
          }
        }
        // 按 type 回退匹配（如 wechat / alipay）
        for (final a in visibleAccounts) {
          if (a.type == hint.type) return a;
        }
      }
    }

    // 4. 默认账户回退
    if (fallbackAccountId != null && byId.containsKey(fallbackAccountId)) {
      return byId[fallbackAccountId];
    }
    return null;
  }
}
