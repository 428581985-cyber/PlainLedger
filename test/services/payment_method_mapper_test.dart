import 'package:flutter_test/flutter_test.dart';

import 'package:beecount/data/db.dart';
import 'package:beecount/services/import/payment_method_mapper.dart';

/// 构造一个最小账户，只填测试关心的字段。
///
/// 这些值换成别的不影响断言，只是 Drift 的 data class 需要 id/ledgerId/name。
Account _acc({
  required int id,
  required String name,
  String? bankName,
  String? cardLastFour,
}) =>
    Account(
      id: id,
      ledgerId: 0,
      name: name,
      type: 'bank_card',
      currency: 'CNY',
      initialBalance: 0,
      sortOrder: 0,
      hidden: false,
      bankName: bankName,
      cardLastFour: cardLastFour,
    );

void main() {
  group('没有出资渠道的值不建账户', () {
    for (final raw in ['/', '', '   ', '-', '--', '—', '－', '无']) {
      test('"$raw" 返回 null', () {
        expect(PaymentMethodMapper.resolve(raw), isNull);
      });
    }
  });

  group('微信', () {
    test('零钱通 → 微信 / wechat', () {
      final h = PaymentMethodMapper.resolve('零钱通')!;
      expect(h.name, '微信');
      expect(h.type, 'wechat');
    });

    test('零钱 → 微信 / wechat', () {
      final h = PaymentMethodMapper.resolve('零钱')!;
      expect(h.name, '微信');
      expect(h.type, 'wechat');
    });

    test('微信零钱通 → 微信 / wechat', () {
      final h = PaymentMethodMapper.resolve('微信零钱通')!;
      expect(h.name, '微信');
      expect(h.type, 'wechat');
    });
  });

  group('支付宝', () {
    for (final raw in ['账户余额', '余额宝', '花呗']) {
      test('$raw → 支付宝 / alipay', () {
        final h = PaymentMethodMapper.resolve(raw)!;
        expect(h.name, '支付宝');
        expect(h.type, 'alipay');
      });
    }
  });

  group('银行卡', () {
    test('储蓄卡：拆出开户行与卡号后四位', () {
      final h = PaymentMethodMapper.resolve('招商银行储蓄卡(8877)')!;
      expect(h.name, '招商银行');
      expect(h.type, 'bank_card');
      expect(h.bankName, '招商银行');
      expect(h.cardLastFour, '8877');
    });

    test('信用卡 → credit_card', () {
      final h = PaymentMethodMapper.resolve('建设银行信用卡(1234)')!;
      expect(h.name, '建设银行');
      expect(h.type, 'credit_card');
      expect(h.cardLastFour, '1234');
    });

    test('无「储蓄卡/信用卡」后缀也能拆', () {
      final h = PaymentMethodMapper.resolve('中国工商银行(0000)')!;
      expect(h.name, '中国工商银行');
      expect(h.cardLastFour, '0000');
      expect(h.type, 'bank_card');
    });

    test('全角括号归一', () {
      final h = PaymentMethodMapper.resolve('招商银行储蓄卡（8877）')!;
      expect(h.name, '招商银行');
      expect(h.cardLastFour, '8877');
    });

    test('支付宝复合优惠串：& 之后是优惠项，只取第一段', () {
      final h = PaymentMethodMapper.resolve('建设银行储蓄卡(8877)&支付宝立减&红包')!;
      expect(h.name, '建设银行');
      expect(h.cardLastFour, '8877');
      expect(h.type, 'bank_card');
    });
  });

  group('命中已有账户', () {
    test('按卡号后四位 + 开户行匹配到已有账户', () {
      final existing = [
        _acc(id: 7, name: '招行工资卡', bankName: '招商银行', cardLastFour: '8877'),
        _acc(id: 8, name: '建行卡', bankName: '建设银行', cardLastFour: '1234'),
      ];
      final h = PaymentMethodMapper.resolve(
        '招商银行储蓄卡(8877)',
        bankAccounts: existing,
      )!;
      expect(h.matchedId, 7, reason: '应该命中卡号 8877 的那张卡');
    });

    test('卡号对不上时不命中，走新建', () {
      final existing = [
        _acc(id: 7, name: '招行工资卡', bankName: '招商银行', cardLastFour: '0001'),
      ];
      final h = PaymentMethodMapper.resolve(
        '招商银行储蓄卡(8877)',
        bankAccounts: existing,
      )!;
      expect(h.matchedId, isNull);
    });
  });

  group('保底', () {
    test('无法识别的渠道按原名走 cash，不丢数据', () {
      final h = PaymentMethodMapper.resolve('某个新渠道')!;
      expect(h.name, '某个新渠道');
      expect(h.type, 'cash');
    });
  });
}
