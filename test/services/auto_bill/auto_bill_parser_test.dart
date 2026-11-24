import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:beecount/data/db.dart';
import 'package:beecount/services/auto_bill/account_mapping_service.dart';
import 'package:beecount/services/auto_bill/auto_bill_models.dart';
import 'package:beecount/services/auto_bill/auto_bill_rule_engine.dart';

Account _acc({
  required int id,
  required String name,
  required String type,
  String? bankName,
  String? cardLastFour,
}) =>
    Account(
      id: id,
      ledgerId: 0,
      name: name,
      type: type,
      currency: 'CNY',
      initialBalance: 0,
      sortOrder: 0,
      hidden: false,
      bankName: bankName,
      cardLastFour: cardLastFour,
    );

void main() {
  late AutoBillRuleEngine engine;

  setUpAll(() {
    final jsonStr = File('assets/auto_bill_rules.json').readAsStringSync();
    engine = AutoBillRuleEngine.fromJsonString(jsonStr);
  });

  group('AutoBillRuleEngine - 单一规则库 JSON 解析', () {
    test('微信支付通知（零钱通）', () {
      const event = AutoBillRawEvent(
        eventId: 'e1',
        sourceType: AutoBillSourceType.paymentNotification,
        packageName: 'com.tencent.mm',
        title: '微信支付',
        text: '微信支付凭证：你已使用零钱通向瑞幸咖啡付款¥28.50',
        timestampMs: 1732400000000,
      );
      final parsed = engine.parse(event);
      expect(parsed, isNotNull);
      expect(parsed!.amount, 28.50);
      expect(parsed.type, 'expense');
      expect(parsed.merchant, '瑞幸咖啡');
      expect(parsed.accountHint, '零钱通');
    });

    test('微信普通好友聊天消息被标题白名单彻底拦截（防误记）', () {
      const chat = AutoBillRawEvent(
        eventId: 'chat1',
        sourceType: AutoBillSourceType.paymentNotification,
        packageName: 'com.tencent.mm',
        title: '张三',
        text: '刚向瑞幸咖啡付款¥28.50，你转我一份吧',
        timestampMs: 1732400000000,
      );
      expect(engine.parse(chat), isNull);
    });

    test('支付宝通知（余额宝）', () {
      const event = AutoBillRawEvent(
        eventId: 'e2',
        sourceType: AutoBillSourceType.paymentNotification,
        packageName: 'com.eg.android.AlipayGphone',
        title: '支付宝通知',
        text: '你已成功向麦当劳付款 36.80元，付款方式：余额宝',
        timestampMs: 1732400000000,
      );
      final parsed = engine.parse(event);
      expect(parsed, isNotNull);
      expect(parsed!.amount, 36.80);
      expect(parsed.type, 'expense');
      expect(parsed.merchant, '麦当劳');
      expect(parsed.accountHint, '余额宝');
    });

    test('银行动账短信（剥离余额数字，提取银行名与卡号尾号）', () {
      const event = AutoBillRawEvent(
        eventId: 'e3',
        sourceType: AutoBillSourceType.bankSms,
        packageName: 'com.hihonor.mms',
        title: '95555',
        text: '【招商银行】您尾号8877的储蓄卡11月24日在美团外卖消费人民币42.30元，当前余额12345.67元。',
        timestampMs: 1732400000000,
      );
      final parsed = engine.parse(event);
      expect(parsed, isNotNull);
      expect(parsed!.amount, 42.30);
      expect(parsed.type, 'expense');
      expect(parsed.merchant, '美团外卖');
      expect(parsed.bankName, '招商银行');
      expect(parsed.cardLastFour, '8877');
      expect(parsed.accountHint, '招商银行储蓄卡(8877)');
      expect(parsed.precisionScore, greaterThanOrEqualTo(130));
    });

    test('微信收款通知识别为收入', () {
      const event = AutoBillRawEvent(
        eventId: 'e4',
        sourceType: AutoBillSourceType.paymentNotification,
        packageName: 'com.tencent.mm',
        title: '微信支付',
        text: '微信支付收款通知：收到张三转账¥200.00，已存入零钱',
        timestampMs: 1732400000000,
      );
      final parsed = engine.parse(event);
      expect(parsed, isNotNull);
      expect(parsed!.amount, 200.00);
      expect(parsed.type, 'income');
      expect(parsed.accountHint, '零钱');
    });

    test('零钱通转入识别为内部转账', () {
      const event = AutoBillRawEvent(
        eventId: 'e5',
        sourceType: AutoBillSourceType.paymentNotification,
        packageName: 'com.tencent.mm',
        title: '微信支付',
        text: '零钱通转入成功，金额¥1,000.00',
        timestampMs: 1732400000000,
      );
      final parsed = engine.parse(event);
      expect(parsed, isNotNull);
      expect(parsed!.amount, 1000.00);
      expect(parsed.type, 'transfer');
    });

    test('过滤验证码、快递、蚂蚁森林等噪音通知', () {
      const otp = AutoBillRawEvent(
        eventId: 'n1',
        sourceType: AutoBillSourceType.bankSms,
        packageName: 'com.hihonor.mms',
        title: '95555',
        text: '【招商银行】您的支付验证码为 884512，请勿泄露。金额 100.00元',
        timestampMs: 1732400000000,
      );
      expect(engine.parse(otp), isNull);

      const forest = AutoBillRawEvent(
        eventId: 'n2',
        sourceType: AutoBillSourceType.paymentNotification,
        packageName: 'com.eg.android.AlipayGphone',
        title: '支付宝',
        text: '蚂蚁森林能量已成熟，快来领取 100g',
        timestampMs: 1732400000000,
      );
      expect(engine.parse(forest), isNull);
    });

    test('拦截招行纯外币境外消费推送（无人民币实付金额时不按1:1误记）', () {
      const event = AutoBillRawEvent(
        eventId: 'fx_sgd_only',
        sourceType: AutoBillSourceType.bankNotification,
        packageName: 'cmb.pb',
        title: '招商银行',
        text: '您尾号7409的招行账户境外消费SGD1.38',
        timestampMs: 1732400000000,
      );
      expect(engine.parse(event), isNull);
    });

    test('拦截招行撤销境外消费预授权推送', () {
      const event = AutoBillRawEvent(
        eventId: 'preauth_cancel',
        sourceType: AutoBillSourceType.bankNotification,
        packageName: 'cmb.pb',
        title: '招商银行',
        text: '您尾号7409的账户撤销境外消费预授权人民币7.14',
        timestampMs: 1732400000000,
      );
      expect(engine.parse(event), isNull);
    });

    test('拦截招行甲骨文预授权冻结短信', () {
      const event = AutoBillRawEvent(
        eventId: 'preauth_freeze',
        sourceType: AutoBillSourceType.bankSms,
        packageName: 'com.hihonor.mms',
        title: '招商银行',
        text:
            '【招商银行】您账户7409于11月25日00:25在ORACLE  SINGAPORE      SINGAPORE     SGP预授权冻结SGD1.38（人民币7.14），请留意后续扣款通知。',
        timestampMs: 1732400000000,
      );
      expect(engine.parse(event), isNull);
    });

    test('拦截万事达卡余额不足支付失败通知', () {
      const event = AutoBillRawEvent(
        eventId: 'fail_insufficient',
        sourceType: AutoBillSourceType.bankNotification,
        packageName: 'cmb.pb',
        title: '万事达卡支付失败通知',
        text: '您的万事达卡因卡内可用余额不足交易失败，金额 ¥6.67',
        timestampMs: 1732400000000,
      );
      expect(engine.parse(event), isNull);
    });

    test('境外真实人民币结算短信：忽略外币USD与卡余额，精确提取人民币金额', () {
      const event = AutoBillRawEvent(
        eventId: 'fx_with_rmb',
        sourceType: AutoBillSourceType.bankSms,
        packageName: 'com.hihonor.mms',
        title: '95555',
        text: '【招商银行】您尾号7409的储蓄卡在Apple消费USD9.99（人民币72.45元），当前余额927.57元。',
        timestampMs: 1732400000000,
      );
      final parsed = engine.parse(event);
      expect(parsed, isNotNull);
      expect(parsed!.amount, 72.45);
      expect(parsed.type, 'expense');
      expect(parsed.cardLastFour, '7409');
      expect(parsed.bankName, '招商银行');
    });
  });

  group('AccountMappingService - 账户映射优先级', () {
    final accounts = [
      _acc(id: 1, name: '微信零钱', type: 'wechat'),
      _acc(id: 2, name: '微信零钱通', type: 'wechat'),
      _acc(id: 3, name: '支付宝余额宝', type: 'alipay'),
      _acc(
        id: 4,
        name: '招行工资卡',
        type: 'bank_card',
        bankName: '招商银行',
        cardLastFour: '8877',
      ),
    ];

    test('优先命中用户自定义关键词规则', () {
      final bill = engine.parse(const AutoBillRawEvent(
        eventId: 'm1',
        sourceType: AutoBillSourceType.paymentNotification,
        packageName: 'com.tencent.mm',
        title: '微信支付',
        text: '使用零钱通向瑞幸咖啡付款¥19.90',
        timestampMs: 1732400000000,
      ))!;

      final matched = AccountMappingService.resolveAccount(
        bill: bill,
        accounts: accounts,
        customRules: const [
          AccountMappingRule(
            id: 'r1',
            keyword: '零钱通',
            accountId: 2,
            accountName: '微信零钱通',
            priority: 1,
          ),
        ],
      );
      expect(matched?.id, 2);
    });

    test('无自定义规则时按银行卡尾号自动匹配', () {
      final bill = engine.parse(const AutoBillRawEvent(
        eventId: 'm2',
        sourceType: AutoBillSourceType.bankSms,
        packageName: 'com.hihonor.mms',
        title: '95555',
        text: '【招商银行】尾号8877储蓄卡消费¥58.00',
        timestampMs: 1732400000000,
      ))!;

      final matched = AccountMappingService.resolveAccount(
        bill: bill,
        accounts: accounts,
        customRules: const [],
      );
      expect(matched?.id, 4);
    });
  });
}
