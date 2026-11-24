import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' as d;
import '../../providers.dart';
import '../../widgets/ui/ui.dart';
import '../../data/db.dart' as schema;
import '../../l10n/app_localizations.dart';
import '../../services/category_rules/category_rule_engine.dart';
import '../../services/import/csv_parser.dart';
import '../../utils/category_utils.dart';
import '../../services/import/bill_parser.dart';
import '../../services/import/parsers/generic_parser.dart';
import '../../services/import/parsers/alipay_parser.dart';
import '../../services/import/parsers/wechat_parser.dart';
import '../../services/import/payment_method_mapper.dart';
import '../../services/billing/post_processor.dart';
import '../../services/data_import_service.dart';
import '../../services/import/account_currency_plan.dart';
import '../../utils/date_parser.dart';
import '../../styles/tokens.dart';
import 'import_page.dart';

class ImportConfirmPage extends ConsumerStatefulWidget {
  final String csvText;
  final bool hasHeader;
  final BillSourceType billType;
  const ImportConfirmPage({
    super.key,
    required this.csvText,
    required this.hasHeader,
    required this.billType,
  });

  @override
  ConsumerState<ImportConfirmPage> createState() => _ImportConfirmPageState();
}

class _ImportConfirmPageState extends ConsumerState<ImportConfirmPage> {
  List<List<String>> rows = const [];
  bool parsing = true;
  // 自动识别到的表头所在行（仅当 hasHeader 为 true 时使用）
  int headerRow = 0;
  final Map<String, int?> mapping = {
    'date': null,
    'type': null,
    'amount': null,
    'currency': null,            // v30 多币种:币种列(反馈10)
    'category': null,
    'sub_category': null,       // 二级分类
    'account': null,
    'from_account': null,
    'to_account': null,
    'note': null,
    'tags': null,                // 标签（逗号分隔）
    'attachments': null,         // 附件文件名（逗号分隔）
  };
  bool importing = false;
  int ok = 0, fail = 0, skipped = 0; // skipped: 跳过的非收支类型记录
  int step = 0; // 0: 字段映射, 1: 分类映射
  bool _cancelled = false;
  List<String> distinctCategories = [];
  Map<String, int?> categoryMapping = {}; // 源分类名 -> 目标分类ID（null表示保持原名）
  /// 本次是否把分类映射固化为 source_category 规则（第 2 步底部勾选框）
  bool saveRulesAsMapping = true;
  /// 已加载的分类规则（导入前加载，供第 2 步预匹配 + 导入时传参）
  List<schema.CategoryRule> rules = const [];
  Future<List<schema.Category>>? allCategoriesFuture;
  late final BillParser _billParser;

  /// 支付方式识别预览：原始值 → 规整后的账户名 + 笔数
  /// 只收录「发生了改名/归并」的项，自家导出的普通账户列（原名回填）不显示。
  List<({String raw, String name, int count})> _paymentPreview = const [];
  /// 无出资渠道的占位值（`/`、`无`）笔数，例如微信的转账/红包/提现
  int _paymentUnrecognized = 0;

  @override
  void initState() {
    super.initState();
    // 根据账单类型选择解析器
    _billParser = _getParser(widget.billType);

    // 解析在后台 isolate 完成，避免主线程卡顿
    () async {
      final parsed = await compute(_parseRowsIsolate, widget.csvText);
      if (!mounted) return;
      setState(() {
        rows = parsed;
        parsing = false;
      });
      // 解析完成
      // 使用解析器查找表头
      if (widget.hasHeader && rows.isNotEmpty) {
        headerRow = _billParser.findHeaderRow(rows);
        if (headerRow < 0) headerRow = 0; // 兜底
      }
      _autoDetectMapping();
      // 预取分类列表供第二步选择
      allCategoriesFuture = _loadAllCategories(ref);
      // 预取分类规则：第 2 步的预匹配优先用规则
      rules = await _loadRules();
      if (mounted) setState(() {});
    }();
  }

  /// 根据账单类型获取解析器
  BillParser _getParser(BillSourceType type) {
    switch (type) {
      case BillSourceType.generic:
        return GenericBillParser();
      case BillSourceType.alipay:
        return AlipayBillParser();
      case BillSourceType.wechat:
        return WechatBillParser();
    }
  }

  void _autoDetectMapping() {
    if (rows.isEmpty || !widget.hasHeader) return;
    final headers = rows[headerRow].map((e) => e.toString().trim()).toList();

    // 使用解析器的列映射功能
    final detectedMapping = _billParser.mapColumns(headers);

    // 更新 mapping
    detectedMapping.forEach((key, index) {
      if (mapping.containsKey(key)) {
        mapping[key] = index;
      }
    });
    _refreshPaymentPreview();
  }

  /// 统计「支付方式」列的识别结果，供字段映射下方只读展示。
  /// 只做规整不建账户；账户真正落地在 [_buildImportDataFromCsv]。
  void _refreshPaymentPreview() {
    final idx = mapping['account'];
    if (idx == null || rows.isEmpty) {
      _paymentPreview = const [];
      _paymentUnrecognized = 0;
      return;
    }
    final dataStart = widget.hasHeader ? headerRow + 1 : 0;
    final counts = <String, int>{};
    for (int i = dataStart; i < rows.length; i++) {
      final r = rows[i];
      if (idx >= r.length) continue;
      final raw = r[idx].toString().trim();
      if (raw.isEmpty) continue;
      counts[raw] = (counts[raw] ?? 0) + 1;
    }

    final entries = <({String raw, String name, int count})>[];
    var unrecognized = 0;
    counts.forEach((raw, count) {
      final hint = PaymentMethodMapper.resolve(raw);
      if (hint == null) {
        unrecognized += count;
        return;
      }
      // 规整后名字没变（如自家导出的「现金」）→ 无需提示，保持原 UI 干净
      if (hint.name == raw) return;
      entries.add((raw: raw, name: hint.name, count: count));
    });
    entries.sort((a, b) => b.count.compareTo(a.count));

    _paymentPreview = entries.take(5).toList();
    _paymentUnrecognized = entries.isEmpty ? 0 : unrecognized;
  }

