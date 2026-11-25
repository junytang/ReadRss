<div align="center">
  <img src="https://raw.githubusercontent.com/junytang/ReadRss/main/harmony/entry/src/main/resources/base/media/app_icon.png" alt="ReadRss icon" width="120" height="120" />
  <h1>ReadRss for HarmonyOS</h1>
  <p><strong>把 ReadYou 的阅读体验带到 HarmonyOS 7</strong><br />
  基于 ArkTS + ArkUI 的原生 RSS 阅读器：本地优先、多后端同步、可深度定制的阅读体验。</p>

  <p>
    <a href="https://github.com/junytang/ReadRss/blob/main/LICENSE"><img alt="License: GPL-3.0" src="https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square" /></a>
    <a href="https://github.com/junytang/ReadRss/tags"><img alt="Version" src="https://img.shields.io/github/v/tag/junytang/ReadRss?filter=harmonyos-*&label=version&style=flat-square" /></a>
    <img alt="HarmonyOS" src="https://img.shields.io/badge/HarmonyOS-7%20%7C%20API%2026-0A59F7?style=flat-square" />
    <img alt="Tech stack" src="https://img.shields.io/badge/stack-ArkTS%20%2B%20ArkUI-41B883?style=flat-square" />
    <a href="https://github.com/junytang/ReadRss/actions/workflows/build_harmonyos.yml"><img alt="Build HarmonyOS" src="https://github.com/junytang/ReadRss/actions/workflows/build_harmonyos.yml/badge.svg" /></a>
  </p>

  <p>
    <a href="#-项目亮点">项目亮点</a> ·
    <a href="#-功能一览">功能一览</a> ·
    <a href="#-后端支持">后端支持</a> ·
    <a href="#-快速开始">快速开始</a> ·
    <a href="#开发者与维护者文档">开发者文档</a>
  </p>
</div>

