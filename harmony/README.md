# ReadRss HarmonyOS 7 移植版

本仓库是用 **ArkTS + ArkUI** 对 ReadYou Android 版进行原生重写的鸿蒙 7（API 26）工程（Android 原工程保持原样）。
鸿蒙工程位于 [`harmony/`](harmony/) 目录，是一个可单独用 DevEco Studio 打开的独立项目；本首页 README 即该目录下的 `README.md`。

## 环境要求

- DevEco Studio **6.0.0+**
- HarmonyOS SDK **API 26**（工程已按 API 26+ 的新版本格式配置：
  `compileSdkVersion / compatibleSdkVersion / targetSdkVersion = "26.0.0"`，
  `arkTSVersion = "1.1"`，`modelVersion = "7.0.0"`；注意 API 26 起不再接受 `"7.0.0(26)"` 这种旧格式）
- 真机或模拟器：HarmonyOS 7 设备 / API 26 模拟器
- 调试签名：首次打开工程后，在 DevEco 中登录华为账号并自动生成调试签名
  （`File > Project Structure > Signing Configs`）

> 工程已配置 API 26（`compatibleSdkVersion` / `targetSdkVersion = "26.0.0"`，
> `modelVersion = "7.0.0"`，见 `build-profile.json5` / `oh-package.json5` / `hvigor/hvigor-config.json5`），
> 已用 DevEco 自带命令行工具链（`hvigorw assembleHap` / `test`）编译与测试通过。
> 真机运行时行为仍以真机日志为准。

## 打开与运行

1. 用 DevEco Studio 打开本仓库的 `harmony/` 目录（即鸿蒙工程根目录）。
2. 等待依赖同步完成（无第三方 ohpm 依赖，仅使用系统 Kit）。
3. 配置调试签名并连接设备。
4. 选择 `entry` 模块 → `default` target → 运行。

## 已实现的核心功能

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
> **删除线** = 计划不实现  

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
- [x] ~~后台定时同步：WorkManager 等价能力（`@ohos.resourceschedule.backgroundTaskManager`）+ 按账号同步间隔 + 仅 WiFi / 仅充电约束 + 指数退避。~~
- [ ] 通知：声明并申请通知权限、建立通知渠道、点击直达文章；补齐 Local 同步通知（当前仅 Fever/GReader 发通知且未申请权限）。
- [ ] 通知去重状态持久化（当前「每源一条」依赖内存 Map，进程重启后丢失）。

### P1 — 重要行为对齐

**导航与入口**
- [x] ~~返回键特殊行为：根列表页返回退到后台；搜索/批量/抽屉展开时返回先收起面板。~~
- [x] ~~深链 / 外部入口：`ACTION_VIEW`、`ACTION_SEND`（分享订阅 URL）、`article.id`/`feed.id`/`group.id` extras、通知点击跳转。~~
- [ ] 「起始页」（Feeds / Flow）与「默认筛选」（星标/未读/全部）设置。
- [ ] 独立单源列表路由 `FlowPage` 接线（`openFlow` 当前无任何调用方）。

**文章列表**
- [x] 未读排序切换 Latest / Earliest：设置 > 文章列表中的开关；排序方向同时影响长按「标记上/下面文章」的方向。
- [x] 左右滑动作可配（无 / 标已读 / 标星标，左右分别设置），选项以图标呈现；滑动按钮也是图标。默认右滑收藏、左滑标已读（对齐 Android）。
- [x] 长按菜单补「分享」项（系统分享面板）。
- [x] 批量标记按时间分档：1 天 / 3 天 / 7 天 / 全部（顶栏按钮的标准弹出菜单）。
- [x] 列表显示项开关：源图标、源名、缩略图、摘要长度（无/短/2 行/3 行）。首屏预估条目数已按这些开关调整行高估算。已读灰显策略按需求未实现（保留现有固定灰显）。

**阅读页**
- [x] ~~全文 / 摘要即时切换按钮（当前 `showFullContent` 已移除，始终抓全文）。~~
- [x] ~~底部操作栏：标已读/未读、星标、下一篇、TTS、全文切换。~~
- [x] ~~打开链接方式 6 选 1（CustomTabs / 默认浏览器 / 指定包 / 总是询问等）+ 指定浏览器。~~
- [x] ~~分享内容设置（仅链接 / 标题+链接）。~~
- [x] ~~顶栏点击回顶、阅读样式快捷入口。~~

