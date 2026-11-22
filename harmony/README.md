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

## 与 Android 版的功能差距（按优先级）

> 依据两端当前代码逐项比对得出（盘点结论见仓库根目录 `AGENTS.md`）。
> **P0** = 影响基本可用的核心能力，或代码已存在但不生效/不可达的半成品；
> **P1** = 与 Android 行为不一致的重要交互与设置；
> **P2** = 体验增强与样式设置；
> **P3** = 平台外围能力（需平台适配或成本较高）。

### P0 — 必须先补齐

**订阅与分组管理**
- [ ] 放开「添加订阅」入口并补全配置流程（URL 搜索、重命名、选分组、每源开关「通知/全文/浏览器打开」、新建分组）。`SubscribeView` 已实现，但 `FeedListView` 中入口整段被注释。
- [ ] 源配置抽屉：点击 favicon 重抓图标、重命名、改 URL、移至分组、新建分组、清空该源文章、取消订阅、每源开关。
- [ ] 分组配置抽屉：重命名、批量设置通知/全文/浏览器、整组移动、清空组内文章、删除组（GReader 后端方法已有，无任何 UI 调用）。
- [ ] OPML 导入 / 导出（导出可选是否包含各源附加配置）。
- [ ] 落实服务能力矩阵：Local 全功能 / GReader 可管理但不可导 OPML / Fever 只读（当前 Fever 取消订阅直接抛异常）。

**阅读与设置正确性**
- [x] 上 / 下篇导航：正文顶部下拉看上一篇、底部上拉看下一篇，带跟手回弹与提示；仅在页面滚到顶/底时触发，不影响正常滚动；就地切换文章，返回键回到列表；翻页范围跟随当前列表的筛选/分组/源/搜索条件。
- [x] `syncOnLaunch` 生效：`EntryAbility` 启动时读取该设置（当前只在首装时同步一次）。（已实现：`isFirstRun() || settingsStore.get().syncOnLaunch`。）
- [x] `markReadOnOpen` 生效：阅读页按该设置决定是否标已读（当前无条件标已读）。（已实现：`load()` 中按设置值决定是否乐观标已读。）

**同步**
- [ ] 后台定时同步：WorkManager 等价能力（`@ohos.resourceschedule.backgroundTaskManager`）+ 按账号同步间隔 + 仅 WiFi / 仅充电约束 + 指数退避。
- [ ] 通知：声明并申请通知权限、建立通知渠道、点击直达文章；补齐 Local 同步通知（当前仅 Fever/GReader 发通知且未申请权限）。
- [ ] 通知去重状态持久化（当前「每源一条」依赖内存 Map，进程重启后丢失）。

### P1 — 重要行为对齐

**导航与入口**
- [ ] 返回键特殊行为：根列表页返回退到后台；搜索/批量/抽屉展开时返回先收起面板。
- [ ] 深链 / 外部入口：`ACTION_VIEW`、`ACTION_SEND`（分享订阅 URL）、`article.id`/`feed.id`/`group.id` extras、通知点击跳转。
- [ ] 「起始页」（Feeds / Flow）与「默认筛选」（星标/未读/全部）设置。
- [ ] 独立单源列表路由 `FlowPage` 接线（`openFlow` 当前无任何调用方）。

**文章列表**
- [ ] 未读排序切换 Latest / Earliest（DB 已支持 ASC，缺 UI 开关）。
- [ ] 左右滑动作可配（None / 标已读 / 标星标，左右分别设置）；当前仅有固定左滑标已读。
- [ ] 长按菜单补「分享」项（当前只有 4 项）。
- [ ] 批量标记按时间分档：1 天 / 3 天 / 7 天 / 全部（当前只有「全部标已读」）。
- [ ] 列表显示项开关：源图标、源名、缩略图、摘要长度（无/短/长）、已读灰显策略。

**阅读页**
- [ ] 全文 / 摘要即时切换按钮（当前 `showFullContent` 已移除，始终抓全文）。
- [ ] 底部操作栏：标已读/未读、星标、下一篇、TTS、全文切换。
- [ ] 打开链接方式 6 选 1（CustomTabs / 默认浏览器 / 指定包 / 总是询问等）+ 指定浏览器。
- [ ] 分享内容设置（仅链接 / 标题+链接）。
- [ ] 顶栏点击回顶、阅读样式快捷入口。