> **关于本仓库**：这是 [ReadYou](https://github.com/ReadYouApp/ReadYou) Android RSS 阅读器的 HarmonyOS 原生移植工程。Android 原工程完整保留、不做改动；所有移植代码位于 [`harmony/`](https://github.com/junytang/ReadRss/tree/main/harmony) 目录，可单独用 DevEco Studio 打开。仓库根目录的 `README.md` 是指向本文件的符号链接，也就是 GitHub 首页展示的内容。原项目的多语言介绍见 [README-zh-CN.md](https://github.com/junytang/ReadRss/blob/main/README-zh-CN.md) 等文件。

## ✨ 项目亮点

- **真正的原生移植**：ArkTS + ArkUI 重写界面与数据层，而不是套壳或 Web 容器；行为尽可能与 Android 版保持一致。
- **兼容主流自建服务**：Fever、Google Reader、FreshRSS 走既有协议，Miniflux 提供原生 REST 支持；凭据加密后本地保存，多账号支持。
- **本地优先的数据层**：RDB 持久化订阅、分组、文章与已读状态，离线可读；同步期间徽标和未读数实时刷新，标记已读/星标即时生效。
- **为长文阅读打磨**：全文抓取与正文提取、上下篇连续阅读、图片全屏、深色模式等能力已落地。
- **可验证、可持续维护**：命令行可编译 HAP，根目录 `./run_tests.sh` 覆盖解析、状态机、同步与数据库等关键逻辑；接手约束与同步时序均有文档记录。

## 📰 功能一览

| 分类 | 已实现能力 |
|---|---|
| 账号与同步 | Fever / Google Reader / FreshRSS / Miniflux 多账号管理与切换；ID 流对账、批量正文抓取、标记状态双向同步；token 持久化与 401 自动重登；离线已读状态批处理。 |
| 订阅与文章 | 多源与分组浏览、未读/星标筛选、搜索、排序切换、分页加载、下拉同步、批量按时间标记、左右滑动作可配、源图标/缩略图/摘要显示开关。 |
| 阅读体验 | WebView 全文渲染与内联样式、AVIF 图片代理、上下篇导航、图片全屏查看、系统分享。 |
| 个性化 | 基础字体与外部字体导入、字号缩放、排版细项（字间距/对齐/粗体/图片圆角等）。 |
| 数据安全 | 凭据 DES 加密（与 Android `DESUtils` 同密钥）、多账号数据隔离。 |

> 当前仍在推进的订阅/分组管理 UI、OPML 导入导出与通知能力，见下方 [功能差距与路线图](#功能差距与路线图按优先级)。

## 🔌 后端支持

| 后端 | 支持情况 | 说明 |
|---|---|---|
| 本地源（Local） | ✅ | 直接抓取 RSS / Atom，自研轻量 XML 解析器，无需服务端。 |
| Fever | ✅ | 分组/订阅/图标、分页文章、未读与收藏状态对账、标记读写；按能力矩阵暂为只读管理。 |
| Google Reader / FreshRSS | ✅ | ClientLogin + Token、订阅与标签、ID 流对账、批量正文抓取、标记读写；后端管理方法已有，部分 UI 待接入。 |
| Miniflux | ✅ | 原生 REST API（API Token / Basic Auth）、分类订阅、图标、分页文章、状态对账与订阅管理。 |
| 其他服务 | ➖ | Feedly / Inoreader 等沿用 Android 版的禁用策略，不提供入口。 |

## 🚀 快速开始

1. 安装 **DevEco Studio 6.0+** 与 **HarmonyOS SDK API 26**。
2. 用 DevEco 打开仓库中的 `harmony/` 目录，等待依赖同步（无第三方 ohpm 依赖，仅使用系统 Kit）。
3. 在 `File > Project Structure > Signing Configs` 登录华为账号并配置调试签名，连接真机或 API 26 模拟器。
4. 选择 `entry` 模块 → `release` target → 运行。

命令行编译（**unsigned 包无法直接安装到真机**，真机部署请先配置签名）：

```bash
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
  --mode module -p product=default -p buildMode=release assembleHap \
  --analyze=normal --parallel --incremental --daemon
```

运行全部自动化测试：

```bash
./run_tests.sh
```

---

## 开发者与维护者文档

### 环境要求

- DevEco Studio **6.0.0+** / HarmonyOS SDK **API 26**（`compatibleSdkVersion` / `targetSdkVersion = "26.0.0"`，`modelVersion = "7.0.0"`；API 26 起不再接受 `"7.0.0(26)"` 旧格式）。
- HarmonyOS 7 真机或 API 26 模拟器；首次打开工程需在 DevEco 配置调试签名。
- 无第三方 ohpm 依赖，只用系统 Kit；关键文件索引见 `AGENTS.md`。
- 本机已验证 `hvigorw assembleHap` / `test`；运行时行为以用户真机日志为准。

### 工程结构

```
harmony/
├── AppScope/                 # bundleName、图标、名称
├── entry/src/main/
│   ├── module.json5          # ability、INTERNET 权限
│   ├── resources/            # 字符串、颜色、图标
│   └── ets/
│       ├── entryability/     # EntryAbility：DB / 偏好初始化
│       ├── common/ account/ model/ data/   # 常量路由、账号与 DES、模型、RDB + Preferences
│       ├── rss/              # 解析器、RssRepository、三种同步服务与 API
│       ├── components/       # FeedListView / ArticleListView / ReadingView / 设置与账号页
│       └── pages/Index.ets   # Navigation 路由
├── build-profile.json5
└── oh-package.json5
```

### 与 Android 版架构对照

| Android | HarmonyOS |
|---|---|
| `@HiltAndroidApp` + Hilt 依赖注入 | 模块级单例（`database` / `settingsStore` / `rssRepository` / `accountRepository`） |
| `RssService.get(type)` 及三大实现 | `SyncServiceFactory.syncServiceFor(account)` + Local / Fever / GoogleReader 三种服务 |
| `FeverAPI` / `GoogleReaderAPI` | `FeverApi` / `GoogleReaderApi`（`@ohos.net.http`） |
| `AccountType` + 安全密钥 + DESUtils | `AccountType` 枚举 + `CredentialCodec`（DES64\|ECB\|PKCS7 + MD5） |
| `MainActivity`（单 Activity） | `EntryAbility`（Stage 模型） |
| Compose `NavDisplay` + Navigation 3 | ArkUI `Navigation` + `NavPathStack` |
| ViewModel | 页面内 `@State` + Repository（MVP 简化） |
| Room + DAO + Paging 3 | RDB + 显式 SQL（无 Paging，列表上限 500 条） |
| DataStore Preferences（72 个类） | `@ohos.data.preferences`（随功能持续扩充） |
| WebView + JS 注入 / CSS | `@ohos.web.webview` + `loadData` + 内联 CSS |
| WorkManager 定期同步 | 启动时同步 + 下拉刷新（无后台任务） |

### 功能差距与路线图（按优先级）

> P0 = 基本可用/半成品；P1 = 行为对齐；P2 = 体验增强；P3 = 平台外围。已完成项见上文「功能一览」，此处只列剩余待办与有意裁剪。

**P0 — 优先补齐**
- [ ] 订阅/分组管理：`FeedListView` 中「添加订阅」入口仍被注释；`SubscribeView` 已实现，但配置流程未接通（URL 搜索、重命名、选分组、每源开关、新建分组）。
- [ ] 源/分组配置抽屉：favicon 重抓、重命名/改 URL/移组、清空文章、取消订阅、批量开关；分组删除等 GReader 后端方法已有，缺 UI。
- [ ] OPML 导入 / 导出（导出可选是否包含每源附加配置）；落实能力矩阵：Local 全功能 / GReader 可管理但不可导 OPML / Fever 只读（当前 Fever 取消订阅抛异常）。
- [ ] 通知：申请权限、建渠道、点击直达文章，补 Local 同步通知；去重状态需持久化（现为内存 Map，重启丢失）。

**P2 — 剩余**
- [ ] 自适应双栏（列表 + 详情）+ 分栏拖拽手柄 + 三态导航按钮。

**有意裁剪**
- Feedly / Inoreader 实际协议（Android 同样禁用入口，回退本地服务）。
- GReader 同步性能优化（偏离 Android）：已读 ID 只取前 3 页（≤3000）用于对账、不抓正文；正文只抓未读与星标，避免首次同步上万次请求。
- WebView 图片点击/保存回调与 JS Bridge：改用图片代理与系统分享替代。

### 关键技术决策

- 配置以代码为准：`build-profile.json5` 中 `compatibleSdkVersion` / `targetSdkVersion = "26.0.0"`、`runtimeOS = "HarmonyOS"`；`oh-package.json5` 中 `modelVersion = "7.0.0"`（未显式声明 `compileSdkVersion` / `arkTSVersion`，API 26 工具链可正常编译）。
- 阅读器「更多」菜单用系统 `bindMenu`；AVIF 走公共代理 + 虚假 HTTPS URL + WebView `onInterceptRequest` 拦截（`ArticleImageConverter.ets` / `ReadingView.ets`）。
- 分页：`onReachEnd` 递增 limit 重查，首批 20–80 行补齐至 `FULL_PAGE_SIZE=100`，之后 `LOAD_MORE_STEP=100`。
- 分批大小 50 / 100 / 200 / 300 / 500，默认 **100**；GReader ID 页固定 **1000**，`fetchBatchSize` 只控制正文抓取/入库批次。
- GReader token 持久化 **30 天**，401 清除重登；已读 ID 每次 sync 都对账，无节流。
- `listArticles` 次级排序 `ORDER BY published_at DESC, a.id DESC`（ASC 同理），防止相同时间戳重查跳序。
- AppScope 与 entry 重复图标是分层配置，勿删；`.appanalyzer/` 已 gitignore。

### 载入 / 同步逻辑

**三个 tick（AppStorage，定义于 `rss/SyncProgress.ets`）**
- `syncFirstBatchTick`：首批入库后由 `signalFirstBatch` 发出，全 sync 仅一次（`firstBatchNotified` 挡住兜底调用），无节流。
- `feedDataTick`：每批入库后由 `notifySyncBatch` 发出，节流 800ms。
- `syncFinishedTick`：`notifySyncFinal` 发出，同时设置 `feedDataTick`，无节流。
- `beginSync()` 每次重置 `lastNotify` / `firstBatchNotified`。三种服务都必须发 `beginSync → notifySyncBatch → notifyContentReady → notifySyncFinal` 全序列；`RssRepository.syncAll()` 不再发 tick（避免重复 reload）。

**ArticleListView watcher**
- 首批 tick：下拉刷新时停转圈（`isRefreshing=false`），并立即 `load(false, true)` 显示新文章（修复「转圈停了 UI 不变」的关键，勿删）。
- 批次 tick：只 `refreshCounts()` + `refreshFeeds()` 实时刷未读/徽标，不碰列表（避免打断阅读）。
- 结束 tick：`load(false, true)` 补全列表且保留分页深度；非下拉刷新时弹「同步完成」，下拉刷新的 toast 由 `sync()` 自己弹。

**分页与竞态护栏**
- 分页是递增 limit 重查（非 append），SQL 固定 `ORDER BY published_at DESC, id DESC`；`ForEach` 以 article.id 为 key，已有行不重建。
- `loadSeq` 每次 `load()` 递增并在每个 `await` 后校验；`pageLoadSeq` 被 `load` / `loadMore` 共同递增，丢弃过期追加；`orderKey` 快照 feed/group/filter/search/排序方向，使上下文切换时在途追加失效。
- `load(resetPaging=true, fromSync=false, snapToTop=true)`：真正切换上下文才回顶；sync 自身刷新传 `fromSync=true` 保留滚动深度。
- `suppressScrollMark` + `awaitingTopConfirm`：替换行后 List 仍持旧 offset，回顶确认前禁止滚动标记，避免误标未读。

**冲突与时序**
- 重复下拉：停转圈 + toast「正在同步中，请稍候」，不发起新 sync；sync 期间 `loadMore()` 静默忽略、外部 `load()` 忽略（`isSyncing && !fromSync`），但 `refreshCounts/Feeds` 保留。
- 首装/启动同步：`isSyncing=false`，结束时由 `onSyncFinished` 弹 toast，无转圈。
- 页面下拉：`isSyncing=true` → `syncAll()` → 结束 tick 不弹 toast → `sync()` 弹一次并在 `finally` 复位；`sync()` 内不 `await load(...)`。
- `FeedListView` 不监听 `syncFinishedTick`，只靠自身 `sync()` 的 `await this.load()`（不是冗余，勿删），同样有 `isSyncing` 重入保护。
- 设置写入即写 AppStorage（唯一响应式源）：外观/字体/字号走 `@StorageProp`；列表行为写键 + bump `listSettingsTick`；`markReadOnScroll` / `markReadOnOpen` / `activeAccountId` 常驻页即时响应。

### 自动化测试

统一入口：仓库根目录 `./run_tests.sh`。
- ArkTS 单测（`harmony/entry/src/test/`，Hypium）：解析层、模型助手、状态机、同步节流、网络分页、SettingsStore / TokenStore / ReadStatusStore / Miniflux / Database SQL。单独运行 `cd harmony && hvigorw --mode module -p product=default -p buildMode=debug test`，结果在 `harmony/entry/.test/default/intermediates/test/coverage_data/test_result.txt`。
- 全文提取 fixture（`testcases/verify.py`）：用真实站点 HTML 验证正文容器选择，与 ArkTS 实现镜像；单独运行 `cd testcases && python3 verify.py`。
- MockKit 注意：本版本 `ArgumentMatchers.any()` 返回 `undefined`，多参数 stub 用精确值；清理用 `mock.clear(obj)`，勿用 `mock.clearAll()`（会污染后续测试）。

### 许可

与 Android 原项目一致：GPL-3.0。详见 [LICENSE](https://github.com/junytang/ReadRss/blob/main/LICENSE)。
