import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart' as schema;
import '../../providers.dart';
import '../../services/category_rules/category_rule_engine.dart';
import '../../styles/tokens.dart';
import '../../utils/category_utils.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/category_icon.dart';
import '../../widgets/ui/ui.dart';

/// 批量整理分类
///
/// 顶部按备注搜索 + 分类筛选，列表可多选；支持两种批量操作：
/// 1. 改分类：弹分类选择器，直接写 `categoryId`
/// 2. 按规则智能归类：先用 [CategoryRuleEngine] **dry-run** 算出每个目标分类
///    会命中多少笔，弹预览确认后才真正写库
class BulkCategoryPage extends ConsumerStatefulWidget {
  const BulkCategoryPage({super.key});

  @override
  ConsumerState<BulkCategoryPage> createState() => _BulkCategoryPageState();
}

class _BulkCategoryPageState extends ConsumerState<BulkCategoryPage> {
  /// 分类筛选的特殊值：全部 / 未分类（>= 0 表示具体分类 id）
  static const int _filterAll = -1;
  static const int _filterUncategorized = -2;

  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;

  List<schema.Transaction> _transactions = const [];
  Map<int, schema.Category> _categoryById = const {};
  List<schema.Category> _categories = const [];

  final Set<int> _selected = <int>{};
  int _filterValue = _filterAll;
  bool _loading = true;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // 数据
  // ------------------------------------------------------------------

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final repo = ref.read(repositoryProvider);
      final ledgerId = ref.read(currentLedgerIdProvider);
      final keyword = _searchController.text.trim();
      final list = await repo.getTransactionsForBulk(
        categoryId: _filterValue >= 0 ? _filterValue : null,
        uncategorized: _filterValue == _filterUncategorized,
        keyword: keyword.isEmpty ? null : keyword,
        ledgerId: ledgerId,
      );
      // kind='transfer' 是 seed 建的虚拟转账分类（只用于存转账图标），
      // 不该出现在用户可选分类里。
      final categories = (await repo.getAllCategories())
          .where((c) => c.kind != 'transfer')
          .toList();
      if (!mounted) return;
      final visibleIds = list.map((t) => t.id).toSet();
      setState(() {
        _transactions = list;
        _categories = categories;
        _categoryById = {for (final c in categories) c.id: c};
        // 列表变化后丢掉已不可见的选中项
        _selected.removeWhere((id) => !visibleIds.contains(id));
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// 规则表直接读 db（纯本地，规则页同款做法）
  Future<List<schema.CategoryRule>> _loadRules() async {
    try {
      final db = ref.read(databaseProvider);
      final rows = await db.select(db.categoryRules).get();
      rows.sort((a, b) {
        final byPriority = a.priority.compareTo(b.priority);
        return byPriority != 0 ? byPriority : a.id.compareTo(b.id);
      });
      return rows;
    } catch (_) {
      return const [];
    }
  }

  /// 分类改名/改归属后让首页统计与分类列表重新拉一次
  void _refreshProviders() {
    try {
      ref.read(statsRefreshProvider.notifier).state++;
      ref.invalidate(categoriesProvider);
      ref.invalidate(categoriesWithCountProvider);
    } catch (_) {
      // 忽略刷新信号异常
    }
  }

  String _categoryName(int? id) {
    final c = id == null ? null : _categoryById[id];
    if (c == null) return '未分类';
    return CategoryUtils.getDisplayName(c.name, context, kind: c.kind);
  }

  // ------------------------------------------------------------------
  // 操作
  // ------------------------------------------------------------------

  void _toggle(int id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  Future<void> _changeCategory() async {
    if (_selected.isEmpty || _working) return;
    final target = await showCategorySelector(
      context,
      type: 'all',
      includeParentCategories: true,
      title: '选择目标分类',
    );
    if (target == null || !mounted) return;

    setState(() => _working = true);
    try {
      final updated = await ref
          .read(repositoryProvider)
          .updateTransactionsCategoryBatch(
            ids: _selected.toList(),
            categoryId: target.id,
          );
      if (!mounted) return;
      showToast(context, '已把 $updated 笔改为「${_categoryName(target.id)}」');
      _selected.clear();
      _refreshProviders();
      await _load();
    } catch (e) {
      if (mounted) showToast(context, '改分类失败：$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// 按规则智能归类：先 dry-run 出「将影响 N 笔：分类A 78 / 分类B 41」，
  /// 用户确认后才按目标分类分组批量写库。
  Future<void> _smartClassify() async {
    if (_working || _transactions.isEmpty) return;
    final rules = await _loadRules();
    if (!mounted) return;
    if (rules.isEmpty) {
      showToast(context, '还没有规则，可在「设置 - 分类规则」里新增');
      return;
    }

    // ---- dry-run：只计算，不写库 ----
    final Map<int, List<int>> byTarget = <int, List<int>>{};
    for (final tx in _transactions) {
      if (tx.type == 'transfer') continue; // 转账不参与分类规则
      final text = tx.note ?? '';
      if (text.isEmpty) continue;
      final target =
          CategoryRuleEngine.match(text: text, kind: tx.type, rules: rules);
      if (target == null) continue;
      byTarget.putIfAbsent(target, () => <int>[]).add(tx.id);
    }

    final total = byTarget.values.fold<int>(0, (a, b) => a + b.length);
    if (total == 0) {
      showToast(context, '当前列表没有命中任何规则的交易');
      return;
    }

    final entries = byTarget.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    // 预览文案：「将影响 132 笔：餐饮 78 / 交通 41 / 其他 13」
    final preview = entries
        .map((e) => '${_categoryName(e.key)} ${e.value.length}')
        .join(' / ');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('将影响 $total 笔'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(preview),
              const SizedBox(height: 12),
              Text(
                '仅对当前列表（受搜索与筛选影响）生效，转账不参与。确认后才会写入。',
                style: TextStyle(
                  fontSize: 12,
                  color: BeeTokens.textTertiary(ctx),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('归类 $total 笔'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // ---- 按目标分类分组批量更新 ----
    setState(() => _working = true);
    var updated = 0;
    try {
      final repo = ref.read(repositoryProvider);
      for (final entry in entries) {
        updated += await repo.updateTransactionsCategoryBatch(
          ids: entry.value,
          categoryId: entry.key,
        );
      }
      if (!mounted) return;
      showToast(context, '已按规则归类 $updated 笔');
      _selected.clear();
      _refreshProviders();
      await _load();
    } catch (e) {
      if (mounted) showToast(context, '智能归类失败：$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      body: Column(
        children: [
          const PrimaryHeader(title: '批量整理分类', showBack: true),
          _buildFilterBar(),
          Expanded(child: _buildList()),
          _buildActionBar(),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: (_) {
                // 立刻刷新一次（清空按钮的显隐），再防抖查库
                setState(() {});
                _debounce?.cancel();
                _debounce =
                    Timer(const Duration(milliseconds: 300), () => _load());
              },
              decoration: InputDecoration(
                hintText: '按备注搜索',
                isDense: true,
                prefixIcon: Icon(Icons.search,
                    size: 20, color: BeeTokens.iconTertiary(context)),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          _load();
                        },
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: BeeTokens.border(context)),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: BeeTokens.border(context)),
            ),
            child: DropdownButton<int>(
              value: _filterValue,
              underline: const SizedBox.shrink(),
              isDense: true,
              items: [
                const DropdownMenuItem(value: _filterAll, child: Text('全部')),
                const DropdownMenuItem(
                    value: _filterUncategorized, child: Text('未分类')),
                for (final c in _categories)
                  DropdownMenuItem(
                    value: c.id,
                    child: Text(
                      CategoryUtils.getDisplayName(c.name, context,
                          kind: c.kind),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _filterValue = v);
                _load();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_transactions.isEmpty) {
      return AppEmpty(
        text: '没有符合条件的交易',
        subtext: '换个关键词或筛选条件试试',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: _transactions.length,
      itemBuilder: (context, index) {
        final tx = _transactions[index];
        final category =
            tx.categoryId == null ? null : _categoryById[tx.categoryId];
        return TransactionListItem(
          icon: getCategoryIconData(category: category),
          category: category,
          title: tx.note ?? '',
          categoryName: _categoryName(tx.categoryId),
          transactionId: tx.id,
          amount: tx.amount,
          currencyCode: tx.currencyCode,
          nativeAmount: tx.nativeAmount,
          isExpense: tx.type == 'expense',
          isTransfer: tx.type == 'transfer',
          happenedAt: tx.happenedAt,
          showFullDate: true,
          isSelectionMode: true,
          isSelected: _selected.contains(tx.id),
          onSelectionChanged: () => _toggle(tx.id),
        );
      },
    );
  }

  Widget _buildActionBar() {
    final allSelected = _transactions.isNotEmpty &&
        _selected.length == _transactions.length;
    return Container(
      decoration: BoxDecoration(
        color: BeeTokens.surface(context),
        border: Border(
          top: BorderSide(color: BeeTokens.divider(context), width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    '已选 ${_selected.length} 笔',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: BeeTokens.textSecondary(context),
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _transactions.isEmpty
                        ? null
                        : () => setState(() {
                              if (allSelected) {
                                _selected.clear();
                              } else {
                                _selected
                                  ..clear()
                                  ..addAll(_transactions.map((t) => t.id));
                              }
                            }),
                    child: Text(allSelected ? '取消全选' : '全选'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _working ? null : _smartClassify,
                      icon: const Icon(Icons.auto_fix_high, size: 18),
                      label: const Text('按规则智能归类'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed:
                          (_working || _selected.isEmpty) ? null : _changeCategory,
                      child: const Text('改分类'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