  @override
  Widget build(BuildContext context) {
    if (parsing) {
      return Scaffold(
        body: Column(
          children: [
            PrimaryHeader(
                title: AppLocalizations.of(context).importPreparing,
                showBack: true),
            Expanded(
              child: Center(
                child: CircularProgressIndicator(),
              ),
            )
          ],
        ),
      );
    }
    final columnCount =
        rows.isNotEmpty ? rows[widget.hasHeader ? headerRow : 0].length : 0;
    List<DropdownMenuItem<int>> items() => List.generate(columnCount, (i) {
          final header = widget.hasHeader
              ? rows[headerRow]
              : (rows.isNotEmpty ? rows.first : const <String>[]);
          final label = (widget.hasHeader &&
                  i < header.length &&
                  header[i].trim().isNotEmpty)
              ? header[i].trim()
              : AppLocalizations.of(context).importColumnNumber(i + 1);
          return DropdownMenuItem(
              value: i, child: Text(label, overflow: TextOverflow.ellipsis));
        });

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PrimaryHeader(
              title: step == 0
                  ? AppLocalizations.of(context).importConfirmMapping
                  : AppLocalizations.of(context).importCategoryMapping,
              showBack: true),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                if (step == 0) ...[
                  if (rows.isEmpty)
                    Text(AppLocalizations.of(context).importNoDataParsed),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      _mapRow(AppLocalizations.of(context).importFieldDate,
                          'date', items()),
                      _mapRow(AppLocalizations.of(context).importFieldType,
                          'type', items()),
                      _mapRow(AppLocalizations.of(context).importFieldAmount,
                          'amount', items()),
                      _mapRow(AppLocalizations.of(context).importFieldCurrency,
                          'currency', items()),
                      _mapRow(AppLocalizations.of(context).importFieldCategory,
                          'category', items()),
                      _mapRow(AppLocalizations.of(context).exportCsvHeaderSubCategory,
                          'sub_category', items()),
                      _mapRow(AppLocalizations.of(context).importFieldAccount,
                          'account', items()),
                      _mapRow(AppLocalizations.of(context).exportCsvHeaderFromAccount,
                          'from_account', items()),
                      _mapRow(AppLocalizations.of(context).exportCsvHeaderToAccount,
                          'to_account', items()),
                      _mapRow(AppLocalizations.of(context).importFieldNote,
                          'note', items()),
                      _mapRow(AppLocalizations.of(context).exportCsvHeaderTags,
                          'tags', items()),
                      _mapRow(AppLocalizations.of(context).exportCsvHeaderAttachments,
                          'attachments', items()),
                    ],
                  ),
                  _paymentPreviewWidget(context),
                  const SizedBox(height: 12),
                  // 预览仅展示前 N 行，避免大文件一次性渲染导致卡顿
                  Text(AppLocalizations.of(context).importPreview,
                      style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 6),
                  SizedBox(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Builder(builder: (_) {
                        const int maxPreview = 10; // 预览最多 100 行
                        final totalRows = rows.length;
                        final dataStart =
                            widget.hasHeader ? (headerRow + 1) : 0;
                        // 保证包含表头行 + 最多 maxPreview-1 行数据
                        final header = widget.hasHeader
                            ? [rows[headerRow]]
                            : <List<String>>[];
                        final body = totalRows > dataStart
                            ? () {
                                final take = (maxPreview - header.length);
                                final end = (dataStart + take <= totalRows)
                                    ? dataStart + take
                                    : totalRows;
                                return rows.sublist(dataStart, end);
                              }()
                            : const <List<String>>[];
                        final limited = [...header, ...body];
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _PreviewTable(rows: limited),
                            if (totalRows > limited.length)
                              Padding(
                                padding: const EdgeInsets.only(top: 6.0),
                                child: Text(
                                  AppLocalizations.of(context)
                                      .importPreviewLimit(
                                          limited.length, totalRows),
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: BeeTokens.textTertiary(context)),
                                ),
                              ),
                          ],
                        );
                      }),
                    ),
                  ),
                ] else ...[
                  if (mapping['category'] == null)
                    Text(AppLocalizations.of(context)
                        .importCategoryNotSelected),
                  Text(AppLocalizations.of(context)
                      .importCategoryMappingDescription),
                  const SizedBox(height: 8),
                  FutureBuilder<List<schema.Category>>(
                    future: allCategoriesFuture,
                    builder: (context, snap) {
                      // 虚拟转账分类（kind='transfer'）不是可映射的目标分类。
                      final cats = (snap.data ?? <schema.Category>[])
                          .where((c) => c.kind != 'transfer')
                          .toList();
                      final l10n = AppLocalizations.of(context);
                      final items = <DropdownMenuItem<int?>>[
                        DropdownMenuItem(
                            value: null,
                            child: Text(l10n.importKeepOriginalName)),
                        ...cats.map((c) => DropdownMenuItem<int?>(
                              value: c.id,
                              child: Text(
                                  '${CategoryUtils.getDisplayName(c.name, context, kind: c.kind)} (${c.kind == 'income' ? l10n.categoryIncome : l10n.categoryExpense})'),
                            )),
                      ];
                      // 为每个源分类预设自动匹配（仅在首次加载时执行）
                      // 顺序：规则命中优先 → 其次同名分类
                      if (categoryMapping.values.every((v) => v == null) &&
                          cats.isNotEmpty) {
                        final byName = <String, schema.Category>{};
                        for (final c in cats) {
                          byName.putIfAbsent(c.name, () => c);
                        }
                        // 源分类名本身没有收支类型，先按支出、再按收入各试一次；
                        // kind 为 null 的规则两次都能命中。
                        final sourceRules = [
                          for (final r in rules)
                            if (r.field == 'source_category') r,
                        ];
                        bool hasMatch = false;
                        for (final sourceName in distinctCategories) {
                          int? ruleHit;
                          if (sourceRules.isNotEmpty) {
                            ruleHit = CategoryRuleEngine.match(
                                  text: sourceName,
                                  kind: 'expense',
                                  rules: sourceRules,
                                ) ??
                                CategoryRuleEngine.match(
                                  text: sourceName,
                                  kind: 'income',
                                  rules: sourceRules,
                                );
                          }
                          if (ruleHit != null) {
                            categoryMapping[sourceName] = ruleHit;
                            hasMatch = true;
                            continue;
                          }
                          // 规则没命中 → 同名分类精确匹配
                          final same = byName[sourceName];
                          if (same != null) {
                            categoryMapping[sourceName] = same.id;
                            hasMatch = true;
                          }
                        }
                        // 如果有自动匹配，触发重建以显示预设的匹配
                        if (hasMatch) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) setState(() {});
                          });
                        }
                      }

                      return Column(
                        children: [
                          for (final name in distinctCategories)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                children: [
                                  Expanded(
                                      child: Text(name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis)),
                                  const SizedBox(width: 12),
                                  DropdownButton<int?>(
                                    value: categoryMapping[name],
                                    items: items,
                                    onChanged: (v) => setState(
                                        () => categoryMapping[name] = v),
                                  ),
                                ],
                              ),
                            )
                        ],
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 第 2 步：把本次映射固化为规则（仅当至少有一项选了目标分类时可点）
                if (step == 1)
                  CheckboxListTile(
                    value: _hasMappedCategory && saveRulesAsMapping,
                    onChanged: (importing || !_hasMappedCategory)
                        ? null
                        : (v) => setState(
                            () => saveRulesAsMapping = v ?? false),
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: Text(
                      '把本次分类映射保存为规则（下次自动套用）',
                      style: TextStyle(
                        fontSize: 13,
                        color: BeeTokens.textSecondary(context),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      if (importing)
                        Text(AppLocalizations.of(context)
                            .importProgress(ok, fail)),
                      const Spacer(),
                      if (step == 0)
                        FilledButton(
                          onPressed: () {
                            // 检查是否有分类列映射
                            // 如果没有分类列，说明可能只有转账记录，跳过分类映射步骤，直接开始导入
                            if (mapping['category'] == null) {
                              // 如果没有分类列但有转账相关列，则直接开始导入
                              if (mapping['from_account'] != null ||
                                  mapping['to_account'] != null) {
                                _startImport();
                              } else {
                                showToast(
                                    context,
                                    AppLocalizations.of(context)
                                        .importSelectCategoryFirst);
                              }
                              return;
                            }
                            _buildDistinctCategories();
                            setState(() => step = 1);
                          },
                          child:
                              Text(AppLocalizations.of(context).importNextStep),
                        )
                      else ...[
                        OutlinedButton(
                          onPressed: importing
                              ? null
                              : () => setState(() => step = 0),
                          child: Text(AppLocalizations.of(context)
                              .importPreviousStep),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: importing ? null : _startImport,
                          child: Text(
                              AppLocalizations.of(context).importStartImport),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _mapRow(String label, String key, List<DropdownMenuItem<int>> items) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: 64, child: Text(label)),
        const SizedBox(width: 8),
        SizedBox(
          width: 220,
          child: DropdownButton<int>(
            isExpanded: true,
            value: mapping[key],
            hint: Text(AppLocalizations.of(context).importAutoDetect),
            items: items,
            onChanged: (v) => setState(() {
              mapping[key] = v;
              // 账户列可能刚被手选为「支付方式」，识别预览要跟着刷新
              if (key == 'account') _refreshPaymentPreview();
            }),
          ),
        ),
      ],
    );
  }

  /// 字段映射下方的支付方式识别预览（只读文本，复用页面已有样式，不新造卡片）
  Widget _paymentPreviewWidget(BuildContext context) {
    if (_paymentPreview.isEmpty) return const SizedBox.shrink();
    final parts = <String>[
      for (final e in _paymentPreview) '${e.raw} → ${e.name}（${e.count} 笔）',
      if (_paymentUnrecognized > 0) '未识别 $_paymentUnrecognized 笔',
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        '支付方式识别：${parts.join('；')}',
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: BeeTokens.textTertiary(context)),
      ),
    );
  }

  Future<void> _startImport() async {
    // 使用根容器，保证页面被销毁后仍可更新全局进度供"我的"页展示
    final container = ProviderScope.containerOf(context, listen: false);
    final currentContext = context;
    setState(() {
      importing = true;
      ok = 0;
      fail = 0;
    });
    final repo = ref.read(repositoryProvider);
    final ledgerId = ref.read(currentLedgerIdProvider);
    // 导入前再取一次规则（用户可能刚在规则页改过）
    final currentRules = await _loadRules();

    // v1.15.0: 获取当前账本的币种信息
    final currentLedger = await repo.getLedgerById(ledgerId);
    final ledgerCurrency = currentLedger?.currency ?? 'CNY';

    final dataStart = widget.hasHeader ? (headerRow + 1) : 0;
    final total = rows.length - dataStart;
    final Map<String, int> skippedTypes = {};
    late final ImportData importData;
    try {
      // 先取现有账户：支付方式里的「招行储蓄卡(8877)」需要按开户行+卡号
      // 后四位命中已有账户，避免重复建号。
      final existing = await repo.getAllAccounts();
      final raw = _buildImportDataFromCsv(
        rows: rows, dataStart: dataStart, mapping: mapping,
        categoryMapping: categoryMapping, skippedTypes: skippedTypes,
        ledgerCurrency: ledgerCurrency, rules: currentRules,
        bankAccounts: existing,
      );
      final plan = planExternalAccountCurrencies(raw,
        ledgerCurrency: ledgerCurrency,
        existingCurrencies: {for (final account in existing) account.name: account.currency},
      );
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
        title: Text(l10n.importAccountCurrencyPreview),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l10n.importAccountCurrencyPreviewHint),
            const SizedBox(height: 12),
            for (final account in plan.data.accounts) Text('${account.name} · ${account.currency}'),
            if (plan.mappings.isNotEmpty) ...[
              const Divider(),
              for (final mapping in plan.mappings) Text(mapping),
            ],
          ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.importStartImport)),
        ],
      ));
      if (!mounted) return;
      if (confirmed != true) { setState(() => importing = false); return; }
      importData = plan.data;
    } catch (error) {
      if (mounted) {
        setState(() => importing = false);
        showToast(context, AppLocalizations.of(context).importTransactionFailed('$error'));
      }
      return;
    }
    // 初始化全局进度
    container.read(importProgressProvider.notifier).state = ImportProgress(
      running: true,
      total: total,
      done: 0,
      ok: 0,
      fail: 0,
    );

    if (!currentContext.mounted) return;
    bool dialogOpen = true;
    // 进度弹窗（可转后台）
    showDialog(
      context: currentContext,
      barrierDismissible: false,
      builder: (dctx) {
        return Consumer(builder: (dctx, r, _) {
          final p = r.watch(importProgressProvider);
          final percent =
              p.total == 0 ? 0.0 : (p.done / p.total).clamp(0.0, 1.0);
          return AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            title: Text(AppLocalizations.of(context).importInProgress),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                    value: percent > 0 && percent < 1 ? percent : null),
                const SizedBox(height: 8),
                // 实时进度文案（每50条更新一次，足够流畅）
                Text(
                    AppLocalizations.of(context)
                        .importProgressDetail(p.done, p.fail, p.ok, p.total),
                    style: Theme.of(dctx)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: BeeTokens.textTertiary(context))),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  dialogOpen = false;
                  Navigator.of(dctx).pop();
                  // 返回到数据管理页面继续后台导入
                  if (mounted) {
                    // Pop回DataManagementPage: ImportConfirmPage -> ImportPage
                    Navigator.of(currentContext).pop(); // Close ImportConfirmPage
                    Navigator.of(currentContext).pop(); // Close ImportPage, back to DataManagementPage
                  }
                },
                child:
                    Text(AppLocalizations.of(context).importBackgroundImport),
              ),
              TextButton(
                onPressed: () {
                  _cancelled = true;
                  dialogOpen = false;
                  Navigator.of(dctx).pop();
                },
                child: Text(AppLocalizations.of(context).importCancelImport),
              ),
            ],
          );
        });
      },
    );

    // 定义进度变量
    int done = 0;

    try {
      // 调用统一导入服务
      final result = await dataImportService.importData(
        repo,
        ledgerId,
        importData,
        defaultCurrency: ledgerCurrency,
        rules: currentRules,
        onProgress: (processed, progressTotal) {
          done = processed;
          // 更新全局进度
          container.read(importProgressProvider.notifier).state = ImportProgress(
            running: true,
            total: total,
            done: done,
            ok: ok,
            fail: fail,
          );
          if (mounted) setState(() {});
        },
      );

      ok = result.inserted;
      fail = result.failed;
      skipped = skippedTypes.values.fold(0, (a, b) => a + b);
      done = total;

      // 勾了「保存为规则」→ 把本次分类映射固化成 source_category 规则，
      // 下次导入同源分类自动套用。失败不影响导入结果。
      if (saveRulesAsMapping && _hasMappedCategory && result.inserted > 0) {
        try {
          await _saveMappingAsRules();
        } catch (_) {
          // 规则写入失败忽略：交易已经入库，规则可稍后在规则页补
        }
      }

      // 显式触发一次同步上推。SyncCoordinator 监听 local_changes 表已经会
      // 自动调度,这里作为兜底:provider 重建瞬间 / 边界条件下 coordinator
      // 还没就位时,UI 显式触发也能把刚导入的数据推上云端。
      // fire-and-forget:不阻塞导入完成动画。
      try {
        // ignore: unawaited_futures
        PostProcessor.syncC(container, ledgerId: ledgerId);
      } catch (_) {
        // 忽略同步触发错误,导入本身已经成功
      }
    } catch (e) {
      // 导入失败
      if (mounted) {
        showToast(context, AppLocalizations.of(context).importTransactionFailed('$e'));
      }
      fail = total - ok; // 更新失败数
    }

    // 即使页面已被关闭（mounted=false），也要继续更新全局进度供"我的"页展示
    // 先切换为"完成"以驱动 UI 展示成功动画/提示（不等待云上传）
    try {
      container.read(importProgressProvider.notifier).state = ImportProgress(
        running: false,
        total: total,
        done: done,
        ok: ok,
        fail: fail,
        ledgerId: ledgerId, // 设置账本ID，用于触发账本列表页面刷新
        skipped: skipped, // 跳过的记录数
        skippedTypes: skippedTypes, // 跳过的类型及数量
      );
    } catch (_) {
      // 忽略进度更新错误
    }

    // 延迟清空和刷新（不依赖页面状态，即使页面销毁也要执行）
    if (!_cancelled) {
      Future<void>.delayed(const Duration(seconds: 5), () {
        // 延长到5秒，让用户看到动画
        try {
          container.read(importProgressProvider.notifier).state =
              ImportProgress.empty;
          // 刷新"我的"页统计（笔数/天数）
          container.invalidate(countsForLedgerProvider(ledgerId));
          // 触发全局统计刷新（用于"我的"页顶部聚合信息）
          container.read(statsRefreshProvider.notifier).state++;
          // 触发一次同步状态刷新（UI 端会复用缓存避免闪烁）
          container.read(syncStatusRefreshProvider.notifier).state++;
        } catch (_) {
          // 忽略延迟刷新错误
        }
      });
    }

    // Check if context is still mounted for UI operations
    if (!currentContext.mounted) {
      return;
    }

    // 显示导入完成提示
    final cancelledText =
        _cancelled ? AppLocalizations.of(currentContext).importCancelled : '';
    final l10nToast = AppLocalizations.of(currentContext);

    // 构建提示信息
    String message = l10nToast.importCompleted(cancelledText, fail, ok);
    bool hasSkipped = skipped > 0;

    if (hasSkipped) {
      // 显示类型不匹配的跳过记录
      final typeSkipped = skippedTypes.values.fold(0, (a, b) => a + b);

      if (typeSkipped > 0) {
        final skippedList = skippedTypes.entries
            .map((e) => '${e.key}(${e.value})')
            .join('、');
        message += '\n${l10nToast.importSkippedNonTransactionTypes(typeSkipped)}\n$skippedList';
      }
    }

    // Handle UI operations before cloud upload
    if (dialogOpen) {
      Navigator.of(currentContext).pop();
    }

    // 判断显示方式: 完全成功用toast,有失败或跳过用弹窗
    if (fail == 0 && !hasSkipped) {
      // 完全成功: 使用toast,然后关闭页面
      showToast(currentContext, message);
      // 关闭确认页 -> 返回到数据管理页面
      // Pop回DataManagementPage: ImportConfirmPage -> ImportPage
      Navigator.of(currentContext).pop(); // Close ImportConfirmPage
      Navigator.of(currentContext).pop(); // Close ImportPage, back to DataManagementPage
    } else {
      // 有失败或跳过: 使用弹窗显示详细信息,等待用户确认后再关闭页面
      await showDialog(
        context: currentContext,
        builder: (ctx) => AlertDialog(
          title: Text(l10nToast.importCompleteTitle),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10nToast.commonConfirm),
            ),
          ],
        ),
      );

      // 用户确认后再关闭页面
      if (currentContext.mounted) {
        Navigator.of(currentContext).pop(); // Close ImportConfirmPage
        Navigator.of(currentContext).pop(); // Close ImportPage, back to DataManagementPage
      }
    }
    // 返回后再显式刷新一次全局统计，确保顶部汇总即时更新
    try {
      container.read(statsRefreshProvider.notifier).state++;
    } catch (_) {}

    // 导入完成后，账本列表页面会通过监听 importProgressProvider 自动刷新
    // ledgerId 已经在上面的 importProgressProvider 中设置
  }

  /// 支付方式规整结果 → 实际使用的账户名。
  /// - null：这笔没有出资渠道，不挂账户（也绝不建一个叫「/」的账户）
  /// - 命中已有账户：用已有账户的名字，让导入服务按名字复用而不是另建新号
  String? _resolvedAccountName(
    PaymentAccountHint? hint,
    List<schema.Account> bankAccounts,
  ) {
    if (hint == null) return null;
    final matchedId = hint.matchedId;
    if (matchedId != null) {
      for (final a in bankAccounts) {
        if (a.id == matchedId) return a.name;
      }
    }
    return hint.name;
  }

  /// 将CSV数据转换为统一的ImportData格式
  ImportData _buildImportDataFromCsv({
    required List<List<String>> rows,
    required int dataStart,
    required Map<String, int?> mapping,
    required Map<String, int?> categoryMapping,
    required Map<String, int> skippedTypes,
    required String ledgerCurrency,
    List<schema.CategoryRule>? rules,
    List<schema.Account> bankAccounts = const [],
  }) {
    final accounts = <ImportAccount>[];
    final categories = <ImportCategory>[];
    final tags = <ImportTag>[];
    final transactions = <ImportTransaction>[];

    // 源分类规则(按行 kind 匹配):命中就不必再按原名建分类,
    // 也不会因为「保持原名」多建一堆垃圾分类。
    final sourceRules = <schema.CategoryRule>[
      for (final r in (rules ?? const <schema.CategoryRule>[]))
        if (r.field == 'source_category') r,
    ];
    int? ruleHitFor(String? name, String? kind) {
      if (name == null || kind == null || sourceRules.isEmpty) return null;
      return CategoryRuleEngine.match(
        text: name,
        kind: kind,
        rules: sourceRules,
      );
    }

    // 备注规则（具体商户名，如「深圳大学」）优先于源分类规则（笼统分类名）。
    // 这里必须也跑一遍：本向导一旦预解析出 categoryId，导入服务会直接采用，
    // 落库阶段就不会再跑 note 规则了。
    final noteRules = <schema.CategoryRule>[
      for (final r in (rules ?? const <schema.CategoryRule>[]))
        if (r.field == 'note') r,
    ];
    int? noteRuleHitFor(String? text, String? kind) {
      if (text == null || text.isEmpty || kind == null || noteRules.isEmpty) {
        return null;
      }
      return CategoryRuleEngine.match(text: text, kind: kind, rules: noteRules);
    }

    final accountIdx = mapping['account'];
    final fromAccountIdx = mapping['from_account'];
    final toAccountIdx = mapping['to_account'];
    final tagsIdx = mapping['tags'];

    // 收集唯一账户和标签
    final uniqueAccountNames = <String>{};
    /// 账户名 → 账户类型（cash / bank_card / credit_card / wechat / alipay）
    final accountTypeByName = <String, String>{};
    final uniqueTagNames = <String>{};
    // 支付方式原始值 → 规整结果（null = 这笔没有出资渠道）。两遍扫描共用一份缓存，
    // 保证「预览看到的」和「实际建号的」完全一致。
    final paymentHints = <String, PaymentAccountHint?>{};
    PaymentAccountHint? hintFor(String raw) => paymentHints.containsKey(raw)
        ? paymentHints[raw]
        : (paymentHints[raw] =
            PaymentMethodMapper.resolve(raw, bankAccounts: bankAccounts));
    // 收集分类信息（用于创建分类）
    final categoryInfoMap = <String, ({String kind, String? icon, String? parentName})>{};

    // 第一遍：收集账户、标签、分类信息
    for (int i = dataStart; i < rows.length; i++) {
      final r = rows[i];

      String? getBy(String key) {
        final userIdx = mapping[key];
        if (userIdx != null && userIdx >= 0 && userIdx < r.length) {
          final val = r[userIdx].toString().trim();
          return val.isNotEmpty ? val : null;
        }
        return null;
      }

      // 收集账户名（「支付方式」列先规整成真正的账户，null 的直接跳过）
      if (accountIdx != null && accountIdx < r.length) {
        final name = r[accountIdx].toString().trim();
        if (name.isNotEmpty) {
          final hint = hintFor(name);
          final resolved = _resolvedAccountName(hint, bankAccounts);
          if (resolved != null) {
            uniqueAccountNames.add(resolved);
            accountTypeByName.putIfAbsent(resolved, () => hint!.type);
          }
        }
      }
      if (fromAccountIdx != null && fromAccountIdx < r.length) {
        final name = r[fromAccountIdx].toString().trim();
        if (name.isNotEmpty) uniqueAccountNames.add(name);
      }
      if (toAccountIdx != null && toAccountIdx < r.length) {
        final name = r[toAccountIdx].toString().trim();
        if (name.isNotEmpty) uniqueAccountNames.add(name);
      }

      // 收集标签名
      if (tagsIdx != null && tagsIdx < r.length) {
        final tagsStr = r[tagsIdx].toString().trim();
        if (tagsStr.isNotEmpty) {
          for (final tagName in tagsStr.split(',')) {
            final trimmed = tagName.trim();
            if (trimmed.isNotEmpty) uniqueTagNames.add(trimmed);
          }
        }
      }

      // 解析类型用于分类收集
      final typeRaw = getBy('type') ?? 'expense';
      final typeStr = typeRaw.trim().toLowerCase();
      String? type;
      if (typeStr == '收入' || typeStr == '收' || typeStr == '入账' || typeStr == '进账' ||
          typeStr == '入帳' || typeStr == '進帳' ||  // 繁体
          typeStr == 'income' || typeStr == 'revenue' || typeStr == 'earning') {
        type = 'income';
      } else if (typeStr == '支出' || typeStr == '支' || typeStr == '出账' ||
                 typeStr == '消费' || typeStr == '花费' ||
                 typeStr == '出帳' || typeStr == '消費' || typeStr == '花費' ||  // 繁体
                 typeStr == 'expense' || typeStr == 'spending' || typeStr == 'expenditure') {
        type = 'expense';
      } else if (typeStr == '转账' || typeStr == '轉帳' || typeStr == 'transfer') {  // 添加繁体
        type = 'transfer';
      }

      // 收集分类信息（仅非转账）
      if (type != null && type != 'transfer') {
        final categoryName = getBy('category');
        final subCategoryName = getBy('sub_category');
        // 第一遍扫描也要拿到备注，才能判断 note 规则是否命中
        final rowNote = getBy('note');
        final categoryIcon = getBy('category_icon');
        final subCategoryIcon = getBy('sub_category_icon');

        // 只有两级分类（自家导出）才按原名补建父/子分类，保住层级结构；
        // 单级分类不再按原名建分类 —— 未映射的交给导入服务的
        // 「规则 → 同名复用 → 其他」，避免每次导入都堆一堆垃圾分类。
        if (subCategoryName != null && categoryName != null) {
          // 父子任一侧被规则命中就不再按原名建分类
          if (ruleHitFor(categoryName, type) == null &&
              noteRuleHitFor(rowNote, type) == null) {
            final parentKey = '$categoryName:$type';
            categoryInfoMap.putIfAbsent(parentKey, () => (
              kind: type!,
              icon: categoryIcon,
              parentName: null,
            ));
          }
          if (ruleHitFor(subCategoryName, type) == null &&
              noteRuleHitFor(rowNote, type) == null) {
            final subKey = '$subCategoryName:$type:$categoryName';
            categoryInfoMap.putIfAbsent(subKey, () => (
              kind: type!,
              icon: subCategoryIcon,
              parentName: categoryName,
            ));
          }
        }
      }
    }

    // 构建账户列表（类型取自支付方式规整结果，转出/转入等普通账户保持 cash）
    for (final name in uniqueAccountNames) {
      accounts.add(ImportAccount(
        name: name,
        type: accountTypeByName[name] ?? 'cash',
        currency: ledgerCurrency,
      ));
    }

    // 构建标签列表
    for (final name in uniqueTagNames) {
      tags.add(ImportTag(name: name));
    }

    // 构建分类列表（先一级后二级）
    final level1Categories = categoryInfoMap.entries
        .where((e) => e.value.parentName == null)
        .toList();
    final level2Categories = categoryInfoMap.entries
        .where((e) => e.value.parentName != null)
        .toList();

    for (final entry in level1Categories) {
      final parts = entry.key.split(':');
      final name = parts[0];
      final kind = parts[1];
      categories.add(ImportCategory(
        name: name,
        kind: kind,
        level: 1,
        icon: entry.value.icon,
      ));
    }
    for (final entry in level2Categories) {
      final parts = entry.key.split(':');
      final name = parts[0];
      final kind = parts[1];
      final parentName = parts[2];
      categories.add(ImportCategory(
        name: name,
        kind: kind,
        level: 2,
        icon: entry.value.icon,
        parentName: parentName,
      ));
    }

    // 第二遍：构建交易列表
    for (int i = dataStart; i < rows.length; i++) {
      final r = rows[i];

      String? getBy(String key) {
        final userIdx = mapping[key];
        if (userIdx != null && userIdx >= 0 && userIdx < r.length) {
          final val = r[userIdx].toString().trim();
          return val.isNotEmpty ? val : null;
        }
        return null;
      }

      final dateStr = getBy('date');
      final typeRaw = getBy('type') ?? 'expense';
      final amountStr = getBy('amount');
      final currencyStr = getBy('currency')?.trim().toUpperCase();
      final categoryName = getBy('category');
      final subCategoryName = getBy('sub_category');
      // 「支付方式」列 → 规整账户名；无出资渠道（`/`）时传 null，这笔不挂账户
      final rawAccountName = getBy('account');
      final accountName = rawAccountName == null
          ? null
          : _resolvedAccountName(hintFor(rawAccountName), bankAccounts);
      final fromAccountName = getBy('from_account');
      final toAccountName = getBy('to_account');
      final note = getBy('note');
      final tagsStr = getBy('tags');
      final attachmentsStr = getBy('attachments');

      // 类型识别
      final typeStr = typeRaw.trim().toLowerCase();
      String? type;
      if (typeStr == '收入' || typeStr == '收' || typeStr == '入账' || typeStr == '进账' ||
          typeStr == '入帳' || typeStr == '進帳' ||  // 繁体
          typeStr == 'income' || typeStr == 'revenue' || typeStr == 'earning') {
        type = 'income';
      } else if (typeStr == '支出' || typeStr == '支' || typeStr == '出账' ||
                 typeStr == '消费' || typeStr == '花费' ||
                 typeStr == '出帳' || typeStr == '消費' || typeStr == '花費' ||  // 繁体
                 typeStr == 'expense' || typeStr == 'spending' || typeStr == 'expenditure') {
        type = 'expense';
      } else if (typeStr == '转账' || typeStr == '轉帳' || typeStr == 'transfer') {  // 添加繁体
        type = 'transfer';
      } else {
        // 未识别的类型：记录并跳过
        skippedTypes[typeRaw.trim()] = (skippedTypes[typeRaw.trim()] ?? 0) + 1;
        continue;
      }

      // 金额解析
      final amountClean = (amountStr ?? '0').replaceAll(RegExp(r'[¥$,+-]'), '');
      final amount = double.tryParse(amountClean)?.abs() ?? 0.0;

      // 日期解析
      final date = DateParser.parse(dateStr);

      // 解析标签名称列表
      List<String>? tagNames;
      if (tagsStr != null && tagsStr.isNotEmpty) {
        tagNames = tagsStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      }

      // 解析附件文件名列表
      List<ImportAttachment>? attachments;
      if (attachmentsStr != null && attachmentsStr.isNotEmpty) {
        final fileNames = attachmentsStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
        if (fileNames.isNotEmpty) {
          attachments = fileNames.asMap().entries.map((entry) => ImportAttachment(
            fileName: entry.value,
            sortOrder: entry.key,
          )).toList();
        }
      }

      // 处理分类：支持用户映射和二级分类
      String? finalCategoryName;
      String? categoryKind;
      int? categoryId;

      if (type != 'transfer') {
        if (subCategoryName != null && categoryName != null) {
          // 有二级分类：优先用户映射，其次规则，最后按二级分类原名
          final chosenSub = categoryMapping[subCategoryName];
          final subRule = ruleHitFor(subCategoryName, type);
          final noteHit = noteRuleHitFor(note, type);
          if (chosenSub != null) {
            categoryId = chosenSub;
          } else if (noteHit != null) {
            categoryId = noteHit;
          } else if (subRule != null) {
            categoryId = subRule;
          } else {
            finalCategoryName = subCategoryName;
            categoryKind = type;
          }
        } else if (categoryName != null) {
          // 只有一级分类：用户映射 → 规则 → 保持原名
          final chosen = categoryMapping[categoryName];
          final ruleHit = ruleHitFor(categoryName, type);
          final noteHit = noteRuleHitFor(note, type);
          if (chosen != null) {
            categoryId = chosen;
          } else if (noteHit != null) {
            categoryId = noteHit;
          } else if (ruleHit != null) {
            categoryId = ruleHit;
          } else {
            finalCategoryName = categoryName;
            categoryKind = type;
          }
        }
      }

      if (currencyStr != null && !RegExp(r'^[A-Z]{3,8}$').hasMatch(currencyStr)) {
        throw FormatException('${AppLocalizations.of(context).importCurrencyInvalid} ${i + 1}: $currencyStr');
      }
      transactions.add(ImportTransaction(
        type: type,
        amount: amount,
        currencyCode: currencyStr,
        categoryName: finalCategoryName,
        categoryKind: categoryKind,
        categoryId: categoryId,
        happenedAt: date,
        note: note,
        accountName: type != 'transfer' ? accountName : null,
        fromAccountName: type == 'transfer' ? fromAccountName : null,
        toAccountName: type == 'transfer' ? toAccountName : null,
        tagNames: tagNames,
        attachments: attachments,
      ));
    }

    return ImportData(
      accounts: accounts,
      categories: categories,
      tags: tags,
      transactions: transactions,
    );
  }

  void _buildDistinctCategories() {
    final catIdx = mapping['category'];
    if (catIdx == null) {
      distinctCategories = [];
      categoryMapping = {};
      return;
    }
    final set = <String>{};
    final dataStart = widget.hasHeader ? (headerRow + 1) : 0;
    for (int i = dataStart; i < rows.length; i++) {
      if (catIdx < rows[i].length) {
        final name = rows[i][catIdx].trim();
        if (name.isNotEmpty) set.add(name);
      }
    }
    distinctCategories = set.toList()..sort();

    // 初始化分类映射为null，后续在FutureBuilder中进行自动匹配
    categoryMapping = {for (final n in distinctCategories) n: null};
  }

  /// 读取全部分类规则（priority 升序、id 升序，与引擎的匹配顺序一致）。
  /// local-only：直接走 databaseProvider 的 db，不额外加 repository 方法。
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

  /// 本次映射里是否至少有一项选了目标分类（勾选框的可用条件）
  bool get _hasMappedCategory => categoryMapping.values.any((v) => v != null);

  /// 把本次「源分类名 → 目标分类ID」的映射固化为 source_category 规则。
  /// 同 keyword + field 已存在则只更新 targetCategoryId（幂等）。
  Future<void> _saveMappingAsRules() async {
    final pairs = <String, int>{
      for (final e in categoryMapping.entries)
        if (e.value != null && e.key.trim().isNotEmpty) e.key.trim(): e.value!,
    };
    if (pairs.isEmpty) return;
    final db = ref.read(databaseProvider);
    final now = DateTime.now();
    for (final entry in pairs.entries) {
      final existing = await (db.select(db.categoryRules)
            ..where((r) =>
                r.keyword.equals(entry.key) &
                r.field.equals('source_category')))
          .get();
      if (existing.isNotEmpty) {
        // 已有同关键词规则：只刷新目标分类，避免重复堆积
        await (db.update(db.categoryRules)
              ..where((r) => r.id.equals(existing.first.id)))
            .write(schema.CategoryRulesCompanion(
          targetCategoryId: d.Value(entry.value),
          updatedAt: d.Value(now),
        ));
      } else {
        await db.into(db.categoryRules).insert(
              schema.CategoryRulesCompanion.insert(
                keyword: entry.key,
                matchType: const d.Value('equals'),
                field: const d.Value('source_category'),
                targetCategoryId: entry.value,
                kind: const d.Value(null),
                priority: const d.Value(10),
                enabled: const d.Value(true),
                createdAt: d.Value(now),
                updatedAt: d.Value(now),
              ),
            );
      }
    }
  }
}

