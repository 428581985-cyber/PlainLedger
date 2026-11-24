import 'package:drift/drift.dart' as d;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../providers/budget_providers.dart';
import '../../services/billing/post_processor.dart';
import '../../styles/tokens.dart';
import '../../utils/category_utils.dart';
import '../../utils/currencies.dart';
import '../../utils/shared_ledger_picker_filter.dart';
import '../../utils/transaction_edit_utils.dart';
import '../../widgets/biz/account_selector.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/category_icon.dart';
import '../../widgets/ui/ui.dart';

/// 一笔交易的全部关联信息，供明细页一次性加载。
class _DetailData {
  final Transaction tx;
  final Category? category;
  final Account? account;
  final Account? toAccount;
  final List<Tag> tags;
  final List<TransactionAttachment> attachments;

  const _DetailData({
    required this.tx,
    required this.category,
    required this.account,
    required this.toAccount,
    required this.tags,
    required this.attachments,
  });
}

/// 只读优先：一次把交易行、分类、账户、标签、附件查齐。
/// 每次字段就地编辑后 invalidate 它，页面原地重新取数并显示新值。
final _txDetailProvider =
    FutureProvider.autoDispose.family<_DetailData, int>((ref, id) async {
  final repo = ref.watch(repositoryProvider);
  final db = ref.watch(databaseProvider);
  final tx = await repo.getTransactionById(id);
  if (tx == null) throw StateError('交易不存在或已删除');

  // 共享账本 Editor 视角下 categoryId / accountId 为 null，真实引用存在
  // *SyncIdOverride。把 override 转成 synthetic id 后统一走 db 反查，
  // 正数 id 查主表、负数 id 查 SharedLedger* 镜像表。
  int? effectiveId(int? id, String? overrideSyncId) => id ??
      (overrideSyncId != null ? syntheticIdForSyncId(overrideSyncId) : null);

  final catId = effectiveId(tx.categoryId, tx.categorySyncIdOverride);
  final accId = effectiveId(tx.accountId, tx.accountSyncIdOverride);
  final toAccId = effectiveId(tx.toAccountId, tx.toAccountSyncIdOverride);

  final category =
      catId == null ? null : await db.findCategoryBySyntheticId(catId);
  final account =
      accId == null ? null : await db.findAccountBySyntheticId(accId);
  final toAccount =
      toAccId == null ? null : await db.findAccountBySyntheticId(toAccId);
  final tags = await repo.getTagsForTransaction(id);
  final attachments = await repo.getAttachmentsByTransaction(id);

  return _DetailData(
    tx: tx,
    category: category,
    account: account,
    toAccount: toAccount,
    tags: tags,
    attachments: attachments,
  );
});

/// 交易明细页：只读优先，点哪个字段就只改哪个字段。
///
/// 由 [TransactionEditUtils.editTransaction] 统一路由进来；底部「编辑」按钮
/// 仍走原来的完整 TransactionEditorPage 流程，不破坏既有编辑能力。
class TransactionDetailPage extends ConsumerWidget {
  final int transactionId;

