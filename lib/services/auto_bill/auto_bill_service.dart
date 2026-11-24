import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' as d;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/db.dart';
import '../../main.dart' show globalNavigatorKey;
import '../../pages/transaction/transaction_editor_page.dart';
import '../../providers.dart';
import '../billing/post_processor.dart';
import '../category_rules/category_rule_engine.dart';
import '../system/logger_service.dart';
import 'account_mapping_service.dart';
import 'auto_bill_deduplicator.dart';
import 'auto_bill_models.dart';
import 'auto_bill_rule_engine.dart';

class AutoBillPermissionStatus {
  const AutoBillPermissionStatus({
    required this.notificationListener,
    required this.notificationConnected,
    required this.accessibility,
    required this.overlay,
    required this.batteryOptimization,
    required this.enabled,
    this.autoSaveEnabled = true,
  });

  final bool notificationListener;
  final bool notificationConnected;
  final bool accessibility;
  final bool overlay;
  final bool batteryOptimization;
  final bool enabled;
  final bool autoSaveEnabled;

  static const empty = AutoBillPermissionStatus(
    notificationListener: false,
    notificationConnected: false,
    accessibility: false,
    overlay: false,
    batteryOptimization: false,
    enabled: false,
    autoSaveEnabled: true,
  );

  factory AutoBillPermissionStatus.fromMap(Map<Object?, Object?> map) {
    return AutoBillPermissionStatus(
      notificationListener: (map['notificationListener'] as bool?) ?? false,
      notificationConnected: (map['notificationConnected'] as bool?) ?? false,
      accessibility: (map['accessibility'] as bool?) ?? false,
      overlay: (map['overlay'] as bool?) ?? false,
      batteryOptimization: (map['batteryOptimization'] as bool?) ?? false,
      enabled: (map['enabled'] as bool?) ?? true,
      autoSaveEnabled: (map['autoSaveEnabled'] as bool?) ?? true,
    );
  }
}

/// 无感记账 Flutter 侧总控服务：
/// - 桥接 Android 原生双引擎 MethodChannel(`com.plainledger.app/auto_bill`)
/// - 消费待同步队列并实时接收新事件，使用同一份 `assets/auto_bill_rules.json` 解析
/// - 结合自定义账户映射与 `CategoryRuleEngine` 自动入库或原地升级已有账单
/// - 响应灵动胶囊点击事件，直达 `TransactionEditorPage` 快速修改
class AutoBillService {
  AutoBillService._();
  static final AutoBillService instance = AutoBillService._();

  static const _channel = MethodChannel('com.plainledger.app/auto_bill');
  static const _eventTxMapPrefsKey = 'auto_bill_event_tx_map_v1';
  static const _tag = 'AutoBill';

  final AccountMappingService mappingService = AccountMappingService();
  AutoBillRuleEngine? _engine;
  AutoBillDeduplicator? _deduplicator;
  WidgetRef? _ref;
  bool _initialized = false;
  Future<void> _serialQueue = Future.value();

  /// eventId -> Drift transaction.id 映射，用于 60s 内更高精度来源升级更新 & 点击悬浮球编辑/撤销
  final Map<String, int> _eventToTxId = {};

  Future<void> _enqueue(Future<void> Function() task) {
    final next = _serialQueue.then((_) => task(), onError: (_) => task());
    _serialQueue = next.catchError((Object e, StackTrace st) {
      logger.error(_tag, '无感记账异步队列执行异常: $e', e, st);
    });
    return _serialQueue;
  }

  Future<void> initialize(WidgetRef ref) async {
    _ref = ref;
    if (!Platform.isAndroid) return;

    await _ensureReady();
    if (!_initialized) {
      _initialized = true;
      _channel.setMethodCallHandler(_handleNativeCall);
    }

    await syncAccountMappingsToNative();
    await drainAndProcessPending();
    await checkAndOpenPendingEdit();
  }

  void updateRef(WidgetRef ref) {
    _ref = ref;
  }