// isolate 入口函数：在后台解析 CSV 文本
List<List<String>> _parseRowsIsolate(String input) {
  return CsvParser.parse(input);
}

Future<List<schema.Category>> _loadAllCategories(WidgetRef ref) async {
  final repo = ref.read(repositoryProvider);
  final expenseTopLevel = await repo.getTopLevelCategories('expense');
  final incomeTopLevel = await repo.getTopLevelCategories('income');

  final allCategories = <schema.Category>[];
  allCategories.addAll(expenseTopLevel);
  allCategories.addAll(incomeTopLevel);

  // 获取所有子分类
  for (final category in [...expenseTopLevel, ...incomeTopLevel]) {
    final subCategories = await repo.getSubCategories(category.id);
    allCategories.addAll(subCategories);
  }

  return allCategories;
}

class _PreviewTable extends StatelessWidget {
  final List<List<String>> rows;
  // 预览表格: 固定单元格宽度，避免在横向滚动环境中使用 Expanded 触发布局错误
  const _PreviewTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    const double cellWidth = 140;
    final isDark = BeeTokens.isDark(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: BeeTokens.border(context)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            for (int r = 0; r < rows.length; r++)
              Container(
                color: r == 0
                    ? (isDark ? Colors.grey.shade800 : Colors.grey.shade100)
                    : BeeTokens.surfaceElevated(context),
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                child: Row(
                  children: [
                    for (final cell in rows[r])
                      SizedBox(
                        width: cellWidth,
                        child: Text(
                          cell,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: BeeTokens.textPrimary(context),
                            fontWeight: r == 0 ? FontWeight.w600 : null,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
