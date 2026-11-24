# PlainLedger（素帐）改造交接文档

> 生成时间：2026-11-24  
> 目标项目：`C:\Users\Gordo\PlainLedger`（`com.plainledger.app`，当前版本 `1.1.5+8`）  
> GitHub 仓库：`https://github.com/428581985-cyber/PlainLedger.git`  
> 目标真机：荣耀 Magic 8（MagicOS）

---

## 1. 当前工作区与工程现状

1. **源码位置与包名**
   - 工程根目录：`C:\Users\Gordo\PlainLedger`（原工作区 `C:\Users\Gordo\BEEEEEE\BeeCount` 已删除，仅保留此改造版）。
   - `android/app/build.gradle` 中 `applicationId` 为 `com.plainledger.app`，Kotlin 源码 `namespace` 仍为 `com.tntlikely.beecount`。
   - **Git 与工具链环境**：已完成 Git 初始化、P1 瘦身及 GitHub 远端关联；本工程实际使用 `dev.bat` 指定的 Flutter `3.47.9`（`C:\Users\Gordo\AppData\Local\flutter-3.47.9\bin\flutter.bat`），而非系统 `PATH` 中的 Flutter `3.27.3`（构建 Debug APK 需带 `--flavor dev`）。
2. **已有核心能力**
   - 多账户体系（微信零钱/零钱通、支付宝余额/余额宝、多张银行卡）已具备基础实现。
   - 已去掉原版 BeeCount 的多云盘同步（Supabase/WebDAV/S3/iCloud）和共享账本。
   - `lib/services/category_rules/category_rule_engine.dart` 与 `lib/pages/settings/category_rules_page.dart` 已存在本地分类规则引擎。
   - `lib/services/import/` 下已有 `wechat_parser.dart`、`alipay_parser.dart`、`generic_parser.dart`、`payment_method_mapper.dart`。
3. **待解决的硬件联调前置项**
   - 荣耀 Magic 8（`AS6VVB6323004666`，`VID_339B`）在 Windows 下通过通用 WinUSB 暴露 ADB 接口，`adb` 37.x 必须设置 `ADB_LIBUSB=1` 才能识别（已写入 `dev.bat`）；连接后需在手机端点击 USB 调试授权弹窗。

---

## 2. 已确认的最终需求共识

### 2.1 去臃肿（纯粹化）
- **彻底移除所有 AI 模块**：
  - 移除本地 GGUF 大模型推理（`pubspec.yaml` 中的 `llama_flutter_android`、`lib/ai/simple/local_ai_engine.dart`、`model_downloader.dart`、`model_validation.dart`、`gpu_support.dart`）。
  - 移除云端 AI、AI 聊天页与 AI 设置页（`lib/ai/simple/`、`lib/pages/ai/`、`lib/services/image/billing_image_service.dart` 及相关 provider/入口）。
  - 自动记账与分类识别**全部采用纯本地规则/正则/关键词引擎**，追求轻量、离线、零延迟。
- **精简外壳与冗余组件**：
  - 移除海报分享（`lib/services/export/share_poster_*`）、产品推广卡片（`lib/widgets/biz/product_promo_card.dart`）、多余头部皮肤（`assets/header_skins/`）及冗余桌面小组件（`lib/pages/settings/widget_management_page.dart`、`android/.../BeeCount*WidgetProvider.kt` 与对应布局/XML）。

### 2.2 无感记账（核心新增功能）
- **双引擎监听**（替换现有的手动截图监听 `android/app/src/main/kotlin/com/tntlikely/beecount/ScreenshotObserver.kt`）：
  1. `NotificationListenerService`：监听微信、支付宝、云闪付、银行 App 推送及消费短信通知。
  2. `AccessibilityService`：监听前台消费/支付成功页面节点文本，覆盖不发通知的纯屏幕支付完成页。
- **荣耀 Magic 8「灵动胶囊」风格交互**：
  - 检测到消费后，在屏幕顶部打孔区弹出紧凑的胶囊悬浮窗（展示金额、商户/分类、扣款账户）。
  - **默认自动保存入账**（不点击即存好）；**点击胶囊可进入快速修改**（调整账户、分类、金额等）。