**账号与同步**
- [ ] 账号详情页：连接信息四项可改（服务器/用户名/密码/证书）、清空文章、删除。
- [ ] 客户端证书使用系统 KeyChain 选择（当前仅保存别名字符串，未真正用于 TLS）。
- [ ] 账号级同步策略设置：同步间隔、仅 WiFi、仅充电、同步屏蔽列表（字段已持久化但无 UI、无逻辑读取）。
- [ ] `ReaderWorker`（并发全文抓取）与 `WidgetUpdateWorker`（同步后刷新小组件）。
- [ ] 同步日志 + 故障排查页：Worker 状态、错误日志查看/复制/清空。
- [ ] DiffMapHolder 等价的离线已读状态批处理（当前为 `ReadStatusBatcher`，能力不完全等价）。

### P2 — 体验增强与样式

**导航与动效**
- [ ] Navigation 3 风格转场、共享元素过渡、预测式返回动画。
- [ ] 自适应双栏（列表 + 详情）+ 分栏拖拽手柄 + 三态导航按钮（关闭/隐藏列表/展开列表）。

**文章列表**
- [ ] 底部下拉换源（不操作 / 加载下一源 / 标已读并加载下一源）。
- [ ] 粘性日期头、Today/Yesterday 日期文案、显示时间开关。
- [ ] 筛选栏样式（图标 / 图标+文字 / 仅选中带文字）、padding、色调层级。

**阅读页**
- [ ] TTS 朗读：按行分段播报、进度环、长按进入系统 TTS 设置。
- [ ] 图片全屏查看器：4x 缩放、点击关闭、长按保存、403 图片 Referer 重试。
- [ ] 阅读主题预设（MaterialYou / Reeder / Paper / Custom）。
- [ ] 自动隐藏工具栏（滚动时收起顶/底栏）。
- [ ] 排版设置：字间距、文字对齐、正文/标题/子标题粗体与大写、图片内边距/圆角/最大化、阅读页色调层级。

**订阅页 / 设置**
- [ ] 隐藏空分组、分组总是展开、全部展开/收起按钮。
- [ ] BestIconFinder 站点 favicon 探测（当前只用服务端返回的图标 URL）。
- [ ] 设置项补齐：阅读器样式、文章列表样式、订阅页样式、交互、深色三态（跟随系统/开/关）、AMOLED 黑、基础字体方案、外部字体导入。

### P3 — 平台外围能力

- [ ] 桌面小组件：列表视图 + 卡片视图（Article of the Day），主题 SansSerif/Serif，数据源 Account/Group/Feed，配置页与点击跳文章。
- [ ] 应用内更新检查（GitHub releases、设置页 banner、跳过此版本）。
- [ ] 崩溃上报（未异常捕获 + 报告页 + 复制 Markdown 报告）。
- [ ] Tips & Support 页、Sponsor、GitHub/Telegram/Help 链接、开源许可列表。
- [ ] 40+ 种语言本地化（Android 有 51 个翻译资源目录；当前鸿蒙版全中文硬编码）。
- [ ] Material You 动态取色（壁纸/基础色板 + 自定义主色 HEX）。
- [ ] 原生 Compose 阅读渲染器 + 渲染器切换（平台差异，需基于 ArkUI 重新设计）。
- [ ] 启动欢迎页 / 服务条款同意流程。
- [ ] 粗体字符（Jiffy Reader 风格）、RTL/Bidi、触觉反馈、筛选切换点击音效、自绘滚动指示条。

### 有意裁剪（不建议直接照搬）

- Feedly / Inoreader 实际协议（Android 同样禁用入口，回退到本地服务）。
- **性能优化（偏离 Android）**：GReader 同步时已读 ID 只取前 3 页（上限 3000）且只用于本地状态对账，不抓正文；正文只抓未读与星标。Android 会抓取全部已读 ID 正文，首次同步可能产生上万次请求。
- WebView 中的图片点击 / 保存回调与 JS Bridge（平台 WebView 能力差异，已用代理与系统分享替代部分能力）。

## 下一步建议

1. 按 P0 清单补齐订阅管理、上/下篇、设置生效与后台同步/通知。
2. 按 P1 清单对齐 Android 的关键交互与设置行为。
3. 视真机反馈逐步推进 P2 / P3；平台相关项（小组件、Material You、原生渲染器）需单独设计。

## 许可

与 Android 原项目一致：GPL-3.0。