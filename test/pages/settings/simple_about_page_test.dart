import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:beecount/pages/settings/simple_about_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: '素帐',
      packageName: 'com.plainledger.app',
      version: '1.1.3',
      buildNumber: '6',
      buildSignature: '',
    );
  });

  testWidgets('关于页展示版本与 GitHub 仓库入口', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SimpleAboutPage()));
    await tester.pumpAndSettle();

    expect(find.text('版本 1.1.3+6'), findsOneWidget);
    expect(find.text('GitHub 仓库'), findsOneWidget);
    expect(
      find.text('github.com/428581985-cyber/PlainLedger'),
      findsOneWidget,
    );

    await tester.scrollUntilVisible(find.text('GitHub Releases'), 200);
    expect(find.text('GitHub Releases'), findsOneWidget);
  });
}
