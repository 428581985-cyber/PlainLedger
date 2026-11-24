// 设备级集成测试：在真机上验证功能是否正确，替代「截图 + 算坐标 + 视觉判断」。
//
// 跑法（手机插着 USB）：
//   flutter test integration_test/app_smoke_test.dart -d <设备ID>
//
// 重要：整个文件只能启动一次 App。
// runApp 每调一次就重建整棵 widget 树，多调会触发
// `_dependents.isEmpty` 断言红屏，所以所有断言放在同一个 testWidgets 里。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:beecount/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('启动 → 首页分组 → 设置入口', (tester) async {
    app.main();
    await tester.pump();

    // 等首页出现。不用 pumpAndSettle：首页有持续动画，永远 settle 不了。
    var booted = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.textContaining('最近交易').evaluate().isNotEmpty) {
        booted = true;
        break;
      }
    }
    expect(booted, isTrue, reason: '15 秒内首页没出现「最近交易」，启动可能失败');
    // 任何 RenderFlex overflow / 未捕获异常都会在这里变成失败
    expect(tester.takeException(), isNull, reason: '首页渲染时抛了异常（可能是布局溢出）');
    expect(find.textContaining('总资产'), findsWidgets, reason: '首页没有总资产卡片');

    // —— 首页按天分组：应存在 yyyy-MM-dd 形式的组头 ——
    final headerPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    final headers = find
        .byWidgetPredicate((w) =>
            w is Text &&
            w.data != null &&
            headerPattern.hasMatch(w.data!.trim()))
        .evaluate();
    expect(headers.isNotEmpty, isTrue, reason: '首页没找到 yyyy-MM-dd 日期组头');

    // —— 设置页三个新入口 ——
    final settingsTab = find.text('设置');
    expect(settingsTab, findsWidgets, reason: '底部导航没有「设置」');
    await tester.tap(settingsTab.last);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull, reason: '设置页渲染异常');
    expect(find.text('账户管理'), findsWidgets, reason: '缺少「账户管理」入口');
    expect(find.text('批量整理分类'), findsWidgets, reason: '缺少「批量整理分类」入口');
    expect(find.text('分类规则'), findsWidgets, reason: '缺少「分类规则」入口');
  });
}
