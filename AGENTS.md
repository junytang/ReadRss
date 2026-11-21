# AGENTS.md — ReadYou HarmonyOS 7 移植接手指南

本文件供后续接手本项目的模型/开发者快速了解背景、约束和当前状态。
**必读**：动手前先读完「用户硬性要求」和「载入/同步逻辑」两节——历史上绝大多数 bug 都出在这两块。

## 1. 项目定位与工作范围

- 这是 **ReadYou Android RSS 阅读器** 的 **HarmonyOS 7 原生 ArkTS/ArkUI 移植** worktree。
- **Android 原工程保持原样，禁止改动**（本仓库根目录下 `app/`、`gradle/` 等均为 Android 代码）。
- 所有移植代码在 `harmony/` 下，是一个可单独用 DevEco Studio 打开的独立工程。
- 架构映射、已实现功能、已知限制详见 `harmony/README.md`（本文件不重复，只讲「接手必需」的动态信息）。

### Git 状态

- 分支：`port/harmonyos7`
- 具体提交历史和工作树状态以 `git log` / `git status` 为准，本文件不缓存易过期的信息。

## 2. 用户硬性要求（最高优先级，不要自由发挥）

1. **所有行为要求和 Android 版一致，不要自由发挥**。有疑问时查 Android 对应实现，不要凭直觉设计。
2. **优先使用系统默认组件**（ ArkUI 系统组件 / bindMenu 等），除非用户明确要求自定义。
3. 标记已读/星标等操作：**UI 必须立即响应**（乐观更新），服务器响应只用于纠正状态。
4. 所有未读徽标/计数要在同步过程中**实时刷新**，不要等整个 sync 完成。
5. 用户在**真机**上用 DevEco 构建测试，本地环境**无法编译** HarmonyOS，以用户提供的真机日志为权威依据。

## 3. 环境与验证方式

- 本机无 DevEco / HarmonyOS SDK，**不能编译或运行**。
- 修改后用 Python 脚本做括号/结构校验（历史用法：遍历 `.ets` 做 `{[(` 配对检查），仅能防语法结构错误。
- 运行时结论必须靠用户真机日志验证。日志中 `SYNCDBG` 前缀均为诊断日志（见第 8 节）。

## 4. 关键技术决策（已定，勿随意推翻）

- 目标：**HarmonyOS 7 / API 26**，`compileSdkVersion/compatibleSdkVersion/targetSdkVersion = "26.0.0"`，`arkTSVersion "1.1"`，`modelVersion "7.0.0"`（API 26 起不接受 `"7.0.0(26)"` 旧格式）。
- 无第三方 ohpm 依赖，只用系统 Kit。
- `showFullContent` 设置项已移除——全文抓取始终开启。
- 阅读器「更多」菜单用 ArkUI 系统 `bindMenu`：浏览器打开 / 复制链接 / 系统分享。
- AVIF 图片：设备 ArkWeb 不能解码，走公共代理 `https://images.weserv.nl/?url=...&output=jpeg...`，通过虚假 HTTPS URL + WebView `onInterceptRequest` 暴露（见 `ArticleImageConverter.ets` / `ReadingView.ets`）。
- Feed / 分组按最新文章时间降序排序。
- 订阅抽屉宽度 66%（从 82% 调小）。
- 分页加载：`onReachEnd` 触发，`displayLimit` 每次 +500。
- 分批大小设置值：50 / 100 / 200 / 300 / 500，默认 **100**（`SettingsStore` + `AppSettings.fetchBatchSize`）。
- GReader ID 分页大小固定 **1000**；`fetchBatchSize` 只控制正文抓取/入库批次。
- GReader token 持久化 **30 天**（`GReaderTokenStore.ets`），401 时清除重登。
- 已读 ID 对账**每次 sync 都做**，无时间间隔节流。
- `listArticles` 排序带次级键：`ORDER BY published_at DESC, a.id DESC`（ASC 同理）——防止相同时间戳文章在重查时相对顺序跳变。
- AppScope 与 entry 有重复图标文件（分层图标配置，勿随意删）。
- `.appanalyzer/` 已在 `harmony/.gitignore` 排除。

## 5. 载入 / 同步逻辑（核心，最易出 bug）

### 5.1 涉及的三个 tick（AppStorage）

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

### 5.2 ArticleListView 的 watcher 分工（**改动务必保持此分工**）

- `onSyncFirstBatch()`（`syncFirstBatchTick`）：
  - 若 `isSyncing`（页面下拉刷新）→ `isRefreshing=false` **停转圈**
  - **`load(false, true)` 立即重载列表**——首批已入库，让新文章马上显示（这是修复"转圈停了但 UI 不变、等 toast 才瞬间更新"的关键，勿删）
- `onSyncBatch()`（`feedDataTick`）：**只** `refreshCounts()` + `refreshFeeds()`（未读数/徽标实时刷新），**不碰列表**（每批都 reload 会打断阅读）
- `onSyncFinished()`（`syncFinishedTick`）：
  - `load(false, true)` 最终补全列表（保留分页深度）
  - 若 `!isSyncing`（首装/启动同步）→ 弹 toast「同步完成」；页面下拉刷新由 `sync()` 自己弹，避免重复

### 5.3 分页与竞态护栏

- **分页机制**：不是分批 append，而是**递增 limit 重查**——`LIMIT 500 → 1000 → 1500`，SQL 固定
  `ORDER BY published_at DESC, id DESC`，永远返回"从头开始的完整前 N 条"。`ForEach` 以 article.id 为 key，
  已有行不重建，因此顺序稳定，不会出现"先 456 后 123"的乱序。
