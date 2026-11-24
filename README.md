# PlainLedger 素帐

[中文](#中文) · [English](#english)

**PlainLedger（素帐）** 是一个纯粹、轻量、离线本地优先的个人 Android 记账工具，基于 [蜜蜂记账 BeeCount](https://github.com/TNT-Likely/BeeCount) 二次裁剪改造，移除云同步与全部 AI 模块，专注多账户记账、纯本地规则分类与账单导入导出。

A pure, lightweight, local-first personal finance app for Android, derived from [BeeCount](https://github.com/TNT-Likely/BeeCount) with cloud sync and AI modules removed, focused on multi-account bookkeeping, local rule-based categorization, and CSV/Excel bill import/export.

- GitHub：<https://github.com/428581985-cyber/PlainLedger>
- 包名（`applicationId`）：`com.plainledger.app`（Android 11+ / API 30）

---

## 中文

### 核心能力

| 模块 | 能力 |
|------|------|
| 记账 | 收入 / 支出 / 转账；金额、分类、多子账户、日期、备注、图片附件、多标签 |
| 账户 | 微信（零钱/零钱通）、支付宝（余额/余额宝/花呗）、银行卡/信用卡及资产构成 |
| 统计 | 本周 / 本月 / 自定义区间；本期收支、环比、同比；支出 Top5 饼图、近 6 个月柱状图、分类排行 |
| 导入导出 | 微信 / 支付宝内置解析与通用 CSV/Excel 自定义列映射导入；本地规则引擎自动归类；CSV 导出 |
| 备份与安全 | 完整备份（数据库 + 图片）或仅数据库备份；可选 PBKDF2 + AES-256-GCM 加密；应用锁（PIN + 生物识别） |
| 界面 | 4 个主 Tab（首页 · 统计 · 账户 · 设置）+ 中央快速记账；浅色 / 深色 / 跟随系统；字体缩放 |

### 技术架构

- Flutter `3.47.9` / Dart `3.13.7`
- Riverpod 状态管理
- Drift + SQLite 本地持久化（schema v34）
- `fl_chart` 图表
- PBKDF2-HMAC-SHA256 + AES-256-GCM 备份加密

### 目录结构

```text
PlainLedger/
├── android/              # Android 工程
├── assets/               # 图标与分类资源
├── docs/                 # 蓝皮书与改造说明
├── lib/
│   ├── data/             # Drift 数据库与 Repository
│   ├── l10n/             # 多语言本地化
│   ├── models/           # 领域模型
│   ├── pages/            # 首页、统计、账户、设置、记账编辑器、导入导出
│   ├── providers/        # Riverpod providers
│   ├── services/         # 备份、账单导入解析、分类规则、附件与安全服务
│   ├── styles/           # Design Token
│   ├── app.dart / main.dart
├── test/                 # 单元 / 组件测试
└── pubspec.yaml
```

> 内部 Dart 包名与 Android `namespace` 仍保留 `beecount` / `com.tntlikely.beecount` 兼容命名；对外品牌与 `applicationId` 为 **PlainLedger（素帐）** / `com.plainledger.app`。

### 本地开发与测试

```bash
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings lib
flutter test --no-pub
flutter build apk --debug --flavor dev --no-pub
```

### 许可证与上游

基于 [蜜蜂记账 BeeCount](https://github.com/TNT-Likely/BeeCount) 二次开发。上游采用 BeeCount 软件许可协议：个人与非营利使用免费，商业使用需获得上游作者书面授权。本项目沿用相同的非商业限制，为源码公开（source-available）项目，并非 OSI 定义的开源软件。请保留 [`LICENSE`](LICENSE)、[`LICENSE_EN`](LICENSE_EN)、[`COMMERCIAL_LICENSE.md`](COMMERCIAL_LICENSE.md) 与 [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)。

---

## English

### Overview

- Repository: <https://github.com/428581985-cyber/PlainLedger>
- Android `applicationId`: `com.plainledger.app` (Android 11+ / API 30)
- Built with Flutter `3.47.9`, Riverpod, Drift/SQLite (`schemaVersion` 34), and `fl_chart`.
- Local-only storage with no account system, no cloud sync, and no AI runtime dependencies.

### License

Based on [BeeCount](https://github.com/TNT-Likely/BeeCount). The upstream BeeCount Software License permits free personal and non-profit use; commercial use requires separate written authorization. This derivative keeps the same non-commercial restriction and is source-available, not OSI open source.
