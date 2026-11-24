import '../../data/db.dart';

/// 分类规则匹配引擎。纯 Dart、无 IO，便于单测。
///
/// 规则来自 `category_rules` 表（[CategoryRule]），由导入 / 批量整理流程
/// 读取后传入。匹配顺序即应用顺序：`priority` 升序、`id` 升序。
class CategoryRuleEngine {
  const CategoryRuleEngine._();

  /// 按 priority 升序、id 升序取第一条命中的规则，
  /// 返回其 `targetCategoryId`；无命中返回 null。
  static int? match({
    required String text,
    required String kind, // 'expense' | 'income'
    required List<CategoryRule> rules, // Drift 生成的 model 类
  }) {
    final sorted = [...rules]..sort((a, b) {
        final byPriority = a.priority.compareTo(b.priority);
        if (byPriority != 0) return byPriority;
        return a.id.compareTo(b.id);
      });

    for (final rule in sorted) {
      // 停用的规则跳过
      if (!rule.enabled) continue;
      // 关键词为空的规则等于匹配一切，跳过
      if (rule.keyword.trim().isEmpty) continue;
      // kind 为 null 的规则不限收支类型
      if (rule.kind != null && rule.kind != kind) continue;
      // field = source_category 的规则匹配的是导入时的分类列文本，
      // 由调用方自行决定传入哪个 text，这里不做区分。
      if (_hit(text, rule)) return rule.targetCategoryId;
    }
    return null;
  }

  static bool _hit(String text, CategoryRule rule) {
    final keyword = rule.keyword.trim();
    if (keyword.isEmpty) return false;

    switch (rule.matchType) {
      case 'equals':
        return text.trim() == keyword;
      case 'prefix':
        return text.trim().startsWith(keyword);
      case 'contains':
      default:
        // 双向 toLowerCase：中文不受影响，英文商户名更稳。
        return text.toLowerCase().contains(keyword.toLowerCase());
    }
  }
}
