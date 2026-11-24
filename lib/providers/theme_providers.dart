import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/note_history.dart';
import '../theme.dart';

// 主题模式Provider（默认跟随系统）
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

// 主题模式持久化初始化
final themeModeInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('themeMode');
  if (saved != null) {
    switch (saved) {
      case 'light':
        ref.read(themeModeProvider.notifier).state = ThemeMode.light;
        break;
      case 'dark':
        ref.read(themeModeProvider.notifier).state = ThemeMode.dark;
        break;
      default:
        ref.read(themeModeProvider.notifier).state = ThemeMode.system;
    }
  }
  ref.listen<ThemeMode>(themeModeProvider, (prev, next) async {
    String value;
    switch (next) {
      case ThemeMode.light:
        value = 'light';
        break;
      case ThemeMode.dark:
        value = 'dark';
        break;
      default:
        value = 'system';
    }
    await prefs.setString('themeMode', value);
  });
});

// 可变主色（个性化换装使用）
final primaryColorProvider = StateProvider<Color>((ref) => BeeTheme.teal);

// 是否隐藏金额显示
final hideAmountsProvider = StateProvider<bool>((ref) => false);

// 字体选择Provider - 已移除，仅使用系统默认字体

// 主题色持久化初始化：
// - 启动时加载保存的主色
// - 监听主色变化并写入本地
final primaryColorInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getInt('primaryColor');
  if (saved != null) {
    ref.read(primaryColorProvider.notifier).state = Color(saved);
  }
  ref.listen<Color>(primaryColorProvider, (prev, next) async {
    // 同步捕获 —— 下面有 await,await 之后标志早被 finally 清掉了
    final fromServer = isApplyingFromServer;
    // 窗口也必须**同步**开:下面的 prefs 写入和小组件重绘都要 await,
    // 等推送那一步才开就晚了,空窗期里 server 的旧色会被下行采信。
    final endPush = fromServer ? null : beginThemePush();
    try {
      await _persistAndPushPrimary(ref, prefs, next, fromServer);
    } finally {
      endPush?.call();
    }
  });
});

/// primaryColor 变化后的落盘 + 上行推送。
/// 抽出来只是为了让 listener 那层能用 try/finally 卡住推送窗口。
Future<void> _persistAndPushPrimary(
    Ref ref, SharedPreferences prefs, Color next, bool fromServer) async {
  final colorValue = (next.a * 255).toInt() << 24 |
      (next.r * 255).toInt() << 16 |
      (next.g * 255).toInt() << 8 |
      (next.b * 255).toInt();
  await prefs.setInt('primaryColor', colorValue);
}

// ==================== 下行 apply 的 echo 抑制 ====================
//
// 主题色 / 皮肤的 listener 一律把新值推给 server(见上面的 push 块和
// `_pushAppearanceToCloud`)。问题是**下行 apply 也是写同一个 provider**,
// 于是「server 推下来 → 本地写入 → listener 又推回 server」构成回环。
//
// 单看一次不出事(server 收到相同值不再广播),但两端各有一次在途 push 时就会
// 交替到达、互相触发,主题色在两个颜色之间**无限横跳** —— 这就是「开启
// BeeCount Cloud 后一岁星座主题色一直闪」的成因。
//
// 绑定配色的皮肤看不出来:它们的结算恒等于 boundPrimary,同值不写自然不推。
// 当时的一岁星座不绑定配色(后来绑了蜜金),走的是 server 值分支,回环就
// 暴露了 —— 如今 19 款经典皮肤仍跟随主题色,这层抑制照样是它们的防线。
//
// 只压上行,**不压本地持久化和桌面小组件刷新** —— 那两件事不论值从哪来都得做。
bool _applyingFromServer = false;

/// 下行 apply 期间为 true。listener 用它决定「这个值要不要推回 server」。
bool get isApplyingFromServer => _applyingFromServer;

/// 把一段下行写入包起来,期间产生的 provider 变更不回推 server。
/// 必须是**同步**闭包:Riverpod 的 listener 同步触发,await 之后标志就失效了。
T runApplyingFromServer<T>(T Function() body) {
  final prev = _applyingFromServer;
  _applyingFromServer = true;
  try {
    return body();
  } finally {
    _applyingFromServer = prev;
  }
}