**账号与同步**
- [ ] 账号详情页：连接信息四项可改（服务器/用户名/密码/证书）、清空文章、删除。
- [x] ~~客户端证书使用系统 KeyChain 选择（当前仅保存别名字符串，未真正用于 TLS）。~~
- [x] ~~账号级同步策略设置：同步间隔、仅 WiFi、仅充电、同步屏蔽列表（字段已持久化但无 UI、无逻辑读取）。~~
- [x] ~~`ReaderWorker`（并发全文抓取）与 `WidgetUpdateWorker`（同步后刷新小组件）。~~
- [x] ~~同步日志 + 故障排查页：Worker 状态、错误日志查看/复制/清空。~~
- [x] DiffMapHolder 等价的离线已读状态批处理（当前为 `ReadStatusStore` ）。

### P2 — 体验增强与样式

**导航与动效**
- [ ] Navigation 3 风格转场、共享元素过渡、预测式返回动画。
- [ ] 自适应双栏（列表 + 详情）+ 分栏拖拽手柄 + 三态导航按钮（关闭/隐藏列表/展开列表）。

**文章列表**
- [x] ~~底部下拉换源（不操作 / 加载下一源 / 标已读并加载下一源）。~~
- [ ] 粘性日期头、Today/Yesterday 日期文案、显示时间开关。
- [ ] 筛选栏样式（图标 / 图标+文字 / 仅选中带文字）、padding、色调层级。

**阅读页**
- [x] ~~TTS 朗读：按行分段播报、进度环、长按进入系统 TTS 设置。~~
- [ ] 图片全屏查看器：4x 缩放、点击关闭、长按保存、403 图片 Referer 重试。
- [x] ~~阅读主题预设（MaterialYou / Reeder / Paper / Custom）。~~
- [x] ~~自动隐藏工具栏（滚动时收起顶/底栏）。~~
- [ ] 排版设置：字间距、文字对齐、正文/标题/子标题粗体与大写、图片内边距/圆角/最大化、阅读页色调层级。

**订阅页 / 设置**
- [x] ~~隐藏空分组、分组总是展开、全部展开/收起按钮。~~
- [x] ~~BestIconFinder 站点 favicon 探测（当前只用服务端返回的图标 URL）。~~
- [x] 设置项补齐：阅读器样式、文章列表样式、订阅页样式、交互、深色三态（跟随系统/开/关）、AMOLED 黑、基础字体方案、外部字体导入。

### P3 — 平台外围能力

- [x] ~~桌面小组件：列表视图 + 卡片视图（Article of the Day），主题 SansSerif/Serif，数据源 Account/Group/Feed，配置页与点击跳文章。~~
- [x] ~~应用内更新检查（GitHub releases、设置页 banner、跳过此版本）。~~
- [x] ~~崩溃上报（未异常捕获 + 报告页 + 复制 Markdown 报告）。~~
- [x] ~~Tips & Support 页、Sponsor、GitHub/Telegram/Help 链接、开源许可列表。~~
- [x] ~~40+ 种语言本地化（Android 有 51 个翻译资源目录；当前鸿蒙版全中文硬编码）。~~
- [x] ~~Material You 动态取色（壁纸/基础色板 + 自定义主色 HEX）。~~
- [x] ~~原生 Compose 阅读渲染器 + 渲染器切换（平台差异，需基于 ArkUI 重新设计）。~~
- [x] ~~启动欢迎页 / 服务条款同意流程。~~
- [x] ~~粗体字符（Jiffy Reader 风格）、RTL/Bidi、触觉反馈、筛选切换点击音效、自绘滚动指示条。~~

### 有意裁剪（不建议直接照搬）

- Feedly / Inoreader 实际协议（Android 同样禁用入口，回退到本地服务）。
- **性能优化（偏离 Android）**：GReader 同步时已读 ID 只取前 3 页（上限 3000）且只用于本地状态对账，不抓正文；正文只抓未读与星标。Android 会抓取全部已读 ID 正文，首次同步可能产生上万次请求。
- WebView 中的图片点击 / 保存回调与 JS Bridge（平台 WebView 能力差异，已用代理与系统分享替代部分能力）。

## 关键技术决策（已定，勿随意推翻）

- 当前工程配置（以代码为准）：`build-profile.json5` 中 `compatibleSdkVersion = "6.0.0(20)"`、
  `targetSdkVersion = "6.1.0(23)"`；`oh-package.json5` 中 `modelVersion = "5.1.0"`。
  配置里**没有** `compileSdkVersion` 或 `arkTSVersion` 字段。本机 SDK 为 API 26，按上述配置可正常编译。
