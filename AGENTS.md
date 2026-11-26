# AGENTS.md — ReadYou HarmonyOS 7 移植接手指南

本文件供后续接手本项目的模型/开发者快速了解背景、约束和当前状态。
**必读**：动手前先读完本文件「用户硬性要求」和 `harmony/README.md` 中的「载入 / 同步逻辑」——历史上绝大多数 bug 都出在这两块。

## 1. 项目定位与工作范围

- 这是 **ReadYou Android RSS 阅读器** 的 **HarmonyOS 原生 ArkTS/ArkUI 移植工程**（普通 git 仓库，非 worktree）。
- **Android 原工程保持原样，禁止改动**（本仓库根目录下 `app/`、`gradle/` 等均为 Android 代码）。
- 所有移植代码在 `harmony/` 下，是一个可单独用 DevEco Studio 打开的独立工程。
- 架构映射、已实现功能，以及全部技术细节（关键技术决策、载入/同步逻辑、真机日志基线、已知待办）详见 `harmony/README.md`。本文件只保留「接手必需」的硬性约束、验证方式和文件索引。

### Git 状态

- 分支：`main`（移植代码就在本仓库的 `harmony/` 目录下）。
- 具体提交历史和工作树状态以 `git log` / `git status` 为准。

## 2. 用户硬性要求（最高优先级，不要自由发挥）

1. **所有行为要求和 Android 版一致，不要自由发挥**。有疑问时查 Android 对应实现，不要凭直觉设计。
2. **优先使用系统默认组件**（ ArkUI 系统组件 / bindMenu 等），除非用户明确要求自定义。
3. 标记已读/星标等操作：**UI 必须立即响应**（乐观更新），服务器响应只用于纠正状态。
4. 所有未读徽标/计数要在同步过程中**实时刷新**，不要等整个 sync 完成。
5. 用户在**真机**上测试；本地已装 DevEco 可编译（见第 3 节），但运行时行为仍以用户提供的真机日志为权威依据。
6. **所有新加的正文文字统一用 `fs(15)`**（即 `this.fs(15)`，随系统字号缩放），并且**必须支持自定义字体**——用 `fontFamily(this.appFont())`（`appFont()` 读取 `systemFontFamily` + `fontDataTick`，映射 `FontManager.familyFor()`）。这是设置页及所有新增 UI 文字的固定风格：标题 `fs(19)`、正文 `fs(15)`、描述 `fs(13)`、分组抬头 `fs(14)`，全部走 `appFont()`。例外：预览正文按既有规则。

## 3. 环境与验证方式

- **本地已安装 DevEco Studio**（`/Applications/DevEco-Studio.app`），自带 SDK 为 **API 26**（`26.0.1.120`），可直接编译。
  但本机无法安装/运行 HAP，运行时验证仍依赖用户真机日志。
- 已实测可用的命令行构建（在 `harmony/` 目录下执行）：
  ```
  /Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
    /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
    --mode module -p product=default -p buildMode=release assembleHap \
    --analyze=normal --parallel --incremental --daemon
  ```
  - 产物：`harmony/entry/build/default/outputs/default/entry-default-unsigned.hap`。
  - **unsigned**：`build-profile.json5` 的 `signingConfigs` 为空，产物装不到真机；真机部署需在 DevEco 的
    `File > Project Structure > Signing Configs` 配好签名后重新构建。
  - `--incremental` 会复用缓存（未改动的 task 显示 `UP-TO-DATE`）；需要全量重编时去掉该参数或先清 `entry/build`。
- 编译只能验证语法/API；UI 与运行时逻辑仍需真机日志（日志基线见 `harmony/README.md`）。
- 括号/结构校验（遍历 `.ets` 做 `{[(` 配对）仅能防语法结构错误，是编译之外的补充手段。

## 4. 关键文件索引

| 文件 | 职责 |
|---|---|
| `harmony/entry/src/main/ets/components/ArticleListView.ets` | 文章列表：`load/loadMore/sync`、全部 watcher、序号护栏、乐观标记、滚动标记 |
| `harmony/entry/src/main/ets/components/FeedListView.ets` | 订阅页抽屉：由父级刷新驱动，未读徽标 |
| `harmony/entry/src/main/ets/data/Database.ets` | RDB 与 SQL；`listArticles`（377 行起，含次级排序） |
| `harmony/entry/src/main/ets/rss/SyncProgress.ets` | 三个 tick 的定义与节流 |
| `harmony/entry/src/main/ets/rss/RssRepository.ets` | 同步门面 `syncAll()`（169 行起） |
| `harmony/entry/src/main/ets/rss/GoogleReaderSyncService.ets` | GReader/FreshRSS 同步阶段、ID 页、批量正文、延迟对账（核心循环 304 行起） |
| `harmony/entry/src/main/ets/rss/FeverSyncService.ets` / `LocalSyncService.ets` | 另两种同步服务的批次/tick |
| `harmony/entry/src/main/ets/rss/GoogleReaderApi.ets` / `GReaderTokenStore.ets` | token 持久化（30 天）、401 重登 |
| `harmony/entry/src/main/ets/common/ArticleImageConverter.ets` | AVIF 代理 + 虚拟 URL 拦截映射 |
| `harmony/entry/src/main/ets/components/ReadingView.ets` | WebView 全文渲染、`onInterceptRequest`、更多菜单 |
| `harmony/entry/src/main/ets/data/SettingsStore.ets` / `model/Models.ets` | 设置持久化与 AppStorage 发布 |
| `harmony/entry/src/main/ets/entryability/EntryAbility.ets` | 启动初始化 tick、首装同步 |