  const TransactionDetailPage({super.key, required this.transactionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(_txDetailProvider(transactionId));
    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      body: Column(
        children: [
          const PrimaryHeader(title: '账单明细', showBack: true, compact: true),
          Expanded(
            child: detailAsync.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: AppEmpty(text: '加载失败', subtext: '$e')),
              data: (data) => _buildBody(context, ref, data),
            ),
          ),
        ],
      ),
      bottomNavigationBar: detailAsync.maybeWhen(
        data: (data) => _buildBottomBar(context, ref, data),
        orElse: () => null,
      ),
    );
  }

  // ------------------------------------------------------------------
  // 页面主体
  // ------------------------------------------------------------------

  Widget _buildBody(BuildContext context, WidgetRef ref, _DetailData data) {
    final tx = data.tx;
    final isTransfer = tx.type == 'transfer';
    final currencyCode = tx.currencyCode ?? 'CNY';
    final symbol = getCurrencySymbol(currencyCode.toUpperCase());

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        _buildHero(context, ref, data),
        const SizedBox(height: 12),
        // 主体字段：每行独立可点，值直接可见，不再折叠进「更多」。
        SectionCard(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            children: [
              _row(
                context,
                icon: Icons.edit_note_outlined,
                label: '名称 / 备注',
                value: (tx.note == null || tx.note!.isEmpty) ? '无' : tx.note!,
                onTap: () => _editNote(context, ref, tx),
              ),
              _divider(context),
              _row(
                context,
                icon: Icons.schedule,
                label: '时间',
                value: DateFormat('yyyy-MM-dd HH:mm:ss')
                    .format(tx.happenedAt.toLocal()),
                onTap: () => _editDate(context, ref, tx),
              ),
              _divider(context),
              if (isTransfer) ...[
                _row(
                  context,
                  icon: Icons.arrow_upward,
                  label: '转出账户',
                  value: data.account?.name ?? '未设置',
                  onTap: () =>
                      _editAccount(context, ref, data, isToAccount: false),
                ),
                _divider(context),
                _row(
                  context,
                  icon: Icons.arrow_downward,
                  label: '转入账户',
                  value: data.toAccount?.name ?? '未设置',
                  onTap: () =>
                      _editAccount(context, ref, data, isToAccount: true),
                ),
              ] else
                _row(
                  context,
                  icon: Icons.account_balance_wallet_outlined,
                  label: '账户',
                  value: data.account?.name ?? '未设置',
                  onTap: () =>
                      _editAccount(context, ref, data, isToAccount: false),
                ),
              _divider(context),
              _row(
                context,
                icon: Icons.category_outlined,
                label: '分类',
                value: isTransfer
                    ? '转账（无分类）'
                    : CategoryUtils.getDisplayName(data.category?.name, context),
                onTap:
                    isTransfer ? null : () => _editCategory(context, ref, data),
              ),
              _divider(context),
              _row(
                context,
                icon: Icons.payments_outlined,
                label: '币种 / 金额',
                value: '$symbol${formatMoneyCompact(tx.amount)}  $currencyCode',
                onTap: () => _editAmount(context, ref, tx),
              ),
            ],
          ),
        ),
        // 标签、附件（如有），只读展示。
        if (data.tags.isNotEmpty || data.attachments.isNotEmpty) ...[
          const SizedBox(height: 12),
          SectionCard(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '标签 / 附件',
                  style: TextStyle(
                      fontSize: 13, color: BeeTokens.textSecondary(context)),
                ),
                if (data.tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final t in data.tags)
                          TagChip(name: t.name, color: t.color),
                      ],
                    ),
                  ),
                for (final a in data.attachments)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.attach_file,
                        size: 20, color: BeeTokens.iconSecondary(context)),
                    title: Text(
                      a.originalName ?? a.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13,
                          color: BeeTokens.textPrimary(context)),
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        // 账单标记：就地切换，与完整编辑器的两个开关保持同一份数据。
        SectionCard(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('不计入统计'),
                subtitle: const Text('开启后该笔不计入收支统计与图表'),
                value: tx.excludeFromStats,
                onChanged: (v) async {
                  final ok = await _writeFields(context, ref, tx,
                      excludeFromStats: d.Value<bool>(v));
                  if (ok && context.mounted) {
                    showToast(context, v ? '已设为不计入统计' : '已恢复计入统计');
                  }
                },
              ),
              SwitchListTile(
                title: const Text('不计入预算'),
                subtitle: const Text('开启后该笔不计入预算用量'),
                value: tx.excludeFromBudget,
                onChanged: (v) async {
                  final ok = await _writeFields(context, ref, tx,
                      excludeFromBudget: d.Value<bool>(v));
                  if (ok && context.mounted) {
                    showToast(context, v ? '已设为不计入预算' : '已恢复计入预算');
                  }
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 顶部：金额大字 + 类型 + 可点的分类图标与分类名。
  Widget _buildHero(BuildContext context, WidgetRef ref, _DetailData data) {
    final tx = data.tx;
    final isTransfer = tx.type == 'transfer';
    final typeLabel = tx.type == 'income'
        ? '收入'
        : (tx.type == 'expense' ? '支出' : '转账');
    final amountColor = isTransfer
        ? BeeTokens.info(context)
        : (tx.type == 'income'
            ? BeeTokens.success(context)
            : BeeTokens.error(context));
    final currencyCode = tx.currencyCode ?? 'CNY';
    final symbol = getCurrencySymbol(currencyCode.toUpperCase());
    final sign = tx.type == 'expense'
        ? '-'
        : (tx.type == 'income' ? '+' : '');
    final categoryName = isTransfer
        ? '转账'
        : CategoryUtils.getDisplayName(data.category?.name, context);

    return SectionCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            '$sign$symbol${formatMoneyCompact(tx.amount)}',
            style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.w700,
                color: amountColor),
          ),
          const SizedBox(height: 6),
          Text(typeLabel,
              style: TextStyle(
                  fontSize: 13, color: BeeTokens.textSecondary(context))),
          const SizedBox(height: 16),
          // 点图标 / 点分类名都只打开分类选择器。
          InkWell(
            onTap:
                isTransfer ? null : () => _editCategory(context, ref, data),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  isTransfer
                      ? Icon(Icons.swap_horiz,
                          size: 28, color: BeeTokens.iconPrimary(context))
                      : CategoryIconWidget(
                          category: data.category,
                          size: 28,
                          showBackground: true,
                        ),
                  const SizedBox(width: 10),
                  Text(categoryName,
                      style: TextStyle(
                          fontSize: 16,
                          color: BeeTokens.textPrimary(context))),
                  if (!isTransfer) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right,
                        size: 18, color: BeeTokens.iconTertiary(context)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    VoidCallback? onTap,
  }) {
    return AppListTile(
      leading: icon,
      title: label,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 190),
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 14, color: BeeTokens.textPrimary(context)),
            ),
          ),
          if (onTap != null)
            Icon(Icons.chevron_right,
                size: 18, color: BeeTokens.iconTertiary(context)),
        ],
      ),
      onTap: onTap,
    );
  }

  Widget _divider(BuildContext context) => Divider(
        height: 1,
        color: BeeTokens.divider(context),
        indent: 48,
      );

  Widget _buildBottomBar(
      BuildContext context, WidgetRef ref, _DetailData data) {
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _confirmDelete(context, ref, data.tx),
                icon: const Icon(Icons.delete_outline),
                label: Text(l10n.commonDelete),
                style: OutlinedButton.styleFrom(
                    foregroundColor: BeeTokens.error(context)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: () async {
                  // 完整编辑仍走原来的全流程；返回后明细页重新取数。
                  await TransactionEditUtils.editTransactionDirect(
                      context, ref, data.tx);
                  if (context.mounted) {
                    _refreshProviders(ref, data.tx.id, data.tx.ledgerId);
                  }
                },
                icon: const Icon(Icons.edit_outlined),
                label: Text(l10n.commonEdit),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // 写库 / 刷新
  // ------------------------------------------------------------------

  /// 分类、名称、时间、金额、账单标记走 LocalRepository.updateTransaction
  /// （自带 changeTracker 记录与 v30 币种联动）。
  ///
  /// 注意：该方法对 categoryId / note / *SyncIdOverride 是「传 null 即写入」
  /// 的语义，所以这里始终用当前 tx 的原值补齐未改动的字段，只替换目标字段，
  /// 避免就地编辑把别的列误清空。accountId 故意不传（dart null = absent），
  /// 账户改由 updateTransactionFields 单独更新。
  Future<bool> _writeFields(
    BuildContext context,
    WidgetRef ref,
    Transaction tx, {
    d.Value<int?>? categoryId,
    d.Value<String?>? note,
    d.Value<DateTime?>? happenedAt,
    d.Value<double>? amount,
    d.Value<bool>? excludeFromStats,
    d.Value<bool>? excludeFromBudget,
    d.Value<String?>? categorySyncIdOverride,
  }) async {
    try {
      await ref.read(repositoryProvider).updateTransaction(
            id: tx.id,
            type: tx.type,
            amount: amount?.value ?? tx.amount,
            categoryId: categoryId != null ? categoryId.value : tx.categoryId,
            note: note != null ? note.value : tx.note,
            happenedAt: happenedAt?.value ?? tx.happenedAt,
            categorySyncIdOverride: categorySyncIdOverride != null
                ? categorySyncIdOverride.value
                : tx.categorySyncIdOverride,
            accountSyncIdOverride: tx.accountSyncIdOverride,
            toAccountSyncIdOverride: tx.toAccountSyncIdOverride,
            excludeFromStats: excludeFromStats?.value ?? tx.excludeFromStats,
            excludeFromBudget:
                excludeFromBudget?.value ?? tx.excludeFromBudget,
          );
      // 与分类详情页删除/编辑一致：统一同步 + 状态刷新（后台静默）。
      await PostProcessor.sync(ref, ledgerId: tx.ledgerId);
      _refreshProviders(ref, tx.id, tx.ledgerId);
      return true;
    } catch (e) {
      if (context.mounted) showToast(context, '保存失败：$e');
      return false;
    }
  }

  /// 账户（转出 / 转入）走 updateTransactionFields：它只对 accountId /
  /// toAccountId 用 absent 语义，是最干净的单字段更新，且自带 changeTracker。
  /// synthetic 账户（id < 0）反查 Owner 的 syncId 写 override，而不是把负数
  /// 直接写进 accountId。
  Future<void> _writeAccountField(
    BuildContext context,
    WidgetRef ref,
    Transaction tx, {
    required bool isToAccount,
    required int? selectedId,
  }) async {
    try {
      final repo = ref.read(repositoryProvider);
      final db = ref.read(databaseProvider);
      String? syncId;
      if (selectedId != null && selectedId < 0) {
        final acc = await db.findAccountBySyntheticId(selectedId);
        syncId = acc?.syncId;
      }
      final effectiveId =
          (selectedId != null && selectedId < 0) ? null : selectedId;
      await repo.updateTransactionFields(
        id: tx.id,
        accountId: isToAccount ? null : d.Value<int?>(effectiveId),
        toAccountId: isToAccount ? d.Value<int?>(effectiveId) : null,
        accountSyncIdOverride: isToAccount ? null : syncId,
        toAccountSyncIdOverride: isToAccount ? syncId : null,
        writeAccountSyncIdOverride: !isToAccount,
        writeToAccountSyncIdOverride: isToAccount,
      );
      await PostProcessor.sync(ref, ledgerId: tx.ledgerId);
      _refreshProviders(ref, tx.id, tx.ledgerId);
      if (context.mounted) showToast(context, '已更新账户');
    } catch (e) {
      if (context.mounted) showToast(context, '保存失败：$e');
    }
  }

  /// 明细页自身 + 全局统计/预算/分类刷新。
  void _refreshProviders(WidgetRef ref, int txId, int ledgerId) {
    ref.invalidate(_txDetailProvider(txId));
    ref.invalidate(categoriesProvider);
    ref.invalidate(countsForLedgerProvider(ledgerId));
    ref.read(statsRefreshProvider.notifier).state++;
    ref.read(budgetRefreshProvider.notifier).state++;
  }

  // ------------------------------------------------------------------
  // 各字段的就地编辑
  // ------------------------------------------------------------------

  Future<void> _editNote(
      BuildContext context, WidgetRef ref, Transaction tx) async {
    final controller = TextEditingController(text: tx.note ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改名称 / 备注'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 2,
          decoration: const InputDecoration(hintText: '输入名称或备注'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (value == null || !context.mounted) return;
    final ok = await _writeFields(context, ref, tx,
        note: d.Value<String?>(value));
    if (ok && context.mounted) showToast(context, '已更新名称');
  }

  Future<void> _editAmount(
      BuildContext context, WidgetRef ref, Transaction tx) async {
    final controller = TextEditingController(text: tx.amount.toString());
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改金额'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(hintText: '输入金额'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (value == null || !context.mounted) return;
    final parsed = double.tryParse(value.trim());
    if (parsed == null || parsed <= 0) {
      showToast(context, '请输入有效金额');
      return;
    }
    final ok = await _writeFields(context, ref, tx,
        amount: d.Value<double>(parsed));
    if (ok && context.mounted) showToast(context, '已更新金额');
  }

  Future<void> _editDate(
      BuildContext context, WidgetRef ref, Transaction tx) async {
    final initial = tx.happenedAt.toLocal();
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !context.mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !context.mounted) return;
    // showTimePicker 只到分钟，秒归零；展示侧仍按「精确到秒」格式化。
    final newValue =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    final ok = await _writeFields(context, ref, tx,
        happenedAt: d.Value<DateTime?>(newValue));
    if (ok && context.mounted) showToast(context, '已更新时间');
  }

  Future<void> _editCategory(
      BuildContext context, WidgetRef ref, _DetailData data) async {
    final tx = data.tx;
    final selected = await showCategorySelector(
      context,
      type: tx.type == 'income' ? 'income' : 'expense',
      currentCategoryId: data.category?.id,
      ledgerId: tx.ledgerId,
      title: '选择分类',
    );
    if (selected == null || !context.mounted) return;
    // 共享账本 Editor 视角：picker 返回 synthetic 分类（id < 0），
    // 真值写 categorySyncIdOverride，categoryId 留 null。
    final isSynthetic = selected.id < 0;
    final ok = await _writeFields(
      context,
      ref,
      tx,
      categoryId: d.Value<int?>(isSynthetic ? null : selected.id),
      categorySyncIdOverride:
          d.Value<String?>(isSynthetic ? selected.syncId : null),
    );
    if (ok && context.mounted) showToast(context, '已更新分类');
  }

  Future<void> _editAccount(
    BuildContext context,
    WidgetRef ref,
    _DetailData data, {
    required bool isToAccount,
  }) async {
    final tx = data.tx;
    final currentId = isToAccount ? data.toAccount?.id : data.account?.id;
    final picked = await showModalBottomSheet<_AccountPick>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BeeTokens.surfaceSheet(context),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _AccountPickerSheet(
        ledgerId: tx.ledgerId,
        initialAccountId: currentId,
        filterCurrency: tx.currencyCode,
        label: isToAccount ? '选择转入账户' : '选择账户',
      ),
    );
    if (picked == null || !context.mounted) return;
    await _writeAccountField(
      context,
      ref,
      tx,
      isToAccount: isToAccount,
      selectedId: picked.accountId,
    );
  }

  /// 二次确认后删除，写法与分类详情页 onDelete 一致：
  /// repo.deleteTransaction（内部含 changeTracker）+ PostProcessor.sync + 刷新。
  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, Transaction tx) async {
    final ok = await AppDialog.confirm<bool>(
          context,
          title: '确认删除',
          message: '确定要删除这笔交易吗？此操作无法撤销。',
        ) ??
        false;
    if (!ok || !context.mounted) return;
    try {
      await ref.read(repositoryProvider).deleteTransaction(tx.id);
      await PostProcessor.sync(ref, ledgerId: tx.ledgerId);
      _refreshProviders(ref, tx.id, tx.ledgerId);
      if (context.mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (context.mounted) showToast(context, '删除失败：$e');
    }
  }
}

/// 账户选择结果：包一层，用来区分「取消（返回 null）」和「选了无账户（id=null）」。
class _AccountPick {
  final int? accountId;
  const _AccountPick(this.accountId);
}

/// 把现成的 [AccountSelector] 包进底部抽屉，选中后点「确定」才写库。
class _AccountPickerSheet extends StatefulWidget {
  final int ledgerId;
  final int? initialAccountId;
  final String? filterCurrency;
  final String label;

  const _AccountPickerSheet({
    required this.ledgerId,
    required this.initialAccountId,
    required this.filterCurrency,
    required this.label,
  });

  @override
  State<_AccountPickerSheet> createState() => _AccountPickerSheetState();
}

class _AccountPickerSheetState extends State<_AccountPickerSheet> {
  late int? _selected = widget.initialAccountId;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.label,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: BeeTokens.textPrimary(context))),
            const SizedBox(height: 12),
            AccountSelector(
              selectedAccountId: _selected,
              ledgerId: widget.ledgerId,
              filterCurrency: widget.filterCurrency,
              pinnedAccountId: widget.initialAccountId,
              onAccountSelected: (id) => setState(() => _selected = id),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消')),
                const SizedBox(width: 8),
                FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, _AccountPick(_selected)),
                    child: const Text('确定')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
