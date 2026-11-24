import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db.dart';
import '../pages/main/simple_home_logic.dart';
import 'database_providers.dart';
import 'statistics_providers.dart';

// ============================================================================
// 首页交易流 + 账单筛选（从 simple_home_page.dart 抽出来，便于跨筛选 UI 共享）
// ============================================================================

/// 首页最近交易流（SimpleLedger 独立于原版首页的数据入口）。
///
/// limit <= 0 表示不截断，取当前账本的**全部**交易；之前固定 60 笔。
/// 全量数据由首页 ListView.builder 按需构建，不会一次性建上千个 children。
final simpleRecentTransactionsProvider =
    StreamProvider.autoDispose<List<Transaction>>((ref) {
  final ledgerId = ref.watch(currentLedgerIdProvider);
  return ref
      .watch(repositoryProvider)
      .watchRecentTransactions(ledgerId: ledgerId, limit: 0);
});

/// 首页筛选状态（跨「标题行入口 / 筛选面板 / chips」共享）。
///
/// 非 autoDispose：切换底部 tab 再回到首页时保留上次筛选条件。
final homeFilterProvider =
    StateProvider<HomeFilterState>((ref) => const HomeFilterState());

/// 筛选后的交易列表；纯派生，只在数据源或筛选条件变化时重算。
final homeFilteredTransactionsProvider =
    Provider.autoDispose<List<Transaction>>((ref) {
  // 下拉刷新 tick 也重算一次：顺带刷新「近 3 个月 / 当月」的时间边界。
  ref.watch(statsRefreshProvider);
  final txs = ref.watch(simpleRecentTransactionsProvider).valueOrNull ??
      const <Transaction>[];
  final filter = ref.watch(homeFilterProvider);
  // 同名分类（收入/支出各一个「其他」）在下拉里只显示一次，选中后按名字
  // 展开为所有同名 id，避免筛掉另一半数据。
  final categories =
      ref.watch(categoriesProvider).valueOrNull ?? const <Category>[];
  return filterHomeTransactions(
    txs,
    filter,
    now: DateTime.now(),
    categoryIds: categoryIdsForFilter(filter.categoryId, categories),
  );
});

/// 按天分组的扁平时间线（组头日汇总基于筛选后的列表重算，不沿用全量汇总）。
final homeTimelineProvider = Provider.autoDispose<List<Object>>((ref) {
  return buildDayTimeline(ref.watch(homeFilteredTransactionsProvider));
});

/// 顶部「共 N 笔 / 合计支出 X 收入 Y」。
final homeSummaryProvider = Provider.autoDispose<HomeSummary>((ref) {
  return summarizeHomeTransactions(
    ref.watch(homeFilteredTransactionsProvider),
  );
});
