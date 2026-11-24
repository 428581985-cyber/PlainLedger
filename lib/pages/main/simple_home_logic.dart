import 'package:intl/intl.dart';

import '../../data/db.dart';
import '../../utils/month_range.dart';

/// 首页月度统计所需的 provider 参数。
///
/// 月份归属必须跟账本的每月起始日一致，不能简单用自然月。
({int ledgerId, DateTime month}) homeMonthlyTotalsParams({
  required int ledgerId,
  required DateTime now,
  required int startDay,
}) {
  return (ledgerId: ledgerId, month: labelForDate(now, startDay));
}

/// 按自然日分组的组头数据（日期 + 当天收入/支出小计）。
class DayGroup {
  const DayGroup({
    required this.date,
    required this.income,
    required this.expense,
  });

  /// yyyy-MM-dd
  final String date;
  final double income;
  final double expense;
}

/// 把交易按自然日分组并扁平化，输出 [DayGroup, 交易, 交易, DayGroup, ...]。
///
/// 入参假设已按 happenedAt desc 排序，因此分组顺序天然是「今天 → 更早」。
/// 转账不计入日汇总；小计用 nativeAmount ?? amount（账本维度口径）。
List<Object> buildDayTimeline(List<Transaction> txs) {
  final groups = <String, List<Transaction>>{};
  for (final t in txs) {
    // happenedAt 在库里存的是 UTC 秒，必须 toLocal() 再取日期
    final key = DateFormat('yyyy-MM-dd').format(t.happenedAt.toLocal());
    groups.putIfAbsent(key, () => <Transaction>[]).add(t);
  }

  final out = <Object>[];
  for (final entry in groups.entries) {
    var income = 0.0;
    var expense = 0.0;
    for (final t in entry.value) {
      final v = t.nativeAmount ?? t.amount;
      if (t.type == 'income') {
        income += v;
      } else if (t.type == 'expense') {
        expense += v;
      }
    }
    out.add(DayGroup(date: entry.key, income: income, expense: expense));
    out.addAll(entry.value);
  }
  return out;
}

// ============================================================================
// 首页交易筛选（状态定义 + 纯函数，供 homeFilterProvider / 首页页面复用）
// ============================================================================

/// 首页「收支类型」筛选。枚举名与 transactions.type 字段值一致。
enum HomeTxTypeFilter { all, expense, income, transfer }

extension HomeTxTypeFilterLabel on HomeTxTypeFilter {
  String get label => switch (this) {
        HomeTxTypeFilter.all => '全部',
        HomeTxTypeFilter.expense => '支出',
        HomeTxTypeFilter.income => '收入',
        HomeTxTypeFilter.transfer => '转账',
      };
}

/// 首页「时间」筛选模式。
enum HomeTimeMode { all, month, recent3Months, custom }

extension HomeTimeModeLabel on HomeTimeMode {
  String get label => switch (this) {
        HomeTimeMode.all => '全部时间',
        HomeTimeMode.month => '指定月份',
        HomeTimeMode.recent3Months => '近 3 个月',
        HomeTimeMode.custom => '自定义区间',
      };
}

/// 首页筛选条件（不可变，跨「标题行入口 / 筛选面板 / chips」共享）。
///
/// 所有维度可组合；默认值 / null 表示「该维度不限制」。
class HomeFilterState {
  const HomeFilterState({
    this.type = HomeTxTypeFilter.all,
    this.timeMode = HomeTimeMode.all,
    this.month,
    this.customStart,
    this.customEnd,
    this.accountId,
    this.categoryId,
    this.keyword = '',
  });

  final HomeTxTypeFilter type;
  final HomeTimeMode timeMode;

  /// 指定月份模式下选中的年月（只取 year / month）。
  final DateTime? month;

  /// 自定义区间的起止日期（本地日历日，含首尾）；为空表示该端不限制。
  final DateTime? customStart;
  final DateTime? customEnd;

  /// null = 全部账户
  final int? accountId;

  /// null = 全部分类
  final int? categoryId;

  /// 备注 / 商户名关键词
  final String keyword;

  bool get hasActiveFilters =>
      type != HomeTxTypeFilter.all ||
      timeMode != HomeTimeMode.all ||
      accountId != null ||
      categoryId != null ||
      keyword.trim().isNotEmpty;

  /// 用于区分 copyWith 里「没传」和「显式传 null」（把某维度清回"全部"）。
  static const Object _sentinel = Object();

  HomeFilterState copyWith({
    HomeTxTypeFilter? type,
    HomeTimeMode? timeMode,
    Object? month = _sentinel,
    Object? customStart = _sentinel,
    Object? customEnd = _sentinel,
    Object? accountId = _sentinel,
    Object? categoryId = _sentinel,
    String? keyword,
  }) {
    return HomeFilterState(
      type: type ?? this.type,
      timeMode: timeMode ?? this.timeMode,
      month: identical(month, _sentinel) ? this.month : month as DateTime?,
      customStart: identical(customStart, _sentinel)
          ? this.customStart
          : customStart as DateTime?,
      customEnd: identical(customEnd, _sentinel)
          ? this.customEnd
          : customEnd as DateTime?,
      accountId: identical(accountId, _sentinel)
          ? this.accountId
          : accountId as int?,
      categoryId: identical(categoryId, _sentinel)
          ? this.categoryId
          : categoryId as int?,
      keyword: keyword ?? this.keyword,
    );
  }
}