- **最准确去重与多账户精准映射**：
  - 采用**时间窗口 + 金额智能去重**：一笔消费若在短时间内（如 60 秒）同时触发「屏幕页面 + 微信/支付宝通知 + 银行卡通知/短信」，自动合并为同一笔记录，并**优先保留包含具体银行卡尾号或子账户的精确来源**。
  - 支持用户自定义「关键词 → 子账户」映射规则（例如：`零钱通` → 微信零钱通，`余额宝` → 支付宝余额宝，`尾号XXXX` → 对应银行卡）。

### 2.3 多平台账单导入
- 保留现有的 **微信 + 支付宝内置解析器 + 可自定义列映射的通用 CSV/Excel 导入**（无需硬编码内置更多小众平台）。
- 重点增强：
  - 支付方式到多子账户（零钱/零钱通/余额/余额宝/银行卡）的精准映射。
  - 内部转账识别（零钱通转入/提现、余额宝转入、信用卡还款等不重复计入支出）。
  - 导入账单与无感记账记录之间的去重。

---

## 3. 三阶段推出计划（Roadmap）

### Phase 1（P1）：工程基线与「去臃肿瘦身」
- [x] 在项目根目录初始化 Git 仓库并完成基线提交。
- [x] 移除 `llama_flutter_android`、全部 `lib/ai/` 与 `lib/pages/ai/` 模块及相关依赖/入口，验证无残留引用。
- [x] 清理海报分享、推广卡片、多余头部皮肤、全部桌面小组件及对应 Android 原生 Provider/资源。
- [x] 运行 `flutter analyze`、`flutter test` 与 `flutter build apk --debug --flavor dev` 确认精简版可正常构建通过。

### Phase 2（P2）：Android 双引擎无感记账 + 灵动胶囊 + 真机联调
- [x] 在 Android 原生层（Kotlin）实现：
  - `NotificationListenerService`（微信/支付宝/银行推送与短信捕获、标题白名单、跳过折叠摘要、展开 `EXTRA_TEXT_LINES` 与真实绑定状态检测）
  - `AccessibilityService`（前台支付完成页节点解析，带节流与内容哈希防抖）
  - 顶部胶囊悬浮窗（`SYSTEM_ALERT_WINDOW`，读取 `DisplayCutout` 适配荣耀 Magic 8 顶部挖孔位置，支持不点自动保存 + 原地升级更新 + 点击跳转编辑）
  - 权限引导与 MagicOS 后台保活提示页
- [x] 在 Dart 层与单一规则库（`assets/auto_bill_rules.json`）实现：
  - 单一规则源消费文本解析引擎（仅覆盖微信、支付宝、银行推送与动账短信；Kotlin/Dart 共享同一份 JSON）
  - 跨渠道 60 秒窗口合并（银行卡尾号 > 子账户 > 泛渠道，保留真实商户名不被清算中介名覆盖）+ 同渠道 3 秒防抖防误杀
  - 自定义「关键词 → 账户」映射规则配置 UI、持久化与原生胶囊同步
- [ ] 连接荣耀 Magic 8 真机（通过 `adb` 安装），实测微信、支付宝、银行卡消费场景与去重准确率。

### Phase 3（P3）：账单导入增强与多账户闭环
- [ ] 优化 `lib/services/import/generic_parser.dart` 的自定义列映射与模板复用体验。
- [ ] 增强 `payment_method_mapper.dart` 对子账户的精准映射与内部转账自动识别。
- [ ] 补全账单导入与自动记账历史记录的去重校验。

---

## 4. 新工作区开场指令建议
切换工作区到 `C:\Users\Gordo\PlainLedger` 后，可以直接对新对话说：
> 「请先阅读项目根目录下的 `HANDOFF.md`，然后按 P1 计划开始第一步：初始化 Git 基线，并梳理需要移除的 AI 与臃肿模块清单。」
