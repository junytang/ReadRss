# ReadYou HarmonyOS 7 移植版（MVP）

本目录是使用 **ArkTS + ArkUI** 对 ReadYou Android 版进行原生重写的鸿蒙 7（API 26）工程。
Android 原工程保持原样，鸿蒙工程作为独立 DevEco 项目放在 `harmony/` 下，可单独用 DevEco Studio 打开。

## 环境要求

- DevEco Studio **6.0.0+**
- HarmonyOS SDK **API 26**（工程已按 API 26+ 的新版本格式配置：
  `compileSdkVersion / compatibleSdkVersion / targetSdkVersion = "26.0.0"`，
  `arkTSVersion = "1.1"`，`modelVersion = "7.0.0"`；注意 API 26 起不再接受 `"7.0.0(26)"` 这种旧格式）
- 真机或模拟器：HarmonyOS 7 设备 / API 26 模拟器
- 调试签名：首次打开工程后，在 DevEco 中登录华为账号并自动生成调试签名
  （`File > Project Structure > Signing Configs`）

> 本机当前没有安装 DevEco Studio / HarmonyOS SDK，因此该工程**未在真机上编译验证过**。
> 请在你的 DevEco 环境中首次构建后，根据编译报错做少量 API 微调。

## 打开与运行

1. 用 DevEco Studio 打开本目录（`ReadYou-harmonyos7/harmony`）。
2. 等待依赖同步完成（无第三方 ohpm 依赖，仅使用系统 Kit）。
3. 配置调试签名并连接设备。
4. 选择 `entry` 模块 → `default` target → 运行。

## 已实现的核心功能（MVP）

| 功能 | 说明 | Android 对应实现 |
|---|---|---|
| 多账号 | 本地 / Fever / Google Reader / FreshRSS，切换、增删改、凭据加密 | `AccountService`、`AccountType`、安全密钥类 |
| 订阅管理 | 添加 / 删除 RSS 地址，推荐源，未读数统计 | `SubscribeViewModel`、`FeedsPage`、`FeedDao` |
| 内容抓取 | `@ohos.net.http` 拉取 RSS/Atom | `RssHelper`、`OkHttpClientModule` |
| Feed 解析 | 自研轻量 XML 解析器 + RSS 2.0 / Atom 解析 | ROME + Jsoup + readability4j |
| 文章列表 | 按源查看、未读筛选、同步、标记已读 | `FlowPage`、`ArticleList`、`Paging` |
| 阅读页 | WebView 渲染全文、收藏、打开原文 | `ReadingPage`、`RYWebView`、`Content` |
| 设置 | 深色模式、启动时同步、打开即已读、字号 | `SettingsPage` + 72 个 DataStore Preference |
| Fever 同步 | 分组/订阅/图标拉取、分页文章、未读与收藏状态对账、标记读写 | `FeverRssService`、`FeverAPI` |
| Google Reader / FreshRSS 同步 | ClientLogin + Token、订阅与标签、ID 流对账、批量正文抓取、标记读写 | `GoogleReaderRssService`、`GoogleReaderAPI` |
| 凭据加密 | DES/ECB/PKCS7（与 Android `DESUtils` 同密钥，可直接迁移账号配置） | `DESUtils`、`SecurityKey` |
| 本地存储 | `@ohos.data.relationalStore`（RDB，含 account / feed_group 表） | Room `Reader` 数据库 v7 |
| 偏好设置 | `@ohos.data.preferences` | Jetpack DataStore Preferences |

## 工程结构

```
harmony/
├── AppScope/                       # 应用级配置（bundleName、图标、名称）
├── entry/
│   └── src/main/
│       ├── module.json5            # ability、权限（INTERNET）
│       ├── resources/              # 字符串、颜色、图标
│       └── ets/
│           ├── entryability/       # EntryAbility（初始化 DB / 偏好）
│           ├── common/             # 常量、日志、路由
│           ├── account/            # AccountModels（含 DES 编解码）、AccountRepository
│           ├── model/              # Feed / Article / Settings 数据模型
│           ├── data/               # Database（RDB，多账号）、SettingsStore（Preferences）
│           ├── rss/                # XmlParser、RssParser、RssRepository、HtmlBuilder、
│           │                       # SyncServiceFactory、Local/Fever/GoogleReader 服务与 API
│           ├── components/         # FeedListView、ArticleListView、ReadingView、
│           │                       # SubscribeView、SettingsView、AccountsView、
│           │                       # AccountEditorView
│           └── pages/Index.ets     # 根 Navigation + 路由表
├── build-profile.json5
├── oh-package.json5
└── hvigorfile.ts
```

