import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:beecount/services/auto_bill/auto_bill_deduplicator.dart';
import 'package:beecount/services/auto_bill/auto_bill_models.dart';
import 'package:beecount/services/auto_bill/auto_bill_rule_engine.dart';

void main() {
  late AutoBillRuleEngine engine;

  setUpAll(() {
    final jsonStr = File('assets/auto_bill_rules.json').readAsStringSync();
    engine = AutoBillRuleEngine.fromJsonString(jsonStr);
  });

  group('AutoBillDeduplicator - 跨渠道合并与同渠道防误杀', () {
    test('先无障碍屏幕页(瑞幸咖啡)、后银行短信(尾号8877 + 财付通)：保留尾号与真实商户名', () {
      final dedup = AutoBillDeduplicator(
        intermediaryMerchants: engine.intermediaryMerchants,
      );
      const baseMs = 1732400000000;

      final screenBill = engine.parse(const AutoBillRawEvent(
        eventId: 'ev_screen',
        sourceType: AutoBillSourceType.accessibilityScreen,
        packageName: 'com.tencent.mm',
        title: '支付成功',
        text: '支付成功\n收款方：瑞幸咖啡\n¥35.00',
        timestampMs: baseMs,
      ))!;

      final r1 = dedup.evaluate(newRecordKey: 'ev_screen', incoming: screenBill);
      expect(r1.action, DedupAction.insertNew);
      expect(r1.mergedBill.merchant, '瑞幸咖啡');
      expect(r1.mergedBill.cardLastFour, isNull);

      final bankSmsBill = engine.parse(const AutoBillRawEvent(
        eventId: 'ev_sms',
        sourceType: AutoBillSourceType.bankSms,
        packageName: 'com.hihonor.mms',
        title: '95555',
        text: '【招商银行】您尾号8877的储蓄卡在财付通消费人民币35.00元，余额9000.00元',
        timestampMs: baseMs + 5000,
      ))!;

      final r2 = dedup.evaluate(newRecordKey: 'ev_sms', incoming: bankSmsBill);
      expect(r2.action, DedupAction.upgradeExisting);
      expect(r2.matchedKey, 'ev_screen');
      expect(r2.mergedBill.cardLastFour, '8877');
      expect(r2.mergedBill.bankName, '招商银行');
      // 真实商户「瑞幸咖啡」不被清算中介「财付通」覆盖
      expect(r2.mergedBill.merchant, '瑞幸咖啡');
    });

    test('已有高精确度银行短信后再来低精确度微信通知：跳过重复', () {
      final dedup = AutoBillDeduplicator(
        intermediaryMerchants: engine.intermediaryMerchants,
      );
      const baseMs = 1732400000000;

      final bankSms = engine.parse(const AutoBillRawEvent(
        eventId: 'ev_sms',
        sourceType: AutoBillSourceType.bankSms,
        packageName: 'com.hihonor.mms',
        title: '95555',
        text: '【招商银行】尾号8877储蓄卡在星巴克消费¥40.00',
        timestampMs: baseMs,
      ))!;
      expect(
        dedup.evaluate(newRecordKey: 'ev_sms', incoming: bankSms).action,
        DedupAction.insertNew,
      );

      final wechatNotif = engine.parse(const AutoBillRawEvent(
        eventId: 'ev_wx',
        sourceType: AutoBillSourceType.paymentNotification,
        packageName: 'com.tencent.mm',
        title: '微信支付',
        text: '向星巴克付款¥40.00',
        timestampMs: baseMs + 2000,
      ))!;
      final r2 = dedup.evaluate(newRecordKey: 'ev_wx', incoming: wechatNotif);
      expect(r2.action, DedupAction.skipDuplicate);
      expect(r2.matchedKey, 'ev_sms');
      expect(r2.mergedBill.cardLastFour, '8877');
    });

    test('同渠道连续两笔相同金额消费（间隔 10 秒）：不误杀，记为两笔', () {
      final dedup = AutoBillDeduplicator(
        intermediaryMerchants: engine.intermediaryMerchants,
      );
      const baseMs = 1732400000000;

      final buy1 = engine.parse(const AutoBillRawEvent(
        eventId: 'ev_1',
        sourceType: AutoBillSourceType.paymentNotification,
        packageName: 'com.tencent.mm',
        title: '微信支付',
        text: '使用零钱向便利店付款¥3.50',
        timestampMs: baseMs,
      ))!;
      final buy2 = engine.parse(const AutoBillRawEvent(
        eventId: 'ev_2',
        sourceType: AutoBillSourceType.paymentNotification,
        packageName: 'com.tencent.mm',
        title: '微信支付',
        text: '使用零钱向便利店付款¥3.50',
        timestampMs: baseMs + 10000,
      ))!;

      expect(
        dedup.evaluate(newRecordKey: 'ev_1', incoming: buy1).action,
        DedupAction.insertNew,
      );
      expect(
        dedup.evaluate(newRecordKey: 'ev_2', incoming: buy2).action,
        DedupAction.insertNew,
      );
    });

    test('同渠道 1 秒内系统重复推送：正常去重跳过', () {
      final dedup = AutoBillDeduplicator(
        intermediaryMerchants: engine.intermediaryMerchants,
      );
      const baseMs = 1732400000000;

      final push1 = engine.parse(const AutoBillRawEvent(
        eventId: 'ev_1',
        sourceType: AutoBillSourceType.paymentNotification,
        packageName: 'com.tencent.mm',
        title: '微信支付',
        text: '使用零钱向便利店付款¥3.50',
        timestampMs: baseMs,
      ))!;
      final push2 = engine.parse(const AutoBillRawEvent(
        eventId: 'ev_2',
        sourceType: AutoBillSourceType.paymentNotification,
        packageName: 'com.tencent.mm',
        title: '微信支付',
        text: '使用零钱向便利店付款¥3.50',
        timestampMs: baseMs + 1000,
      ))!;

      expect(
        dedup.evaluate(newRecordKey: 'ev_1', incoming: push1).action,
        DedupAction.insertNew,
      );
      expect(
        dedup.evaluate(newRecordKey: 'ev_2', incoming: push2).action,
        DedupAction.skipDuplicate,
      );
    });
  });
}