- 无第三方 ohpm 依赖，只用系统 Kit。
- 阅读器「更多」菜单用 ArkUI 系统 `bindMenu`：浏览器打开 / 复制链接 / 系统分享。
- AVIF 图片：设备 ArkWeb 不能解码，走公共代理 `https://images.weserv.nl/?url=...&output=jpeg...`，通过虚假 HTTPS URL + WebView `onInterceptRequest` 暴露（见 `common/ArticleImageConverter.ets` / `components/ReadingView.ets`）。
- 分页加载：`onReachEnd` 触发，递增 limit 重查；首批约 20–80 行，延迟补齐至 `FULL_PAGE_SIZE=100`，之后每次 `LOAD_MORE_STEP=100`。
- 分批大小设置值：50 / 100 / 200 / 300 / 500，默认 **100**（`SettingsStore` + `AppSettings.fetchBatchSize`）。
- GReader ID 分页大小固定 **1000**；`fetchBatchSize` 只控制正文抓取/入库批次。
- GReader token 持久化 **30 天**（`rss/GReaderTokenStore.ets`），401 时清除重登。
- 已读 ID 对账**每次 sync 都做**，无时间间隔节流。
- `listArticles` 排序带次级键：`ORDER BY published_at DESC, a.id DESC`（ASC 同理）——防止相同时间戳文章在重查时相对顺序跳变。
- AppScope 与 entry 有重复图标文件（分层图标配置，勿随意删）。
- `.appanalyzer/` 已在 `.gitignore` 排除。

## 载入 / 同步逻辑（核心，最易出 bug）

### 三个 tick（AppStorage）

定义在 `rss/SyncProgress.ets`：

| tick | 发出时机 | 节流 |
|---|---|---|
| `syncFirstBatchTick` | 首批入库后（`signalFirstBatch`），**全 sync 只发一次**；`notifyContentReady`/`notifySyncFinal` 也会兜底调用但被 `firstBatchNotified` 挡住 | 无 |
| `feedDataTick` | 每批入库后（`notifySyncBatch`） | 800ms（`NOTIFY_INTERVAL_MS`） |
| `syncFinishedTick` | sync 真正结束（`notifySyncFinal`） | 无 |

`beginSync()` 在每次 sync 开始时重置 `lastNotify` 与 `firstBatchNotified`。
`notifySyncFinal()` 在设置 `feedDataTick` 的同时设置 `syncFinishedTick`。

三种同步服务（`GoogleReaderSyncService` / `FeverSyncService` / `LocalSyncService`）都必须完整发
`beginSync → notifySyncBatch → notifyContentReady → notifySyncFinal` 全序列。
`RssRepository.syncAll()` 不再额外发 tick（避免重复全量 reload）。

### ArticleListView 的 watcher 分工（改动务必保持此分工）

- `onSyncFirstBatch()`（`syncFirstBatchTick`）：
  - 若 `isSyncing`（页面下拉刷新）→ `isRefreshing=false` **停转圈**
  - **`load(false, true)` 立即重载列表**——首批已入库，让新文章马上显示（修复"转圈停了但 UI 不变、等 toast 才瞬间更新"的关键，勿删）
- `onSyncBatch()`（`feedDataTick`）：**只** `refreshCounts()` + `refreshFeeds()`（未读数/徽标实时刷新），**不碰列表**（每批都 reload 会打断阅读）
- `onSyncFinished()`（`syncFinishedTick`）：
  - `load(false, true)` 最终补全列表（保留分页深度）
  - 若 `!isSyncing`（首装/启动同步）→ 弹 toast「同步完成」；页面下拉刷新由 `sync()` 自己弹，避免重复

### 分页与竞态护栏

- **分页机制**：不是分批 append，而是**递增 limit 重查**，SQL 固定 `ORDER BY published_at DESC, id DESC`，永远返回"从头开始的完整前 N 条"。`ForEach` 以 article.id 为 key，已有行不重建，顺序稳定。
- **序号护栏**：
  - `loadSeq`：`load()` 每次递增，每个 `await` 后校验 → 过期 load 结果丢弃
  - `pageLoadSeq`：`load()` 与 `loadMore()` 都递增；`loadMore()` 捕获后校验 → 过期 loadMore 不能覆盖新列表
  - `orderKey`：feed/group/filter/search/排序方向的快照；分批追加捕获后校验，排序切换使在途追加失效
- **分页深度**：`load(resetPaging=true, fromSync=false, snapToTop=true)`——真正切换上下文时回顶；sync 自身刷新传 `fromSync=true` 保留滚动深度。
- **上下文切换护栏**：`suppressScrollMark` + `awaitingTopConfirm`——替换行后 List 仍持旧 offset，回顶确认前禁止滚动标记，避免误标未读。

