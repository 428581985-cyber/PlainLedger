import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/db.dart' show Account;
import '../../providers.dart';
import '../../services/auto_bill/auto_bill_models.dart';
import '../../services/auto_bill/auto_bill_service.dart';
import '../../styles/tokens.dart';

/// 无感记账与灵动胶囊设置页
///
/// 包含：
/// - 无感记账总开关
/// - 通知监听（含真实绑定状态检测）/ 无障碍服务 / 悬浮窗权限引导
/// - 荣耀 MagicOS 后台保活设置入口
/// - 顶部灵动胶囊实机测试按钮
/// - 自定义「关键词 → 子账户」映射规则配置
/// - 最近捕获与去重调试日志
class AutoBillSettingsPage extends ConsumerStatefulWidget {
  const AutoBillSettingsPage({super.key});

  @override
  ConsumerState<AutoBillSettingsPage> createState() =>
      _AutoBillSettingsPageState();
}

class _AutoBillSettingsPageState extends ConsumerState<AutoBillSettingsPage>
    with WidgetsBindingObserver {
  final _service = AutoBillService.instance;
  AutoBillPermissionStatus _status = AutoBillPermissionStatus.empty;
  List<AccountMappingRule> _mappings = const [];
  List<Account> _accounts = const [];
  List<String> _logs = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshAll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshAll();
    }
  }

  Future<void> _refreshAll() async {
    final status = await _service.getPermissionStatus();
    final mappings = await _service.mappingService.loadRules();
    final accounts = await ref.read(repositoryProvider).getAllAccounts();
    final logs = await _service.getRecentLogs();
    if (!mounted) return;
    setState(() {
      _status = status;
      _mappings = mappings;
      _accounts = accounts.where((a) => !a.hidden).toList();
      _logs = logs;
      _loading = false;
    });
  }

  Future<void> _toggleEnabled(bool value) async {
    await _service.setEnabled(value);
    await _refreshAll();
  }

  Future<void> _testCapsule() async {
    if (!_status.overlay) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先开启「悬浮窗权限」后再测试灵动胶囊')),
        );
      }
      await _service.openOverlaySettings();
      return;
    }
    await _service.showTestCapsule();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已触发顶部灵动胶囊（默认自动入账，点击胶囊可修改）')),
      );
    }
    Future.delayed(const Duration(milliseconds: 500), _refreshAll);
  }

  Future<void> _showAddMappingDialog() async {
    if (_accounts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在「账户」页创建至少一个账户')),
      );
      return;
    }

    final keywordCtrl = TextEditingController();
    var selectedAccount = _accounts.first;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('新增账户映射规则'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: keywordCtrl,
                decoration: const InputDecoration(
                  labelText: '匹配关键词',
                  hintText: '例如：零钱通、余额宝、8877、招行',
                ),
                autofocus: true,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: selectedAccount.id,
                decoration: const InputDecoration(labelText: '映射到账户'),
                items: [
                  for (final acc in _accounts)
                    DropdownMenuItem(
                      value: acc.id,
                      child: Text(
                        acc.cardLastFour != null && acc.cardLastFour!.isNotEmpty
                            ? '${acc.name} (${acc.cardLastFour})'
                            : acc.name,
                      ),
                    ),
                ],
                onChanged: (id) {
                  if (id == null) return;
                  final found = _accounts.firstWhere((a) => a.id == id);
                  setDialogState(() => selectedAccount = found);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (keywordCtrl.text.trim().isEmpty) return;
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;
    final keyword = keywordCtrl.text.trim();
    if (keyword.isEmpty) return;

    final next = [
      ..._mappings,
      AccountMappingRule(
        id: const Uuid().v4(),
        keyword: keyword,
        accountId: selectedAccount.id,
        accountName: selectedAccount.name,
        priority: _mappings.length + 1,
      ),
    ];
    await _service.mappingService.saveRules(next);
    await _service.syncAccountMappingsToNative();
    await _refreshAll();
  }

  Future<void> _deleteMapping(AccountMappingRule rule) async {
    final next = _mappings.where((r) => r.id != rule.id).toList();
    await _service.mappingService.saveRules(next);
    await _service.syncAccountMappingsToNative();
    await _refreshAll();
  }

  Future<void> _toggleMapping(AccountMappingRule rule, bool enabled) async {
    final next = [
      for (final r in _mappings)
        if (r.id == rule.id) r.copyWith(enabled: enabled) else r,
    ];
    await _service.mappingService.saveRules(next);
    await _service.syncAccountMappingsToNative();
    await _refreshAll();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      appBar: AppBar(
        title: const Text('无感记账与灵动胶囊'),
        actions: [
          IconButton(
            onPressed: _refreshAll,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新状态',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 36),
              children: [
                _buildCard(
                  context,
                  children: [
                    SwitchListTile(
                      value: _status.enabled,
                      onChanged: _toggleEnabled,
                      title: const Text(
                        '启用无感记账',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      subtitle: const Text(
                        '仅监听微信、支付宝与银行卡动账；纯本地规则解析，默认自动入账',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
                _sectionTitle(context, '核心权限（双引擎 + 灵动胶囊）'),
                _buildCard(
                  context,
                  children: [
                    _permissionTile(
                      context,
                      icon: Icons.notifications_active_outlined,
                      title: '通知使用权（引擎一）',
                      subtitle: _status.notificationListener
                          ? (_status.notificationConnected
                              ? '已开启并正常绑定（监听微信/支付宝/银行推送与短信）'
                              : '开关已开但服务未绑定，请重新开关一次恢复')
                          : '用于捕获微信、支付宝、银行推送及消费短信',
                      granted: _status.notificationListener &&
                          _status.notificationConnected,
                      warning: _status.notificationListener &&
                          !_status.notificationConnected,
                      onTap: _service.openNotificationListenerSettings,
                    ),
                    _divider(context),
                    _permissionTile(
                      context,
                      icon: Icons.accessibility_new_rounded,
                      title: '无障碍服务（引擎二）',
                      subtitle: '覆盖不发通知栏消息的微信/支付宝支付成功页',
                      granted: _status.accessibility,
                      onTap: _service.openAccessibilitySettings,
                    ),
                    _divider(context),
                    _permissionTile(
                      context,
                      icon: Icons.layers_outlined,
                      title: '悬浮窗权限（灵动胶囊）',
                      subtitle: '在荣耀 Magic 8 顶部打孔区弹出紧凑胶囊，点按可快速修改',
                      granted: _status.overlay,
                      onTap: _service.openOverlaySettings,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: FilledButton.icon(
                    onPressed: _testCapsule,
                    icon: const Icon(Icons.auto_awesome_motion_rounded, size: 18),
                    label: const Text('测试顶部灵动胶囊（模拟 ¥28.50 瑞幸咖啡）'),
                  ),
                ),
                _sectionTitle(context, '荣耀 MagicOS 后台保活'),
                _buildCard(
                  context,
                  children: [
                    _permissionTile(
                      context,
                      icon: Icons.battery_charging_full_rounded,
                      title: '忽略电池优化',
                      subtitle: '防止系统休眠回收无感记账服务',
                      granted: _status.batteryOptimization,
                      onTap: _service.requestIgnoreBatteryOptimizations,
                    ),
                    _divider(context),
                    ListTile(
                      leading: Icon(Icons.rocket_launch_outlined,
                          color: BeeTokens.iconSecondary(context)),
                      title: const Text('应用启动管理（MagicOS）',
                          style: TextStyle(fontSize: 14)),
                      subtitle: const Text(
                        '建议关闭「自动管理」，手动开启「允许自启动 / 允许后台活动」',
                        style: TextStyle(fontSize: 12),
                      ),
                      trailing: const Icon(Icons.chevron_right, size: 20),
                      onTap: _service.openHonorAppLaunchSettings,
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                        child: _sectionTitle(context, '自定义「关键词 → 账户」映射')),
                    TextButton.icon(
                      onPressed: _showAddMappingDialog,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('新增'),
                    ),
                  ],
                ),
                _buildCard(
                  context,
                  children: _mappings.isEmpty
                      ? [
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text(
                              '暂无自定义映射规则。未配置时将按银行卡尾号和子账户名自动匹配；'
                              '可点击右上角「新增」例如：零钱通 → 微信零钱通、8877 → 招行工资卡。',
                              style: TextStyle(fontSize: 12, height: 1.6),
                            ),
                          ),
                        ]
                      : [
                          for (var i = 0; i < _mappings.length; i++) ...[
                            if (i > 0) _divider(context),
                            ListTile(
                              title: Text(
                                '${_mappings[i].keyword}  →  ${_mappings[i].accountName}',
                                style: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w500),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Switch(
                                    value: _mappings[i].enabled,
                                    onChanged: (v) =>
                                        _toggleMapping(_mappings[i], v),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline,
                                        size: 20),
                                    onPressed: () =>
                                        _deleteMapping(_mappings[i]),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                ),
                Row(
                  children: [
                    Expanded(child: _sectionTitle(context, '最近捕获与去重日志')),
                    if (_logs.isNotEmpty)
                      TextButton(
                        onPressed: () async {
                          await _service.clearRecentLogs();
                          await _refreshAll();
                        },
                        child: const Text('清空'),
                      ),
                  ],
                ),
                _buildCard(
                  context,
                  children: _logs.isEmpty
                      ? [
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text(
                              '暂无记录。开启权限后进行消费或点击上方「测试顶部灵动胶囊」即可在此查看捕获与合并日志。',
                              style: TextStyle(fontSize: 12, height: 1.6),
                            ),
                          ),
                        ]
                      : [
                          for (var i = 0; i < _logs.length; i++) ...[
                            if (i > 0) _divider(context),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              child: Text(
                                _logs[i],
                                style: TextStyle(
                                  fontSize: 12,
                                  color: BeeTokens.textSecondary(context),
                                ),
                              ),
                            ),
                          ],
                        ],
                ),
              ],
            ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: BeeTokens.textTertiary(context),
        ),
      ),
    );
  }

  Widget _buildCard(BuildContext context, {required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: BeeTokens.surface(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BeeTokens.border(context), width: 0.5),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }

  Widget _divider(BuildContext context) => Divider(
        height: 0.5,
        thickness: 0.5,
        indent: 16,
        color: BeeTokens.divider(context),
      );

  Widget _permissionTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool granted,
    bool warning = false,
    required VoidCallback onTap,
  }) {
    final badgeColor = granted
        ? const Color(0xFF1BAF7A)
        : (warning ? const Color(0xFFEDA100) : BeeTokens.textTertiary(context));
    final badgeText = granted ? '已就绪' : (warning ? '需重绑' : '去开启');

    return ListTile(
      leading: Icon(icon, color: BeeTokens.iconSecondary(context)),
      title: Text(title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: badgeColor.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          badgeText,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: badgeColor,
          ),
        ),
      ),
      onTap: onTap,
    );
  }
}
