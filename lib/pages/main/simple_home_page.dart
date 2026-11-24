import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/db.dart';
import '../../providers.dart';
import '../../providers/simple_settings_providers.dart';
import '../../styles/tokens.dart';
import '../../theme.dart';
import '../../utils/currencies.dart';
import '../../utils/transaction_edit_utils.dart';
import '../../widgets/biz/app_empty.dart';
import '../../widgets/biz/day_section_header.dart';
import '../transaction/transaction_editor_page.dart';
import 'simple_home_logic.dart';

/// 极简首页
///
/// 版式：顶部标题 → 总资产（可在设置隐藏）→ 本月收支两栏 → 最近交易列表。
/// 不使用整屏圆角卡片堆叠，只有总资产是可识别的视觉重点。
class SimpleHomePage extends ConsumerWidget {
  const SimpleHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final ink = isDark ? const Color(0xFFECEFEA) : BeeTheme.ink;
    final muted = isDark ? const Color(0xFF8A938C) : const Color(0xFF6B7169);
    final hairline =
        isDark ? Colors.white.withValues(alpha: 0.08) : BeeTheme.ink.withValues(alpha: 0.07);
    final teal = isDark ? BeeTheme.tealDark : BeeTheme.teal;
    final brick = isDark ? const Color(0xFFE0786B) : BeeTheme.brick;

    final ledgerId = ref.watch(currentLedgerIdProvider);
    final startDay = ref.watch(currentMonthStartDayProvider);
    final showTotalAsset = ref.watch(showTotalAssetProvider);
    final currencySymbol = getCurrencySymbol(ref.watch(baseCurrencyProvider));
    final hideAmounts = ref.watch(hideAmountsProvider);

    final now = DateTime.now();
    final monthParams = homeMonthlyTotalsParams(
      ledgerId: ledgerId,
      now: now,
      startDay: startDay,
    );
    final totalsAsync = ref.watch(monthlyTotalsProvider(monthParams));
    final balanceAsync = ref.watch(currentBalanceProvider(ledgerId));
    final recentAsync = ref.watch(simpleRecentTransactionsProvider);
    final categoriesAsync = ref.watch(categoriesProvider);
    final accountsAsync = ref.watch(accountsStreamProvider(ledgerId));

    final totals = totalsAsync.valueOrNull;
    final balance = balanceAsync.valueOrNull;
    // 筛选后的列表 / 时间线 / 汇总都由 provider 派生，日汇总基于筛选结果重算。
    final filtered = ref.watch(homeFilteredTransactionsProvider);
    final timeline = ref.watch(homeTimelineProvider);
    final summary = ref.watch(homeSummaryProvider);
    final filter = ref.watch(homeFilterProvider);

    final categoryMap = {
      for (final category in categoriesAsync.valueOrNull ?? const <Category>[])
        category.id: category,
    };
    final accounts = accountsAsync.valueOrNull ?? const <Account>[];
    final categories = categoriesAsync.valueOrNull ?? const <Category>[];
    final hasError = totalsAsync.hasError ||
        balanceAsync.hasError ||
        recentAsync.hasError;