### sync 期间冲突请求的忽略规则

- 重复下拉（`sync()` 重入）→ 停本次转圈 + toast「正在同步中，请稍候」，不发起新 sync
- `loadMore()` 在 sync 期间 → **静默忽略**（滚动自动触发，弹 toast 会打扰）
- 外部 `load()` 在 sync 期间 → 忽略（`isSyncing && !fromSync`）；sync 自身传 `fromSync=true` 放行
- `refreshCounts` / `refreshFeeds` 在 sync 期间 → 保留（期望的实时徽标更新）

### 两条 sync 路径的 toast/转圈时序

- **首装 / 启动同步**（`EntryAbility` 直接调 `rssRepository.syncAll()`）：`isSyncing=false` → `onSyncFinished` 弹「同步完成」；无转圈。
- **页面下拉刷新**（`ArticleListView.sync()`）：置 `isSyncing=true` → `syncAll()` → `onSyncFinished` 因 `isSyncing=true` 不弹 toast → `sync()` 自己弹一次 → `finally` 复位。`sync()` 内无 `await load(...)`（由 `onSyncFinished` 统一负责）。

### FeedListView 的差异

- `FeedListView` **不监听 `syncFinishedTick`**，列表刷新只靠自身 `sync()` 里的 `await this.load()`——不是冗余，勿删。
- 同样有 `isSyncing` 重入保护。

### 设置通知机制

`SettingsStore` 的所有 setter 改动即写 AppStorage，AppStorage 是唯一响应式数据源：
- 外观/字体/字号 → 各页 `@StorageProp` 即时刷新；
- 文章列表行为 → 写对应键 + bump `listSettingsTick` 触发重载；
- `markReadOnScroll` / `markReadOnOpen` / `activeAccountId` 等 → 写对应键，常驻页即时响应，不依赖 `load()`/`onShown` 时机。

## 真机日志基线（用于验证）

首装同步完成时应看到：
```
greader toFetch=N batchSize=100 (local=0)
greader batch committed ... （按批）
onSyncFirstBatch → home load done articles=<首批数>
...
home onSyncFinished -> reload list
home load done articles=<全部未读数> displayLimit=<分页深度>   ← 关键：列表补全
toast 同步完成（仅一次）
```
下拉刷新（无新文章）应看到：
```
toFetch=0 → contentReady signaled → onSyncFinished → load done → toast 同步完成（仅一次）
```
有新文章时，转圈一停就应有 `home load done`（首批），而不是等 toast 才更新。

## 下一步建议

1. 按 P0 清单补齐订阅管理、上/下篇、设置生效与后台同步/通知。
2. 按 P1 清单对齐 Android 的关键交互与设置行为。
3. 视真机反馈逐步推进 P2 / P3；平台相关项（小组件、Material You、原生渲染器）需单独设计。

## 自动化测试

本工程建立了两层自动化测试，统一入口为仓库根目录的 `run_tests.sh`：

```bash
cd <repo-root> && ./run_tests.sh
```

1. **ArkTS 单元测试**（`harmony/entry/src/test/`，Hypium 框架）：覆盖解析层（XmlParser / RssParser / HtmlDom / HtmlBuilder / WebViewHtml）、ID/模型助手、纯状态机（StatusDiffs / ArticlePaging）、同步进度节流、网络分页、SettingsStore / GReaderTokenStore（注入假 Preferences）、ReadStatusStore flush（MockKit mock repository）、Database SQL 构造（mock RdbStore）等。
   - 单独运行：`cd harmony && hvigorw --mode module -p product=default -p buildMode=debug test`
   - 结果：`harmony/entry/.test/default/intermediates/test/coverage_data/test_result.txt`
2. **全文提取 fixture**（仓库根 `testcases/`，`verify.py`）：用真实站点保存的 HTML 验证正文容器选择算法（Python 参考实现，与 ArkTS 的 `HtmlDom` / `FullContentFetcher` 镜像同步）。单独运行：`cd testcases && python3 verify.py`。

> MockKit 注意（已踩坑并规避）：本版本 `@ohos/hypium` 的 `ArgumentMatchers.any()` 返回 `undefined`，多参数 stub 必须用**精确值匹配**；清理 mock 必须用 `mock.clear(obj)`，不能用 `mock.clearAll()`（后者不还原被 mock 的单例方法，会污染后续测试）。

## 许可

与 Android 原项目一致：GPL-3.0。