// ==================== 本地主题色「推送在途」窗口 ====================
//
// echo 抑制解决了「无限横跳」,但还剩**一次**闪:
//
//   用户切皮肤 → 本地写新色 → push 异步发出(还没到 server)
//   → 这期间一次 syncMyProfile 拉到 server 上的**旧颜色**
//   → 结算采信它、跳到旧色 → push 到达、server 广播回来 → 又跳回新色
//
// 本地用户刚做出的选择,比 server 上那个我们自己还没覆盖掉的旧值更可信。
// 所以推送在途期间,下行的 theme_color 一律不采信。
//
// 用计数而不是 bool:切皮肤会同时改 headerSkin 和 primaryColor,
// 两个 listener 各推一次,窗口要叠着算。
int _themePushInFlight = 0;

/// 本地主题色是否有推送还没落地。
bool get isThemePushInFlight => _themePushInFlight > 0;

/// 同步开一个「本地外观改动还没落到 server」的窗口,返回关窗回调(幂等)。
///
/// **必须在 listener 的同步段调用**,不能等到真正发请求时才开 —— 那之间隔着
/// prefs 写入和桌面小组件重绘两段 await(小组件那步要渲染图片,几百毫秒),
/// 窗口没开的这段时间里下行照样会采信 server 的旧色。
///
/// 实测症状:枫叶(绑定枫红)→ 一岁星座,主题色「黄 → 红 → 黄」跳三下。
/// 第一跳是正确的恢复用户手选色,第二跳就是这个空窗期里被 server 上
/// 还没来得及覆盖的枫红顶掉,第三跳是 push 落地后广播回来。
void Function() beginThemePush() {
  _themePushInFlight++;
  var closed = false;
  return () {
    // 幂等:重复关会让计数穿底,之后就永远不采信 server 的颜色了
    if (closed) return;
    closed = true;
    _themePushInFlight--;
  };
}

/// Flutter [Color] → `#RRGGBB`。忽略 alpha，server 只存 6 位 hex。

// 隐私模式持久化初始化：
// - 启动时加载保存的隐私模式状态
// - 监听隐私模式变化并写入本地
final hideAmountsInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getBool('hideAmounts');
  if (saved != null) {
    ref.read(hideAmountsProvider.notifier).state = saved;
  }
  ref.listen<bool>(hideAmountsProvider, (prev, next) async {
    await prefs.setBool('hideAmounts', next);
  });
});

/// 资产页「净值走势 / 资产构成」视图选择，持久化记住用户偏好（跨会话）。
enum AssetTrendView { trend, composition }

final assetTrendViewProvider =
    StateNotifierProvider<AssetTrendViewNotifier, AssetTrendView>(
        (ref) => AssetTrendViewNotifier());

class AssetTrendViewNotifier extends StateNotifier<AssetTrendView> {
  static const _key = 'assetTrendView';
  AssetTrendViewNotifier() : super(AssetTrendView.trend) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_key) == 'composition') {
      state = AssetTrendView.composition;
    }
  }

  Future<void> select(AssetTrendView v) async {
    if (state == v) return;
    state = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, v == AssetTrendView.composition ? 'composition' : 'trend');
  }
}

// 字体持久化初始化 - 已移除，仅使用系统默认字体

// Header装饰样式Provider
// 可选值：'icons'（图标平铺）、'particles'（粒子星星）、'honeycomb'（蜂巢六边形）
final headerDecorationStyleProvider = StateProvider<String>((ref) => 'icons');

// 金额显示格式Provider（默认显示完整金额）
// false = 完整金额（如 123,456.78）
// true = 简洁显示（如 12.3万）
final compactAmountProvider = StateProvider<bool>((ref) => false);

// 金额显示格式持久化初始化
final compactAmountInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getBool('compactAmount');
  if (saved != null) {
    ref.read(compactAmountProvider.notifier).state = saved;
  }
  ref.listen<bool>(compactAmountProvider, (prev, next) async {
    await prefs.setBool('compactAmount', next);
    _pushAppearanceToCloud(ref);
  });
});