    // 顶部固定区块随列表一起滚动；交易区交给 ListView.builder 按需构建，
    // 避免 645+ 笔一次性建 children 卡顿。
    final headerWidgets = <Widget>[
      _TopBar(ink: ink, muted: muted, now: now),
      const SizedBox(height: 26),
      if (showTotalAsset)
        _TotalAssetBlock(
          symbol: currencySymbol,
          value: balance,
          isDark: isDark,
        ),
      if (showTotalAsset) const SizedBox(height: 26),
      _FlowRow(
        symbol: currencySymbol,
        income: totals?.$1,
        expense: totals?.$2,
        incomeColor: teal,
        expenseColor: brick,
        ink: ink,
        muted: muted,
        hairline: hairline,
      ),
      if (hasError)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () {
              ref.invalidate(monthlyTotalsProvider(monthParams));
              ref.invalidate(currentBalanceProvider(ledgerId));
              ref.invalidate(simpleRecentTransactionsProvider);
            },
            child: Text(
              '数据加载失败，点此重试',
              style: TextStyle(fontSize: 12, color: brick),
            ),
          ),
        ),
      const SizedBox(height: 34),
      _SectionTitle(
        title: '最近交易',
        filterActive: filter.hasActiveFilters,
        ink: ink,
        muted: muted,
        onFilter: () => _openFilterSheet(context),
      ),
      if (filter.hasActiveFilters)
        _ActiveFilterChips(
          filter: filter,
          accounts: accounts,
          categories: categories,
          ink: ink,
          muted: muted,
          onRemove: (next) =>
              ref.read(homeFilterProvider.notifier).state = next,
          onClear: () => ref.read(homeFilterProvider.notifier).state =
              const HomeFilterState(),
        ),
      _SummaryRow(
        count: summary.count,
        expense: summary.expense,
        income: summary.income,
        symbol: currencySymbol,
        hideAmounts: hideAmounts,
        teal: teal,
        brick: brick,
        muted: muted,
      ),
      const SizedBox(height: 6),
    ];

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: teal,
          onRefresh: () async {
            ref.read(statsRefreshProvider.notifier).state++;
            await Future<void>.delayed(const Duration(milliseconds: 350));
          },
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 120),
            // 前 headerWidgets.length 项是固定头部，其后才是按天时间线。
            itemCount: headerWidgets.length +
                (filtered.isEmpty ? 1 : timeline.length),
            itemBuilder: (context, index) {
              if (index < headerWidgets.length) {
                return headerWidgets[index];
              }
              // 空结果：筛选无结果用 AppEmpty，全账本没记账沿用原空态。
              if (filtered.isEmpty) {
                if (filter.hasActiveFilters) {
                  return SizedBox(
                    height: 260,
                    child: AppEmpty(
                      text: '没有符合条件的交易',
                      subtext: '换个筛选条件试试',
                      action: TextButton(
                        onPressed: () =>
                            ref.read(homeFilterProvider.notifier).state =
                                const HomeFilterState(),
                        child: const Text('清除筛选'),
                      ),
                    ),
                  );
                }
                return _EmptyTransactions(
                  muted: muted,
                  onAdd: () => _openEditor(context, 'expense'),
                );
              }

              // index 映射：timeline[index - headerWidgets.length]
              final item = timeline[index - headerWidgets.length];
              if (item is DayGroup) {
                // 首页列表本身有 20 的页边距，传 0 让日期与交易标题左对齐，
                // 分隔线也能撑满内容宽度（不再用 Transform 左移，否则线会跟着偏移）。
                return DaySectionHeader(
                  dateText: item.date,
                  income: item.income,
                  expense: item.expense,
                  horizontalPadding: 0,
                );
              }
              final transaction = item as Transaction;
              final category = transaction.categoryId == null
                  ? null
                  : categoryMap[transaction.categoryId];
              return _TransactionRow(
                transaction: transaction,
                category: category,
                symbol: currencySymbol,
                ink: ink,
                muted: muted,
                incomeColor: teal,
                expenseColor: brick,
                // 点击先进入账单明细页（editTransaction 已统一路由），
                // 不再直接弹出分类网格 + 金额抽屉的编辑页。
                onTap: () => TransactionEditUtils.editTransaction(
                  context,
                  ref,
                  transaction,
                  category,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 筛选入口用底部抽屉，避免把首页塞满控件（样式参考 bulk_category_page）。
  static void _openFilterSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BeeTokens.surfaceSheet(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _HomeFilterSheet(),
    );
  }

  static void _openEditor(
    BuildContext context,
    String kind, {
    int? editingTransactionId,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TransactionEditorPage(
          initialKind: kind,
          quickAdd: editingTransactionId == null,
          editingTransactionId: editingTransactionId,
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.ink, required this.muted, required this.now});

  final Color ink;
  final Color muted;
  final DateTime now;

  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final weekday = _weekdays[now.weekday - 1];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '极简记账',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
            color: ink,
          ),
        ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(
            '${now.month}月${now.day}日 周$weekday',
            style: TextStyle(fontSize: 12, color: muted),
          ),
        ),
      ],
    );
  }
}