  Future<void> _ensureReady() async {
    if (_engine == null) {
      _engine = await AutoBillRuleEngine.loadFromAssets();
      _deduplicator = AutoBillDeduplicator(
        intermediaryMerchants: _engine!.intermediaryMerchants,
      );
    }
    if (_eventToTxId.isEmpty) {
      await _loadEventTxMap();
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onAutoBillEvent':
        final args = call.arguments;
        if (args is Map) {
          final map = Map<String, dynamic>.from(args);
          await _enqueue(() async {
            await _processRawEvent(AutoBillRawEvent.fromMap(map));
            await _channel.invokeMethod<dynamic>('drainPendingEvents');
          });
        }
        break;
      case 'onAutoBillCancelled':
        final eventId = call.arguments as String?;
        if (eventId != null && eventId.isNotEmpty) {
          await _enqueue(() async {
            await _cancelEvent(eventId);
            await _channel.invokeMethod<dynamic>('drainPendingCancelEventIds');
          });
        }
        break;
      case 'onCapsuleEditTapped':
        final eventId = call.arguments as String?;
        if (eventId != null && eventId.isNotEmpty) {
          await drainAndProcessPending();
          await openEditorForEvent(eventId);
        }
        break;
    }
  }

  Future<AutoBillPermissionStatus> getPermissionStatus() async {
    if (!Platform.isAndroid) return AutoBillPermissionStatus.empty;
    try {
      final res =
          await _channel.invokeMethod<Map<Object?, Object?>>('getPermissionStatus');
      if (res == null) return AutoBillPermissionStatus.empty;
      return AutoBillPermissionStatus.fromMap(res);
    } catch (e) {
      logger.warning(_tag, '获取无感记账权限状态失败: $e');
      return AutoBillPermissionStatus.empty;
    }
  }