// 显示交易时间Provider（默认不显示）
// false = 只显示日期
// true = 显示日期和时间（时:分）
final showTransactionTimeProvider = StateProvider<bool>((ref) => false);

// 显示交易时间持久化初始化
final showTransactionTimeInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getBool('showTransactionTime');
  if (saved != null) {
    ref.read(showTransactionTimeProvider.notifier).state = saved;
  }
  ref.listen<bool>(showTransactionTimeProvider, (prev, next) async {
    await prefs.setBool('showTransactionTime', next);
    _pushAppearanceToCloud(ref);
  });
});

// 备注显示方式 Provider(默认分类优先)
// 'category' = 分类名为主,备注挂括号小灰字(当前样式)
// 'note'     = 备注优先,有备注显示备注、无备注显示分类名
final noteDisplayModeProvider = StateProvider<String>((ref) => 'category');

// 备注显示方式持久化初始化
final noteDisplayModeInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('noteDisplayMode');
  if (saved != null) {
    ref.read(noteDisplayModeProvider.notifier).state = saved;
  }
  ref.listen<String>(noteDisplayModeProvider, (prev, next) async {
    await prefs.setString('noteDisplayMode', next);
    _pushAppearanceToCloud(ref);
  });
});

/// 历史备注的默认查询范围，保持原有全账本行为。
final noteHistoryScopeProvider =
    StateProvider<NoteHistoryScope>((ref) => NoteHistoryScope.allCategories);

/// 历史备注的默认排序规则，保持原有按使用次数排序行为。
final noteHistorySortProvider =
    StateProvider<NoteHistorySort>((ref) => NoteHistorySort.frequency);

/// 历史备注展示数量的默认值，保持原有最多展示 20 条的行为。
const noteHistoryDefaultLimit = 20;

/// 历史备注展示数量允许的最小值，避免空列表配置。
const noteHistoryMinLimit = 1;

/// 历史备注展示数量允许的最大值，避免单次加载过多候选。
const noteHistoryMaxLimit = 100;

/// 历史备注当前展示数量。
final noteHistoryLimitProvider =
    StateProvider<int>((ref) => noteHistoryDefaultLimit);

/// 初始化历史备注偏好，并在用户修改时持久化及同步外观配置。
final noteHistoryPreferencesInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final savedScope = prefs.getString('noteHistoryScope');
  final savedSort = prefs.getString('noteHistorySort');
  final savedLimit = prefs.getInt('noteHistoryLimit');

  // 旧版本缺失或配置异常时使用默认值，并回写规范值保证后续导出完整。
  var scope = NoteHistoryScope.allCategories;
  if (savedScope != null) {
    try {
      scope = NoteHistoryScope.values.byName(savedScope);
    } on ArgumentError {
      scope = NoteHistoryScope.allCategories;
    }
  }
  ref.read(noteHistoryScopeProvider.notifier).state = scope;

  var sort = NoteHistorySort.frequency;
  if (savedSort != null) {
    try {
      sort = NoteHistorySort.values.byName(savedSort);
    } on ArgumentError {
      sort = NoteHistorySort.frequency;
    }
  }
  ref.read(noteHistorySortProvider.notifier).state = sort;

  var limit = noteHistoryDefaultLimit;
  if (savedLimit != null &&
      savedLimit >= noteHistoryMinLimit &&
      savedLimit <= noteHistoryMaxLimit) {
    limit = savedLimit;
  }
  ref.read(noteHistoryLimitProvider.notifier).state = limit;

  // ref.listen 不会为初始值触发回调，首次启动时主动落库供配置导出使用。
  await prefs.setString('noteHistoryScope', scope.name);
  await prefs.setString('noteHistorySort', sort.name);
  await prefs.setInt('noteHistoryLimit', limit);

  ref.listen<NoteHistoryScope>(noteHistoryScopeProvider, (prev, next) async {
    // 用户选择变化后写本机偏好，并在 BeeCount Cloud 模式下同步。
    await prefs.setString('noteHistoryScope', next.name);
    _pushAppearanceToCloud(ref);
  });
  ref.listen<NoteHistorySort>(noteHistorySortProvider, (prev, next) async {
    // 用户选择变化后写本机偏好，并在 BeeCount Cloud 模式下同步。
    await prefs.setString('noteHistorySort', next.name);
    _pushAppearanceToCloud(ref);
  });
  ref.listen<int>(noteHistoryLimitProvider, (prev, next) async {
    // 用户修改数量后写本机偏好，并在 BeeCount Cloud 模式下同步。
    await prefs.setInt('noteHistoryLimit', next);
    _pushAppearanceToCloud(ref);
  });
});