/// 按 [filter] 过滤首页交易，保持原有的 happenedAt desc 顺序。
///
/// 时间统一按 happenedAt.toLocal() 后的「本地日历日」比较，与
/// [buildDayTimeline] 的分组口径一致；转账不计入收支汇总。
/// 筛选下拉里可展示的分类。
///
/// 1. 排除 `kind='transfer'` 的虚拟转账分类：那是 seed 里为「存转账图标」
///    建的，转账交易本身不挂分类，选它只会得到空列表；而且它跟用户自己
///    建的「转账」收入分类同名，下拉里会出现两个「转账」。
/// 2. 同名只留一个代表项（例如收入/支出各有一个「其他」），避免下拉里
///    出现两个一模一样的名字。选中后由 `categoryIdsForFilter` 展开成所有
///    同名分类 id，保证按名字筛选时不漏数据。
List<Category> visibleFilterCategories(List<Category> categories) {
  final seen = <String>{};
  final out = <Category>[];
  for (final c in categories) {
    if (c.kind == 'transfer') continue;
    if (!seen.add(c.name)) continue;
    out.add(c);
  }
  return out;
}

/// 把筛选状态里的「代表分类 id」展开成所有同名分类 id。
/// 返回 null 表示不限分类；找不到代表项（分类已被删）时按原 id 精确匹配。
Set<int>? categoryIdsForFilter(int? categoryId, List<Category> categories) {
  if (categoryId == null) return null;
  Category? rep;
  for (final c in categories) {
    if (c.id == categoryId) {
      rep = c;
      break;
    }
  }
  if (rep == null || rep.kind == 'transfer') return <int>{categoryId};
  return categories
      .where((c) => c.name == rep!.name && c.kind != 'transfer')
      .map((c) => c.id)
      .toSet();
}

List<Transaction> filterHomeTransactions(
  List<Transaction> txs,
  HomeFilterState filter, {
  required DateTime now,
  Set<int>? categoryIds,
}) {
  // 时间边界（本地日历日，含首尾）
  DateTime? rangeStart;
  DateTime? rangeEnd;
  switch (filter.timeMode) {
    case HomeTimeMode.all:
    case HomeTimeMode.month:
      break;
    case HomeTimeMode.recent3Months:
      // 含当月往前共 3 个自然月，截止到今天
      rangeStart = DateTime(now.year, now.month - 2, 1);
      rangeEnd = DateTime(now.year, now.month, now.day);
      break;
    case HomeTimeMode.custom:
      final s = filter.customStart;
      final e = filter.customEnd;
      if (s != null) rangeStart = DateTime(s.year, s.month, s.day);
      if (e != null) rangeEnd = DateTime(e.year, e.month, e.day);
      break;
  }

  final kw = filter.keyword.trim().toLowerCase();

  bool matchesTime(DateTime happenedAt) {
    final local = happenedAt.toLocal();
    if (filter.timeMode == HomeTimeMode.month) {
      final m = filter.month;
      // 选了「指定月份」但尚未挑具体月份时不额外过滤，避免结果意外为空
      if (m == null) return true;
      return local.year == m.year && local.month == m.month;
    }
    if (rangeStart == null && rangeEnd == null) return true;
    final day = DateTime(local.year, local.month, local.day);
    if (rangeStart != null && day.isBefore(rangeStart)) return false;
    if (rangeEnd != null && day.isAfter(rangeEnd)) return false;
    return true;
  }

  return txs.where((t) {
    // 收支类型
    if (filter.type != HomeTxTypeFilter.all && t.type != filter.type.name) {
      return false;
    }
    // 时间
    if (!matchesTime(t.happenedAt)) return false;
    // 账户：转出(accountId) / 转入(toAccountId) 两端都算该账户的账单
    if (filter.accountId != null &&
        t.accountId != filter.accountId &&
        t.toAccountId != filter.accountId) {
      return false;
    }
    // 分类：优先用「按名字展开」的同名分类 id 集合（见 categoryIdsForFilter），
    // 未传时退化为按单个 id 精确匹配，保持旧调用兼容。
    final catFilter = categoryIds ??
        (filter.categoryId == null
            ? null
            : <int>{filter.categoryId!});
    if (catFilter != null && !catFilter.contains(t.categoryId)) {
      return false;
    }
    // 关键词：备注 / 商户名模糊匹配（忽略大小写）
    if (kw.isNotEmpty && !(t.note ?? '').toLowerCase().contains(kw)) {
      return false;
    }
    return true;
  }).toList();
}

/// 首页顶部「共 N 笔 / 合计支出 X 收入 Y」汇总。
class HomeSummary {
  const HomeSummary({
    required this.count,
    required this.expense,
    required this.income,
  });

  final int count;
  final double expense;
  final double income;
}

/// 汇总口径与 [buildDayTimeline] 一致：nativeAmount ?? amount，转账不计入。
HomeSummary summarizeHomeTransactions(List<Transaction> txs) {
  var expense = 0.0;
  var income = 0.0;
  for (final t in txs) {
    final v = t.nativeAmount ?? t.amount;
    if (t.type == 'income') {
      income += v;
    } else if (t.type == 'expense') {
      expense += v;
    }
  }
  return HomeSummary(count: txs.length, expense: expense, income: income);
}