  Future<void> setEnabled(bool enabled) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('setEnabled', {'enabled': enabled});
  }

  Future<void> setAutoSaveEnabled(bool enabled) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('setAutoSaveEnabled', {'enabled': enabled});
  }

  Future<void> openNotificationListenerSettings() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('openNotificationListenerSettings');
  }

  Future<void> openAccessibilitySettings() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('openAccessibilitySettings');
  }

  Future<void> openOverlaySettings() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('openOverlaySettings');
  }

  Future<void> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
  }

  Future<void> openHonorAppLaunchSettings() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('openHonorAppLaunchSettings');
  }

  Future<void> showTestCapsule() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('showTestCapsule');
  }

  Future<List<String>> getRecentLogs() async {
    if (!Platform.isAndroid) return const [];
    try {
      final list = await _channel.invokeMethod<List<dynamic>>('getRecentLogs');
      return (list ?? const []).map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> clearRecentLogs() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('clearRecentLogs');
  }

  Future<void> syncAccountMappingsToNative() async {
    if (!Platform.isAndroid) return;
    try {
      final rules = await mappingService.loadRules();
      final payload = rules
          .where((r) => r.enabled)
          .map((r) => {'keyword': r.keyword, 'accountName': r.accountName})
          .toList();
      await _channel.invokeMethod('syncAccountMappings', {'mappings': payload});
    } catch (e) {
      logger.warning(_tag, '同步账户映射到原生层失败: $e');
    }
  }

  Future<void> drainAndProcessPending() async {
    if (!Platform.isAndroid) return;
    await _enqueue(() async {
      try {
        await _ensureReady();
        final list =
            await _channel.invokeMethod<List<dynamic>>('drainPendingEvents');
        if (list != null && list.isNotEmpty) {
          for (final item in list) {
            if (item is Map) {
              final event =
                  AutoBillRawEvent.fromMap(Map<String, dynamic>.from(item));
              await _processRawEvent(event);
            }
          }
        }
        await _drainPendingCancelEventsInternal();
      } catch (e, st) {
        logger.error(_tag, '消费待同步无感记账队列失败: $e', e, st);
      }
    });
  }

  Future<void> drainPendingCancelEvents() async {
    if (!Platform.isAndroid) return;
    await _enqueue(_drainPendingCancelEventsInternal);
  }

  Future<void> _drainPendingCancelEventsInternal() async {
    try {
      await _ensureReady();
      final ids = await _channel
          .invokeMethod<List<dynamic>>('drainPendingCancelEventIds');
      if (ids == null || ids.isEmpty) return;
      for (final rawId in ids) {
        final id = rawId?.toString() ?? '';
        if (id.isNotEmpty) {
          await _cancelEvent(id);
        }
      }
    } catch (e, st) {
      logger.error(_tag, '处理待撤销无感记账队列失败: $e', e, st);
    }
  }

  Future<void> _cancelEvent(String eventId) async {
    final ref = _ref;
    if (ref == null) return;
    await _ensureReady();

    final txId = _eventToTxId.remove(eventId);
    if (txId == null) return;
    _eventToTxId.removeWhere((_, v) => v == txId);
    await _saveEventTxMap();

    final repo = ref.read(repositoryProvider);
    final ledgerId = ref.read(currentLedgerIdProvider);
    try {
      await repo.deleteTransaction(txId);
      logger.info(_tag, '已撤销删除自动入账 txId=$txId eventId=$eventId');
      await PostProcessor.sync(ref, ledgerId: ledgerId);
      ref.invalidate(countsForLedgerProvider(ledgerId));
      ref.read(statsRefreshProvider.notifier).state++;
    } catch (e, st) {
      logger.error(_tag, '撤销删除交易失败 txId=$txId: $e', e, st);
    }
  }

  Future<void> checkAndOpenPendingEdit() async {
    if (!Platform.isAndroid) return;
    try {
      final eventId =
          await _channel.invokeMethod<String?>('getPendingEditEventId');
      if (eventId != null && eventId.isNotEmpty) {
        await openEditorForEvent(eventId);
      }
    } catch (e) {
      logger.warning(_tag, '检查待编辑胶囊事件失败: $e');
    }
  }

  Future<void> openEditorForEvent(String eventId) async {
    final ref = _ref;
    if (ref == null) return;
    await _ensureReady();
    final txId = _eventToTxId[eventId];
    if (txId == null) {
      logger.warning(_tag, '未找到胶囊事件对应的交易 ID: $eventId');
      return;
    }
    final repo = ref.read(repositoryProvider);
    final tx = await repo.getTransactionById(txId);
    if (tx == null) return;

    final nav = globalNavigatorKey.currentState;
    if (nav == null) return;
    await nav.push(
      MaterialPageRoute(
        builder: (_) => TransactionEditorPage(
          initialKind: tx.type,
          quickAdd: true,
          editingTransactionId: tx.id,
          initialCategoryId: tx.categoryId,
          initialAmount: tx.amount,
          initialDate: tx.happenedAt,
          initialNote: tx.note,
          initialAccountId: tx.accountId,
        ),
      ),
    );
  }

  Future<void> _processRawEvent(AutoBillRawEvent event) async {
    final ref = _ref;
    if (ref == null) return;
    await _ensureReady();

    final parsed = _engine!.parse(event);
    if (parsed == null) return;

    final existingTxId = _eventToTxId[event.eventId];
    if (existingTxId != null) {
      // 原生侧已按同一 eventId 合并升级，直接更新对应交易
      await _upsertTransaction(
        ref: ref,
        eventId: event.eventId,
        bill: parsed,
        existingTransactionId: existingTxId,
      );
      return;
    }

    final decision = _deduplicator!.evaluate(
      newRecordKey: event.eventId,
      incoming: parsed,
    );
    switch (decision.action) {
      case DedupAction.skipDuplicate:
        if (decision.matchedKey != null &&
            _eventToTxId.containsKey(decision.matchedKey)) {
          _eventToTxId[event.eventId] = _eventToTxId[decision.matchedKey]!;
          await _saveEventTxMap();
        }
        return;
      case DedupAction.upgradeExisting:
        final targetTxId = decision.matchedKey != null
            ? _eventToTxId[decision.matchedKey!]
            : null;
        await _upsertTransaction(
          ref: ref,
          eventId: decision.matchedKey ?? event.eventId,
          bill: decision.mergedBill,
          existingTransactionId: targetTxId,
        );
        return;
      case DedupAction.insertNew:
        await _upsertTransaction(
          ref: ref,
          eventId: event.eventId,
          bill: decision.mergedBill,
          existingTransactionId: null,
        );
        return;
    }
  }

  Future<void> _upsertTransaction({
    required WidgetRef ref,
    required String eventId,
    required ParsedAutoBill bill,
    required int? existingTransactionId,
  }) async {
    final repo = ref.read(repositoryProvider);
    final db = ref.read(databaseProvider);
    final ledgerId = ref.read(currentLedgerIdProvider);

    final accounts = await repo.getAllAccounts();
    final customMappings = await mappingService.loadRules();
    final fallbackAccountId = bill.type == 'income'
        ? await ref.read(defaultIncomeAccountIdProvider.future)
        : await ref.read(defaultExpenseAccountIdProvider.future);
    final matchedAccount = AccountMappingService.resolveAccount(
      bill: bill,
      accounts: accounts,
      customRules: customMappings,
      fallbackAccountId: fallbackAccountId,
    );

    final effectiveKind = bill.type == 'transfer' ? 'transfer' : bill.type;
    int? categoryId;
    if (effectiveKind != 'transfer') {
      final categoryRules = await db.select(db.categoryRules).get();
      final ruleMatchText = [bill.merchant ?? '', bill.rawText].join(' ');
      categoryId = CategoryRuleEngine.match(
        text: ruleMatchText,
        kind: effectiveKind,
        rules: categoryRules,
      );
      if (categoryId == null) {
        final topCats = await repo.getTopLevelCategories(effectiveKind);
        Category? fallbackCat;
        for (final c in topCats) {
          if (c.name == '其他') {
            fallbackCat = c;
            break;
          }
        }
        fallbackCat ??= topCats.isNotEmpty ? topCats.first : null;
        categoryId = fallbackCat?.id;
      }
    }

    final note = bill.merchant ?? bill.accountHint ?? '自动记账';

    int txId;
    if (existingTransactionId != null) {
      await repo.updateTransaction(
        id: existingTransactionId,
        type: effectiveKind,
        amount: bill.amount,
        categoryId: categoryId,
        note: note,
        happenedAt: bill.timestamp,
        accountId: d.Value<int?>(matchedAccount?.id),
      );
      txId = existingTransactionId;
      logger.info(_tag, '无感记账升级更新 txId=$txId amount=${bill.amount} acc=${matchedAccount?.name}');
    } else {
      txId = await repo.addTransaction(
        ledgerId: ledgerId,
        type: effectiveKind,
        amount: bill.amount,
        categoryId: categoryId,
        happenedAt: bill.timestamp,
        note: note,
        accountId: matchedAccount?.id,
      );
      logger.info(_tag, '无感记账自动入账 txId=$txId amount=${bill.amount} acc=${matchedAccount?.name}');
    }

    _eventToTxId[eventId] = txId;
    await _saveEventTxMap();

    await PostProcessor.sync(ref, ledgerId: ledgerId);
    ref.invalidate(countsForLedgerProvider(ledgerId));
    ref.read(statsRefreshProvider.notifier).state++;
  }

  Future<void> _loadEventTxMap() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_eventTxMapPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      _eventToTxId.clear();
      for (final e in map.entries) {
        final v = (e.value as num?)?.toInt();
        if (v != null) _eventToTxId[e.key] = v;
      }
    } catch (_) {}
  }

  Future<void> _saveEventTxMap() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 仅保留最近 200 条映射，防止 SharedPreferences 膨胀
      if (_eventToTxId.length > 200) {
        final keys = _eventToTxId.keys.toList();
        for (final k in keys.take(_eventToTxId.length - 200)) {
          _eventToTxId.remove(k);
        }
      }
      await prefs.setString(_eventTxMapPrefsKey, jsonEncode(_eventToTxId));
    } catch (_) {}
  }
}
