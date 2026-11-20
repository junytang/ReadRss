# ReadYou 全文提取测试库

用于验证 `harmony/entry/src/main/ets/rss/` 下的全文抓取算法（`HtmlDom.ets` + `FullContentFetcher.ets`）。

## 目录结构

- `cases.json`：用例索引，记录每个 HTML 文件对应的**正文容器**（用 class / id 标识）。
- `*.html`：从真实站点保存的完整页面源码（未修改）。
- `verify.py`：通用文本密度评分算法的 Python 参考实现，与 ArkTS 版对应。

## 运行验证

```bash
cd testcases
python3 verify.py
```

输出每个用例是否选中了期望的正文容器。新增用例：把页面源码另存为 `xxx.html`，在 `cases.json` 里追加一条记录。

## 维护约定

1. 修改 ArkTS 提取算法（`HtmlDom.bestContentNode` / `drillToContent`、`FullContentFetcher.clean`）时，同步更新 `verify.py` 里的 `best` / `drill` / `clean` 逻辑，保持两边一致。
2. 新增站点出问题时，先在这里补一个用例并让 `verify.py` 失败，再改算法，避免改坏已通过的站点。
3. `cases.json` 里的 `container` 用容器 `class` 或 `id` 的一段稳定特征即可，不需要精确匹配整个属性串。
