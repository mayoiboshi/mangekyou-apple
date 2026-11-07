# 07 — P1 第一轮：静态基础与复现

用户在 P0 交付后授权继续。此次范围是语料、跨包差异、词法记录、符号/资源候选关系和 ABMP 内部结构；没有开发解释器、播放器或界面，也没有运行原版、汉化或安装程序。

**本轮静态基础已完成，P1 整体尚未完成，仍不具备进入完整运行时开发的条件。** `reports/p1/readiness.json` 分别记录本轮状态、`p1_fully_complete=false` 和 `runtime_development_ready=false`。

| 实际完成 | 结果 | 证据 |
|---|---|---|
| 扩展文本语料 | 379 文件：283 `.s`、96 `.txt`，共 6,724,955 字节 | corpus-report.json，全部摘要与 P0 研究副本清单一致 |
| 原始字节覆盖 | 655,911 物理行，291,273 个带来源范围的记录；包括 BOM、排版、填充空行 | corpus-report.json / 本地 IR；覆盖断言与回归测试 |
| 行内命令候选 | 7,398 行有多个候选片段；`.s` 内观察到 245 种反斜杠 token、33 种行标记 token | corpus-report.json；完整语法仍 inferred |
| 同名文本比较 | 177 组：53 字节相同、113 仅编码/换行层面差异、11 规范化文本不同 | overlay-report.json |
| 符号目录 | 1,868 标签定义、442 include、3,106 标签字面引用、2,306 声明候选 | symbol-report.json；作用域和执行边仍未确认 |
| 资源标识符候选 | 18,786 条候选边，其中 18,492 条仅有一个目录候选 | resource-report.json；不等于运行时绑定 |
| ABMP 内部 | 9 个顶层样本、8 个嵌套容器、48 个成员；22 图片实际解码 | abmp-report.json；动画语义不支持 |
| 测试 | 虚拟环境下 65 项通过、无跳过；系统 Python 3.9 的可选集成测试会跳过 | test-results.json |
| 原始数据保护 | 10 个 PACK 新算 SHA-256 与 P0 一致；P0 所有 JSON 摘要未变 | corpus-report.json / readiness.json |

数字保留各个包中的副本，不能当作最终生效程序的去重规模。245/33 是候选 token 拼写，不能当成已经实现或确认语义的操作码。

## 复现命令

沿用 P0 的 Python 环境、固定源码及已有研究副本，不需要重新下载游戏或运行 EXE：

```sh
.venv/bin/python tools/reproduce_p1.py --game-dir "$GAME_DIR"
```

`GAME_DIR` 仍由使用者设置，项目不硬编码本机原始目录。省略它仍可分析已有副本，但“本轮原始 PACK 摘要复核”会标为 `not_tested`。

各部分也可独立运行：

```sh
.venv/bin/python tools/p1_static.py --game-dir "$GAME_DIR"
.venv/bin/python tools/abmp_probe.py
.venv/bin/python -m unittest discover -s tests -v
```

`p1_static.py` 可用 `--assets-dir`、`--samples`、`--archives` 指定 P0 的副本和元数据；`abmp_probe.py` 另支持 `--source` 指定固定上游源码。公开输出限项目 `reports/p1/`；完整 IR 限忽略的 `private/`，并拒绝与输入目录重叠。

`reports/p1/` 不保存台词、原始资源、密钥或解码后的图像。大图关系表在公开报告中每类保留前 200 条，明确记录总数、截取上限和完整元数据的规范 JSON 摘要；完整表在 `private/p1/`。规范摘要采用 UTF-8、键排序、无额外空格及末尾 LF，区别于排版后的文件摘要。没有通过删去未知关系让统计显得完整。

原始研究副本仍是重现字节来源的必要输入。IR 的“无损”指每个字节都可由源文件 SHA-256、offset、length 和片段 SHA-256 回溯，包括 BOM 与空白；它不是已经脱离原文件、可独立执行的完整程序。
