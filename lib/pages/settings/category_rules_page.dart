import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' as d;

import '../../data/db.dart';
import '../../providers.dart';
import '../../styles/tokens.dart';
import '../../utils/category_utils.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/ui/ui.dart';

/// 分类规则管理页
///
/// 规则来自 `category_rules` 表（纯本地、不进同步），由导入流程自动生成，
/// 也可以在这里手动新增 / 启停 / 删除。规则匹配由
/// `CategoryRuleEngine` 完成（priority 升序、id 升序取第一条命中）。
class CategoryRulesPage extends ConsumerStatefulWidget {
  const CategoryRulesPage({super.key});

  @override
  ConsumerState<CategoryRulesPage> createState() => _CategoryRulesPageState();
}

class _CategoryRulesPageState extends ConsumerState<CategoryRulesPage> {
  List<CategoryRule> _rules = const [];
  /// targetCategoryId -> 分类（展示目标分类名 / 图标）
  Map<int, Category> _categoryById = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final db = ref.read(databaseProvider);
      final rows = await db.select(db.categoryRules).get();
      rows.sort((a, b) {
        final byPriority = a.priority.compareTo(b.priority);
        return byPriority != 0 ? byPriority : a.id.compareTo(b.id);
      });
      final categories = await ref.read(repositoryProvider).getAllCategories();
      if (!mounted) return;
      setState(() {
        _rules = rows;
        _categoryById = {for (final c in categories) c.id: c};
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  String _matchTypeLabel(String matchType) {
    switch (matchType) {
      case 'equals':
        return '等于';
      case 'prefix':
        return '开头是';
      case 'contains':
      default:
        return '包含';
    }
  }

  String _fieldLabel(String field) =>
      field == 'source_category' ? '源分类' : '备注';

  Future<void> _toggleRule(CategoryRule rule, bool value) async {
    final db = ref.read(databaseProvider);
    await (db.update(db.categoryRules)..where((r) => r.id.equals(rule.id)))
        .write(CategoryRulesCompanion(
      enabled: d.Value(value),
      updatedAt: d.Value(DateTime.now()),
    ));
    await _reload();
  }

  Future<bool> _confirmDelete(CategoryRule rule) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除规则'),
        content: Text('确定删除「${rule.keyword}」这条规则吗？已归类的交易不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _deleteRule(CategoryRule rule) async {
    final db = ref.read(databaseProvider);
    await (db.delete(db.categoryRules)..where((r) => r.id.equals(rule.id)))
        .go();
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    showToast(context, '已删除规则「${rule.keyword}」');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddSheet,
        icon: const Icon(Icons.add),
        label: const Text('新增规则'),
      ),
      body: Column(
        children: [
          const PrimaryHeader(title: '分类规则', showBack: true),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rules.isEmpty
                    ? AppEmpty(
                        text: '还没有规则',
                        subtext: '导入账单时勾选「保存为规则」即可自动生成',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
                        itemCount: _rules.length,
                        itemBuilder: (context, index) =>
                            _buildRuleCard(_rules[index]),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildRuleCard(CategoryRule rule) {
    final target = _categoryById[rule.targetCategoryId];
    final targetName = target == null
        ? '分类已删除'
        : CategoryUtils.getDisplayName(target.name, context, kind: target.kind);
    final isDark = BeeTokens.isDark(context);

    return Dismissible(
      key: ValueKey('rule-${rule.id}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDelete(rule),
      onDismissed: (_) => _deleteRule(rule),
      background: Container(
        margin: const EdgeInsets.only(bottom: 8),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.error.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(Icons.delete_outline,
            color: Theme.of(context).colorScheme.error),
      ),
      child: Card(
        elevation: isDark ? 0 : 1,
        margin: const EdgeInsets.only(bottom: 8),
        color: BeeTokens.surface(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: isDark
              ? BorderSide(color: BeeTokens.border(context))
              : BorderSide.none,
        ),
        child: GestureDetector(
          // 长按删除（与左滑删除等价）
          onLongPress: () async {
            if (await _confirmDelete(rule)) {
              await _deleteRule(rule);
            }
          },
          child: SwitchListTile(
            value: rule.enabled,
            onChanged: (v) => _toggleRule(rule, v),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    rule.keyword,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: BeeTokens.textPrimary(context),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${_matchTypeLabel(rule.matchType)} · ${_fieldLabel(rule.field)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: BeeTokens.textTertiary(context),
                  ),
                ),
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '→ $targetName    命中 ${rule.hitCount} 次',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: target == null
                      ? Theme.of(context).colorScheme.error
                      : BeeTokens.textSecondary(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // 新增规则
  // ------------------------------------------------------------------

  Future<void> _showAddSheet() async {
    // 排除 kind='transfer' 的虚拟转账分类：它只用于存转账图标，
    // 不是一笔交易能归入的分类，选了会让规则永远命中不到数据。
    final categories = _categoryById.values
        .where((c) => c.kind != 'transfer')
        .toList()
      ..sort((a, b) {
        final byKind = a.kind.compareTo(b.kind);
        if (byKind != 0) return byKind;
        return a.sortOrder.compareTo(b.sortOrder);
      });
    if (categories.isEmpty) {
      showToast(context, '还没有分类，先创建一个分类再来加规则');
      return;
    }

    final keywordController = TextEditingController();
    var matchType = 'contains';
    var field = 'source_category';
    int? targetCategoryId = categories.first.id;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BeeTokens.surfaceElevated(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSheetState) {
          return SingleChildScrollView(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('新增规则',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: BeeTokens.textPrimary(ctx),
                    )),
                const SizedBox(height: 16),
                TextField(
                  controller: keywordController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '关键词',
                    hintText: '如：星巴克 / 餐饮',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Text('匹配方式',
                    style: TextStyle(
                        fontSize: 12, color: BeeTokens.textTertiary(ctx))),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final opt in const [
                      ('contains', '包含'),
                      ('equals', '等于'),
                      ('prefix', '开头是'),
                    ])
                      ChoiceChip(
                        label: Text(opt.$2),
                        selected: matchType == opt.$1,
                        onSelected: (_) =>
                            setSheetState(() => matchType = opt.$1),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('匹配字段',
                    style: TextStyle(
                        fontSize: 12, color: BeeTokens.textTertiary(ctx))),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final opt in const [
                      ('note', '备注'),
                      ('source_category', '源分类'),
                    ])
                      ChoiceChip(
                        label: Text(opt.$2),
                        selected: field == opt.$1,
                        onSelected: (_) => setSheetState(() => field = opt.$1),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: targetCategoryId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '目标分类',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final c in categories)
                      DropdownMenuItem<int>(
                        value: c.id,
                        child: Text(
                          '${CategoryUtils.getDisplayName(c.name, ctx, kind: c.kind)}'
                          ' · ${c.kind == 'income' ? '收入' : '支出'}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) =>
                      setSheetState(() => targetCategoryId = v),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      if (keywordController.text.trim().isEmpty) {
                        showToast(ctx, '关键词不能为空');
                        return;
                      }
                      Navigator.pop(ctx, true);
                    },
                    child: const Text('保存'),
                  ),
                ),
              ],
            ),
          );
        });
      },
    );

    if (saved != true) {
      keywordController.dispose();
      return;
    }
    final keyword = keywordController.text.trim();
    keywordController.dispose();
    // targetCategoryId 在闭包里被赋值过，无法直接提升，这里取一份非空副本
    final targetId = targetCategoryId;
    if (keyword.isEmpty || targetId == null) return;

    final db = ref.read(databaseProvider);
    final now = DateTime.now();
    await db.into(db.categoryRules).insert(
          CategoryRulesCompanion.insert(
            keyword: keyword,
            matchType: d.Value(matchType),
            field: d.Value(field),
            targetCategoryId: targetId,
            // 源分类规则建议 priority 10、备注关键词规则 100（见表注释）
            priority: d.Value(field == 'source_category' ? 10 : 100),
            enabled: const d.Value(true),
            createdAt: d.Value(now),
            updatedAt: d.Value(now),
          ),
        );
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    showToast(context, '规则已保存');
  }
}