class _TotalAssetBlock extends StatelessWidget {
  const _TotalAssetBlock({
    required this.symbol,
    required this.value,
    required this.isDark,
  });

  final String symbol;
  final double? value;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    const foreground = Color(0xFFF3F7F4);
    final background = isDark ? const Color(0xFF0F3B36) : BeeTheme.teal;

    return Container(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '总资产',
            style: TextStyle(
              fontSize: 13,
              letterSpacing: 0.4,
              color: foreground.withValues(alpha: 0.72),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                symbol,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                  color: foreground.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value == null ? '—' : _formatAmount(value!),
                    style: const TextStyle(
                      fontSize: 34,
                      height: 1.05,
                      fontWeight: FontWeight.w600,
                      color: foreground,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FlowRow extends StatelessWidget {
  const _FlowRow({
    required this.symbol,
    required this.income,
    required this.expense,
    required this.incomeColor,
    required this.expenseColor,
    required this.ink,
    required this.muted,
    required this.hairline,
  });

  final String symbol;
  final double? income;
  final double? expense;
  final Color incomeColor;
  final Color expenseColor;
  final Color ink;
  final Color muted;
  final Color hairline;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _Metric(
            label: '本月收入',
            symbol: symbol,
            value: income,
            color: incomeColor,
            ink: ink,
            muted: muted,
            alignEnd: false,
          ),
        ),
        Container(
          width: 1,
          height: 40,
          margin: const EdgeInsets.symmetric(horizontal: 18),
          color: hairline,
        ),
        Expanded(
          child: _Metric(
            label: '本月支出',
            symbol: symbol,
            value: expense,
            color: expenseColor,
            ink: ink,
            muted: muted,
            alignEnd: true,
          ),
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.symbol,
    required this.value,
    required this.color,
    required this.ink,
    required this.muted,
    required this.alignEnd,
  });

  final String label;
  final String symbol;
  final double? value;
  final Color color;
  final Color ink;
  final Color muted;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment:
          alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: muted)),
        const SizedBox(height: 7),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              symbol,
              style: TextStyle(fontSize: 13, color: color.withValues(alpha: 0.8)),
            ),
            const SizedBox(width: 3),
            Text(
              value == null ? '—' : _formatAmount(value!),
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: value == null ? muted : color,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 「最近交易」标题行：右侧是筛选入口（图标 + 生效时的小红点）。
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.title,
    required this.filterActive,
    required this.ink,
    required this.muted,
    required this.onFilter,
  });

  final String title;
  final bool filterActive;
  final Color ink;
  final Color muted;
  final VoidCallback onFilter;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: ink,
          ),
        ),
        const Spacer(),
        Stack(
          clipBehavior: Clip.none,
          children: [
            InkWell(
              onTap: onFilter,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(
                  Icons.tune_rounded,
                  size: 20,
                  color: filterActive ? accent : muted,
                ),
              ),
            ),
            if (filterActive)
              Positioned(
                right: 3,
                top: 3,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: Color(0xFFE0786B),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 当前生效的筛选条件 chips：每个可单独删除，末尾「清除全部」一键清空。
class _ActiveFilterChips extends StatelessWidget {
  const _ActiveFilterChips({
    required this.filter,
    required this.accounts,
    required this.categories,
    required this.ink,
    required this.muted,
    required this.onRemove,
    required this.onClear,
  });

  final HomeFilterState filter;
  final List<Account> accounts;
  final List<Category> categories;
  final Color ink;
  final Color muted;
  final ValueChanged<HomeFilterState> onRemove;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final chips = <({String label, HomeFilterState next})>[];

    if (filter.type != HomeTxTypeFilter.all) {
      chips.add((
        label: '类型：${filter.type.label}',
        next: filter.copyWith(type: HomeTxTypeFilter.all),
      ));
    }
    if (filter.timeMode != HomeTimeMode.all) {
      chips.add((
        label: '时间：${_timeChipLabel(filter)}',
        next: filter.copyWith(
          timeMode: HomeTimeMode.all,
          month: null,
          customStart: null,
          customEnd: null,
        ),
      ));
    }
    if (filter.accountId != null) {
      chips.add((
        label: '账户：${_accountName(filter.accountId)}',
        next: filter.copyWith(accountId: null),
      ));
    }
    if (filter.categoryId != null) {
      chips.add((
        label: '分类：${_categoryName(filter.categoryId)}',
        next: filter.copyWith(categoryId: null),
      ));
    }
    if (filter.keyword.trim().isNotEmpty) {
      chips.add((
        label: '关键词：${filter.keyword.trim()}',
        next: filter.copyWith(keyword: ''),
      ));
    }
    if (chips.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final chip in chips)
            Chip(
              label: Text(chip.label,
                  style: TextStyle(fontSize: 11, color: ink)),
              onDeleted: () => onRemove(chip.next),
              deleteIcon: Icon(Icons.close, size: 14, color: muted),
              backgroundColor: BeeTokens.surfaceChip(context),
              side: BorderSide.none,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
          TextButton(
            onPressed: onClear,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text('清除全部',
                style: TextStyle(fontSize: 11, color: muted)),
          ),
        ],
      ),
    );
  }

  String _accountName(int? id) {
    for (final a in accounts) {
      if (a.id == id) return a.name;
    }
    return '账户';
  }

  String _categoryName(int? id) {
    for (final c in categories) {
      if (c.id == id) return c.name;
    }
    return '分类';
  }

  String _timeChipLabel(HomeFilterState f) {
    switch (f.timeMode) {
      case HomeTimeMode.month:
        return f.month == null
            ? '指定月份'
            : DateFormat('yyyy/MM').format(f.month!);
      case HomeTimeMode.recent3Months:
        return '近 3 个月';
      case HomeTimeMode.custom:
        String d(DateTime? v) =>
            v == null ? '…' : DateFormat('yyyy/MM/dd').format(v);
        return '${d(f.customStart)} - ${d(f.customEnd)}';
      case HomeTimeMode.all:
        return '全部时间';
    }
  }
}