## 与 Android 版架构对照

| Android | HarmonyOS |
|---|---|
| `@HiltAndroidApp` + Hilt 依赖注入 | 模块级单例（`database` / `settingsStore` / `rssRepository` / `accountRepository`） |
| `RssService.get(type)` 服务选择 | `SyncServiceFactory.syncServiceFor(account)` |
| `RssService` 三大实现 | `LocalSyncService` / `FeverSyncService` / `GoogleReaderSyncService` |
| `FeverAPI` / `GoogleReaderAPI` | `FeverApi` / `GoogleReaderApi`（`@ohos.net.http`） |
| `AccountType` + 安全密钥 + DESUtils | `AccountType` 枚举 + `CredentialCodec`（DES64\|ECB\|PKCS7 + MD5） |
| `MainActivity`（单 Activity） | `EntryAbility`（Stage 模型） |
| Compose `NavDisplay` + Navigation 3 | ArkUI `Navigation` + `NavPathStack` |
| `FeedsViewModel` / `ArticleListReaderViewModel` | 页面内 `@State` + Repository（MVP 简化） |
| Room + DAO + Paging 3 | RDB + 显式 SQL（无 Paging，列表上限 500 条） |
| DataStore Preferences（72 个类） | `@ohos.data.preferences`（5 个设置项） |
| WebView + JS 注入 / CSS | `@ohos.web.webview` + `loadData` + 内联 CSS |
| WorkManager 定期同步 | 启动时同步 + 下拉刷新（无后台任务） |

## 未实现 / 已知限制

MVP 有意裁剪了以下内容，完整移植需要分阶段补齐：

- Feedly / Inoreader 账号类型（与 Android 一致，暂回退到本地服务）
- **有意的性能优化（偏离 Android）**：Google Reader 同步时，已读 ID 只取前 3 页（上限 3000）且只用于本地状态对账，不抓取正文；正文只抓取未读与星标文章。Android 会抓取所有已读 ID 的正文，首次同步可能产生上万次请求，对客户端和服务端压力都很大。
- 客户端证书认证（Android 使用 KeyChain 选取证书；本移植仅保存别名字符串）
- 后台定时同步、DiffMapHolder 离线已读状态批处理、同步日志
- 全文抓取（readability4j）、离线缓存、图片下载、OPML 导入导出
- 后台定时同步（`SyncWorker` / `ReaderWorker`）、通知、桌面小组件（Glance）
- 朗读 TTS、应用内更新、崩溃上报、分享 / 深链、53 种语言本地化
- Material You 动态取色（25 个颜色科学文件）、Navigation 3 转场动画、自适应双栏布局
- 原生 Compose 阅读渲染器（仅实现 WebView 渲染器）
- WebView 中的图片点击 / 保存回调、JS Bridge

## 下一步建议

1. 首次在 DevEco 中编译，修正系统图标 / API 签名差异（已尽量只用稳定的 Kit API）。
2. 增加后台同步（`@ohos.resourceschedule.backgroundTaskManager`）。
3. 逐步移植 Fever / GReader 同步与多账号模型。
4. 补齐 OPML 导入导出、通知与小组件。

## 许可

与 Android 原项目一致：GPL-3.0。

## 备注
- 后台定时同步、通知、桌面小组件、TTS、应用内更新、崩溃上报
- 阅读器样式设置、图片查看器、上/下篇
- DiffMapHolder 延迟提交、按 1/3/7 天标记已读
- 分组管理（新建/重命名/移动/删除分组）、订阅配置弹窗、OPML 导入导出
- 搜索、InitialFilter 持久化设置
- Feedly/Inoreader 实际协议、客户端证书认证、53 种语言本地化
- 深链 / ACTION_VIEW 处理、返回键特殊行为