// Header装饰样式持久化初始化
final headerDecorationStyleInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('headerDecorationStyle');
  if (saved != null) {
    ref.read(headerDecorationStyleProvider.notifier).state = saved;
  }
  ref.listen<String>(headerDecorationStyleProvider, (prev, next) async {
    await prefs.setString('headerDecorationStyle', next);
    _pushAppearanceToCloud(ref);
  });
});

/// 把 header_decoration_style / compact_amount / show_transaction_time
/// 的当前值打包推给 server 的 /profile/me。非 BeeCount Cloud 模式 provider
/// 返回 null 直接跳过。fire-and-forget,失败只打 warning。
///
/// 用整包 PATCH 是故意的:三者属于同一组"外观",任何一个改动都重发全量,server
/// 写入 appearance_json 整体替换,对端用 WS profile_change 事件拉 /profile/me
/// 拿到最新 dict 应用。
///
/// **绑定主题色的皮肤要先把颜色推上去再推 appearance。** theme_color 和
/// appearance 是 server 上两个字段、两次广播,各自触发对端一次 apply。如果
/// appearance 先落地,对端会在「新皮肤 + server 上还是旧颜色」的组合下走一遍
/// apply,颜色就会先跳旧色再跳回绑定色 —— 用户看到的就是两个主题色之间闪。
/// 这里串行 await 保证对端收到 header_skin 变更时,server 上的颜色已经对齐。
void _pushAppearanceToCloud(Ref ref) {}

// 收支颜色方案Provider（默认红色收入、绿色支出）
// true = 红色收入、绿色支出
// false = 红色支出、绿色收入
final incomeExpenseColorSchemeProvider = StateProvider<bool>((ref) => true);

// 收支颜色方案持久化初始化
final incomeExpenseColorSchemeInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getBool('incomeExpenseColorScheme');
  if (saved != null) {
    ref.read(incomeExpenseColorSchemeProvider.notifier).state = saved;
  }
  ref.listen<bool>(incomeExpenseColorSchemeProvider, (prev, next) async {
    await prefs.setBool('incomeExpenseColorScheme', next);
  });
});

// 用户显示名(昵称)。本地真值存 prefs 'displayName';BeeCount Cloud 模式下改动
// 会推到 server,其余云模式 / 纯本地只存本地。空串 = 未设置。v1 不支持"清空已设
// 昵称"——不会推空串给 server,因此无需改后端 / 包层(包层对空串本就 throw)。
final displayNameProvider = StateProvider<String>((ref) => '');

// 显示名持久化初始化:启动加载 prefs + 监听变化写回本地,并在 cloud 模式下推送。
// 完全照搬 themeMode / compactAmount 的写法。
final displayNameInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('displayName');
  if (saved != null) {
    ref.read(displayNameProvider.notifier).state = saved;
  }
  ref.listen<String>(displayNameProvider, (prev, next) async {
    final fromServer = isApplyingFromServer;
    await prefs.setString('displayName', next);
    if (fromServer) return; // server 推下来的昵称不再推回去
    _pushDisplayNameToCloud(ref, next);
  });
});

/// 把显示名推给 server 的 /profile/me(仅 BeeCount Cloud 模式)。非 cloud 模式
/// provider 返回 null 直接跳过;空串不推(v1 不支持清空,且包层对空串会 throw)。
/// fire-and-forget,失败只打 warning。
void _pushDisplayNameToCloud(Ref ref, String name) {}