/// 「共 N 笔 / 支出 X / 收入 Y」；隐藏金额开关打开时金额显示 ***。
class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.count,
    required this.expense,
    required this.income,
    required this.symbol,
    required this.hideAmounts,
    required this.teal,
    required this.brick,
    required this.muted,
  });

  final int count;
  final double expense;
  final double income;
  final String symbol;
  final bool hideAmounts;
  final Color teal;
  final Color brick;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    String amount(double v) =>
        hideAmounts ? '***' : '$symbol${_formatAmount(v)}';
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('共 $count 笔', style: TextStyle(fontSize: 12, color: muted)),
          Text('支出 ${amount(expense)}',
              style: TextStyle(fontSize: 12, color: brick)),
          Text('收入 ${amount(income)}',
              style: TextStyle(fontSize: 12, color: teal)),
        ],
      ),
    );
  }
}

/// 筛选底部抽屉。
///
/// 面板内维护一份本地草稿，点「确定」才写回 homeFilterProvider，取消/关闭
/// 不会污染筛选状态；样式与 bulk_category_page 的搜索框 + 分类下拉一致。
class _HomeFilterSheet extends ConsumerStatefulWidget {
  const _HomeFilterSheet();

  @override
  ConsumerState<_HomeFilterSheet> createState() => _HomeFilterSheetState();
}

class _HomeFilterSheetState extends ConsumerState<_HomeFilterSheet> {
  late HomeTxTypeFilter _type;
  late HomeTimeMode _timeMode;
  DateTime? _month;
  DateTime? _customStart;
  DateTime? _customEnd;
  int? _accountId;
  int? _categoryId;
  late final TextEditingController _keywordCtrl;

  @override
  void initState() {
    super.initState();
    final f = ref.read(homeFilterProvider);
    _type = f.type;
    _timeMode = f.timeMode;
    _month = f.month;
    _customStart = f.customStart;
    _customEnd = f.customEnd;
    _accountId = f.accountId;
    _categoryId = f.categoryId;
    _keywordCtrl = TextEditingController(text: f.keyword);
  }

  @override
  void dispose() {
    _keywordCtrl.dispose();
    super.dispose();
  }