- **序号护栏**：
  - `loadSeq`：`load()` 每次递增，每个 `await` 后校验 → 过期 load 结果丢弃
  - `pageLoadSeq`：`load()` 与 `loadMore()` 都递增；`loadMore()` 捕获后校验 → 过期 loadMore 不能覆盖新列表
- **分页深度**：`load(resetPaging=true, fromSync=false)`
  - 真正切换上下文（筛选/源/搜索/`onShown`）→ 默认 `resetPaging=true`，重置为 500
  - sync 自身的刷新（首批/完成）传 `fromSync=true` 且 `resetPaging=false`，保留用户滚动深度，列表不缩水

### 5.4 sync 期间冲突请求的忽略规则

- 重复下拉（`sync()` 重入）→ 停本次转圈 + toast「正在同步中，请稍候」，不发起新 sync
- `loadMore()` 在 sync 期间 → **静默忽略**（滚动自动触发，弹 toast 会打扰）
- 外部 `load()` 在 sync 期间 → 忽略（`isSyncing && !fromSync`）；sync 自身传 `fromSync=true` 放行
- `refreshCounts` / `refreshFeeds` 在 sync 期间 → 保留（是期望的实时徽标更新）

### 5.5 两条 sync 路径的 toast/转圈时序

- **首装 / 启动同步**（`EntryAbility` 直接调 `rssRepository.syncAll()`，不经过页面 `sync()`）：
  `isSyncing=false` → `onSyncFinished` 弹「同步完成」；无转圈。
- **页面下拉刷新**（`ArticleListView.sync()`）：
  置 `isSyncing=true` → `syncAll()`（内部发 tick）→ `onSyncFinished` 因 `isSyncing=true` 不弹 toast →
  `sync()` 自己弹一次「同步完成」→ `finally` 复位 `isSyncing/isRefreshing`。
  **注意**：`sync()` 内已移除 `await this.load(...)`（冗余，由 `onSyncFinished` 统一负责）。

### 5.6 FeedListView 的差异

- `FeedListView` **不监听 `syncFinishedTick`**，它的列表刷新只靠自身 `sync()` 里的 `await this.load()`——这**不是**冗余，勿删。
- 它同样有 `isSyncing` 重入保护（重复下拉 toast「正在同步中，请稍候」）。

## 6. 关键文件索引

| 文件 | 职责 |
|---|---|
| `harmony/entry/src/main/ets/components/ArticleListView.ets` | 文章列表：`load/loadMore/sync`、全部 watcher、序号护栏、乐观标记、滚动标记 |
| `harmony/entry/src/main/ets/components/FeedListView.ets` | 订阅页：加载、`isSyncing` 保护、未读徽标 |
| `harmony/entry/src/main/ets/data/Database.ets` | RDB 与 SQL；`listArticles`（377 行起，含次级排序） |
| `harmony/entry/src/main/ets/rss/SyncProgress.ets` | 三个 tick 的定义与节流 |
| `harmony/entry/src/main/ets/rss/RssRepository.ets` | 同步门面 `syncAll()`（169 行起） |
| `harmony/entry/src/main/ets/rss/GoogleReaderSyncService.ets` | GReader/FreshRSS 同步阶段、ID 页、批量正文、延迟对账（核心循环 304 行起） |
| `harmony/entry/src/main/ets/rss/FeverSyncService.ets` / `LocalSyncService.ets` | 另两种同步服务的批次/tick |
| `harmony/entry/src/main/ets/rss/GoogleReaderApi.ets` / `GReaderTokenStore.ets` | token 持久化（30 天）、401 重登 |
| `harmony/entry/src/main/ets/common/ArticleImageConverter.ets` | AVIF 代理 + 虚拟 URL 拦截映射 |
| `harmony/entry/src/main/ets/components/ReadingView.ets` | WebView 全文渲染、`onInterceptRequest`、更多菜单 |
| `harmony/entry/src/main/ets/data/SettingsStore.ets` / `model/Models.ets` | `fetchBatchSize` 等设置持久化 |
| `harmony/entry/src/main/ets/entryability/EntryAbility.ets` | 启动初始化 tick、首装同步 |

## 7. 真机日志基线（用于验证）

首装同步完成时应看到：
```
greader toFetch=N batchSize=100 (local=0)
greader batch committed ... （按批）
onSyncFirstBatch → home load done articles=<首批数>
...
home onSyncFinished -> reload list
home load done articles=<全部未读数> displayLimit=500   ← 关键：列表补全
toast 同步完成（仅一次）
```
下拉刷新（无新文章）应看到：
```
toFetch=0 → contentReady signaled → onSyncFinished → load done → toast 同步完成（仅一次）
```
有新文章时，转圈一停就应有 `home load done`（首批），而不是等 toast 才更新。

## 8. 已知待办 / 注意事项

- `SYNCDBG` 诊断日志已于 2026-11-21 **全部清理**（40 处 / 7 个文件），`Logger.error` 等错误日志全部保留。
  清理时同步移除了 `SyncProgress.ets`、`FeedListView.ets` 中不再使用的 `Logger` import，并修掉了
  `notifySyncBatch()` 里因删日志而空掉的 `else` 块。不要在 sync/load 热路径重新引入高频 `Logger.info`。
- 跨页面并发 sync：`ArticleListView` 与 `FeedListView` 各有独立 `isSyncing`，理论上可同时发起 sync 并发写库（用户未要求处理）。
- 服务端层面：sync 期间用户的标记操作可能被 GReader 的 toRead/toUnread 对账覆盖（数据一致性问题，未处理）。
- 用户偏好系统组件；不要引入自定义绘制替代系统组件。