  void _reset() {
    setState(() {
      _type = HomeTxTypeFilter.all;
      _timeMode = HomeTimeMode.all;
      _month = null;
      _customStart = null;
      _customEnd = null;
      _accountId = null;
      _categoryId = null;
      _keywordCtrl.clear();
    });
  }

  void _apply() {
    ref.read(homeFilterProvider.notifier).state = HomeFilterState(
      type: _type,
      timeMode: _timeMode,
      month: _month,
      customStart: _customStart,
      customEnd: _customEnd,
      accountId: _accountId,
      categoryId: _categoryId,
      keyword: _keywordCtrl.text.trim(),
    );
    Navigator.of(context).pop();
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: DateTimeRange(
        start: _customStart ?? DateTime(now.year, now.month, 1),
        end: _customEnd ?? now,
      ),
      locale: const Locale('zh'),
      helpText: '选择账单区间',
      saveText: '确定',
    );
    if (picked != null) {
      setState(() {
        _customStart = picked.start;
        _customEnd = picked.end;
        _timeMode = HomeTimeMode.custom;
      });
    }
  }

  /// 月份下拉：账本里有交易的月份 + 最近 12 个月兜底，降序。
  List<DateTime> _monthOptions(List<Transaction> txs) {
    final now = DateTime.now();
    final set = <DateTime>{};
    for (var i = 0; i < 12; i++) {
      set.add(DateTime(now.year, now.month - i, 1));
    }
    for (final t in txs) {
      final d = t.happenedAt.toLocal();
      set.add(DateTime(d.year, d.month, 1));
    }
    return set.toList()..sort((a, b) => b.compareTo(a));
  }

  DateTime _effectiveMonth(List<DateTime> months) {
    if (_month != null && months.contains(_month)) return _month!;
    return months.first;
  }

  String _customRangeLabel() {
    if (_customStart == null || _customEnd == null) return '选择起止日期';
    final f = DateFormat('yyyy/MM/dd');
    return '${f.format(_customStart!)} - ${f.format(_customEnd!)}';
  }

  @override
  Widget build(BuildContext context) {
    final ledgerId = ref.watch(currentLedgerIdProvider);
    final accounts = ref.watch(accountsStreamProvider(ledgerId)).valueOrNull ??
        const <Account>[];
    // 下拉里排除虚拟转账分类，并把同名分类（如收入/支出两个「其他」）
    // 合并成一项，避免用户看到两个一模一样的「转账」「其他」。
    final categories = visibleFilterCategories(
      ref.watch(categoriesProvider).valueOrNull ?? const <Category>[],
    );
    final allTxs = ref.watch(simpleRecentTransactionsProvider).valueOrNull ??
        const <Transaction>[];
    final months = _monthOptions(allTxs);

    // 草稿里可能残留已删除/别的账本的 id，DropdownButton 要求 value 必须
    // 存在于 items 中，这里兜底回落到「全部」避免断言。
    final accountValue = _accountId != null &&
            accounts.any((a) => a.id == _accountId)
        ? _accountId
        : null;
    final categoryValue = _categoryId != null &&
            categories.any((c) => c.id == _categoryId)
        ? _categoryId
        : null;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    '筛选账单',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: BeeTokens.textPrimary(context),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              _FilterSection(
                title: '收支类型',
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final t in HomeTxTypeFilter.values)
                      ChoiceChip(
                        label: Text(t.label),
                        selected: _type == t,
                        showCheckmark: false,
                        onSelected: (_) => setState(() => _type = t),
                      ),
                  ],
                ),
              ),
              _FilterSection(
                title: '时间',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Dropdown<HomeTimeMode>(
                      value: _timeMode,
                      items: [
                        for (final m in HomeTimeMode.values)
                          DropdownMenuItem(value: m, child: Text(m.label)),
                      ],
                      onChanged: (v) => setState(() {
                        _timeMode = v!;
                        // 切到「指定月份」时默认当前月，避免没挑月份导致空筛选
                        if (v == HomeTimeMode.month && _month == null) {
                          _month = months.first;
                        }
                      }),
                    ),
                    if (_timeMode == HomeTimeMode.month) ...[
                      const SizedBox(height: 8),
                      _Dropdown<DateTime>(
                        value: _effectiveMonth(months),
                        items: [
                          for (final m in months)
                            DropdownMenuItem(
                              value: m,
                              child: Text(DateFormat('yyyy 年 M 月').format(m)),
                            ),
                        ],
                        onChanged: (v) => setState(() => _month = v),
                      ),
                    ],
                    if (_timeMode == HomeTimeMode.custom) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _pickRange,
                        icon: const Icon(Icons.date_range, size: 18),
                        label: Text(_customRangeLabel()),
                      ),
                    ],
                  ],
                ),
              ),
              _FilterSection(
                title: '账户',
                child: _Dropdown<int?>(
                  value: accountValue,
                  items: [
                    const DropdownMenuItem<int?>(
                        value: null, child: Text('全部账户')),
                    for (final a in accounts)
                      DropdownMenuItem<int?>(
                        value: a.id,
                        child: Text(a.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => _accountId = v),
                ),
              ),
              _FilterSection(
                title: '分类',
                child: _Dropdown<int?>(
                  value: categoryValue,
                  items: [
                    const DropdownMenuItem<int?>(
                        value: null, child: Text('全部分类')),
                    for (final c in categories)
                      DropdownMenuItem<int?>(
                        value: c.id,
                        child: Text(c.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => _categoryId = v),
                ),
              ),
              _FilterSection(
                title: '关键词（备注 / 商户名）',
                child: TextField(
                  controller: _keywordCtrl,
                  decoration: InputDecoration(
                    hintText: '搜索备注或商户名',
                    isDense: true,
                    prefixIcon: Icon(Icons.search,
                        size: 20, color: BeeTokens.iconTertiary(context)),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          BorderSide(color: BeeTokens.borderStrong(context)),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _reset,
                      child: const Text('重置'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _apply,
                      child: const Text('确定'),
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

class _FilterSection extends StatelessWidget {
  const _FilterSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              color: BeeTokens.textSecondary(context),
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// 统一的下拉样式（参考 bulk_category_page 的分类下拉）。
class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BeeTokens.borderStrong(context)),
      ),
      child: DropdownButton<T>(
        value: value,
        items: items,
        onChanged: onChanged,
        isExpanded: true,
        isDense: true,
        underline: const SizedBox.shrink(),
      ),
    );
  }
}

class _TransactionRow extends StatelessWidget {
  const _TransactionRow({
    required this.transaction,
    required this.category,
    required this.symbol,
    required this.ink,
    required this.muted,
    required this.incomeColor,
    required this.expenseColor,
    required this.onTap,
  });

  final Transaction transaction;
  final Category? category;
  final String symbol;
  final Color ink;
  final Color muted;
  final Color incomeColor;
  final Color expenseColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isTransfer = transaction.type == 'transfer';
    final isIncome = transaction.type == 'income';
    final amountColor = isTransfer
        ? muted
        : isIncome
            ? incomeColor
            : expenseColor;
    final sign = isTransfer ? '' : isIncome ? '+' : '-';
    final title = category?.name ?? (isTransfer ? '转账' : '未分类');
    final note = transaction.note?.trim();

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: ink,
                    ),
                  ),
                  if (note != null && note.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      note,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '$sign$symbol${_formatAmount(transaction.amount)}',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: amountColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _timeLabel(transaction.happenedAt),
                  style: TextStyle(fontSize: 11, color: muted),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 日期已在组头上，行内只显示时分。
  static String _timeLabel(DateTime date) =>
      DateFormat('HH:mm').format(date.toLocal());
}

class _EmptyTransactions extends StatelessWidget {
  const _EmptyTransactions({required this.muted, required this.onAdd});

  final Color muted;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 44),
      child: Column(
        children: [
          Icon(Icons.receipt_long_outlined,
              size: 34, color: muted.withValues(alpha: 0.45)),
          const SizedBox(height: 12),
          Text('还没有记账', style: TextStyle(fontSize: 14, color: muted)),
          const SizedBox(height: 4),
          TextButton(
            onPressed: onAdd,
            child: const Text('记一笔'),
          ),
        ],
      ),
    );
  }
}

String _formatAmount(double value) => NumberFormat('#,##0.00').format(value);
