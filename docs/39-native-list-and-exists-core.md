# 39 — 字符串列表、变量类别和相对资源候选

开发版 0.6.0 接入独立的 `list` 文本组件和 `vexs`。明确选定版本后，真实启动片段从上轮 260 条推进至 715 条记录，再停在未实现的三参数 `for`。仍不能完整游玩，也未与原程序执行对照。原文件只读，未启动 EXE/DLL。

## 哪些证据改变了实现

三份原生报告合计 33 个选定查询、17 项指定机器指令事实：`list-native-report.json`（10 / 7）、`list-helper-native-report.json`（17 / 7）、`list-path-native-report.json`（6 / 3）。这些计数包含伪代码、汇编及明确的函数覆盖查询，不能称为 33 个完整恢复的函数。

`list-binding-report.json` 重新核对类字段、类型单元、跳表和 6 处选定字节模式：

| 对象 | 静态绑定 |
|---|---|
| TImoObjectDataStringList | VMT 0x688764，实例 32 字节，obj +24；构造写类型字节 23 |
| TStringList | VMT 0x432d50，FCount +32、FCaseSensitive +42；不是 table 的 TFastStringList |
| 对象分派 | 类型 23 → 0x6cce64；类型 36 的 table 分派保持独立 |
| TImoPath | VMT 0x6a4ed8，实例 44 字节，SelfFilePath 回调 +24；上下文 +0x13c 绑定它 |

列表构造器明确把大小写标志设为零。`l` 分支打开流后调用组件清空和流载入；标准文本分割分支识别 NUL、LF、CR，并消费 CR 后的可选 LF。名称取值通过虚方法查找第一个分隔符和名称，再从匹配行取值；不能照搬 table 的双斜杠过滤或空值标记处理。

`?v` 的两种组件也有区别：list 在找到非空值后调用另一个整数转换帮助函数，传入两个零字，而不是 table 使用的数字默认值。当前核心只实现受限缓存转换，未覆盖的数值范围或拼写明确停止；完整 64 位转换为 `unsupported`。

`vexs` 的指令选择值为 0x73786576。所选分支把原始名称、当前帧上下文交给查询包装函数，随后把返回字节写入 ResultInt。包装函数实际从输出字节取值；伪代码呈现的无条件返回一不可靠。结合此前 `native-variable-report.json.lookup_order_category_3_2_1`，当前模型返回本地/全局/系统类别 3/2/1，未找到为 0，**不是统一的真假值**。

这些机器指令和元信息的局部检查为 `verified`；对象语义组合及移植实现为 **Hypothesis / inferred**。原引擎等价性保持 `not_tested`。

## 资源查找的适用范围

`l` 所用路径解析器会先调用 SelfFilePath 回调，尝试拼接当前路径与输入，再尝试输入本身，之后还有配置路径列表。上下文的回调绑定至 0x6d1534；有界窗口可追至读取器当前键、记录 +12 和目录提取帮助函数。目录分隔常量包含反斜线和冒号。

当前实现只把前两个候选映射到固定来源目录表：当前脚本的逻辑目录，然后原始逻辑名。存在不同字节副本时仍须显式选择，不能因后面的根目录副本唯一而绕过前面的歧义。配置搜索目录、Windows 绝对路径与文件系统扩展、完整预处理后的来源恢复尚不支持。此限定见 `ScriptModuleCatalog.resourcePath` 和 v5 契约；没有把它称为完整 Windows 路径兼容。

真实片段因此能以 `ValueDefault.txt` 关联到 `script/config/valuedefault.txt` 的两份副本；最终仍分别选择 data7 或 data8，未自动决定包优先级。

## 非 ASCII 名称如何处理

`ScriptStringList` 保留全部行及来源摘要，不在载入时删除注释形状的行，不转换 `%%none%%`。公开行摘要只含字节位置、正文/名称/值的 SHA-256 和比较状态。

现有实现只覆盖 ASCII 名称比较。非 ASCII 名称正常保存，`comparisonStatus=unsupported`；查询按来源顺序进行，在匹配前遇到这样的名称就停止，报告该资源行位置。已在更早的受支持名称处命中的查询可以返回，不会越过未知比较继续查找。`nameCount` 仅统计本模型的不同 ASCII 名称，`unresolvedNameCount` 统计未解释比较的名称行数，不是原生等价键数量。

两份真实列表均有 76 行、48 个 ASCII 名称和 1 行未知比较。此次执行所需查询在到达未知行前已命中；这不能证明未来查询或其他文本没有区域比较问题。Windows 用户区域设置和缺省代码页仍未复现。

## 本地实现和真实结果

`ScriptStringList.swift`、`ScriptStorage.swift` 和 `ScriptMachine.swift` 新增：空列表句柄、混合对象作用域、固定摘要的列表载入、有限取值、变量类别检查及整条失败指令不提交。每个文本限 1 MiB / 10,000 行 / 每行 8,192 UTF-8 字节，列表累计来源 8 MiB / 50,000 行；table 与 list 句柄合计最多 512。其他数组、字符串、快照和执行时间限制继续生效。

`list-execution-report.json` 固定本次源码、ARM64 执行文件及十份依据报告的摘要。全部 379 份文本、291,273 条词法记录再次与 Python 字节模型比较，零差异；列表行摘要另由独立 Python 模型重建。它们不是原引擎变量值或演出等价测试。

| 显式选择范围 | 处理记录 | 观察到的停止 |
|---|---:|---|
| 不选版本 | 20 | 模块歧义 |
| 只选初始化模块 | 29 | 配置歧义 |
| 初始化模块及两份配置 | 257 | 下一模块歧义 |
| 再选配置脚本 | 266 | 当前目录列表副本歧义 |
| 再选对应列表副本 | 715 | 未支持的 for，三参数 |

最后三行的明确选择分别对 data7、data8 保留独立场景；总共 8 个场景。715 条路径均完成 27 次变量类别检查、48 次查询及 3 次文本载入，逐个核对 839 个来源字节引用。为保持既有轨迹字段稳定，公共处理器的一些动作名仍含 `table`，这里的查询/载入总数包含 table 与 list，不能当成表专属统计。

终点引用均为 `script/config/value.s` 第 207 行：data7 offset 4384、length 16；data8 offset 8770、length 32。完整源摘要及范围摘要见各场景的 `machine.currentLocation`；下一条没有执行，也没有跳过未知循环。处理记录包含空行与元记录，不能换算为整作进度。

## 测试、失败与边界

新增 11 项 Swift 自建测试覆盖重复名称、标记/斜杠保持、空值、非数字零缓存、范围拒绝、CR/LF/UTF-16 字节位置、混合作用域、类别 0/1/2/3、结果字符串保持、相对路径优先、版本歧义、失败原子性及未知名称顺序。原生测试合计 85 项通过。新增 4 项 Python 测试核对独立行模型、限制和伪造报告拒绝。

首次回归有一项测试仍断言当前 profile 必须为 v4；调整到 v5 后通过，旧日志保留。早期列表模型在载入时拒绝非 ASCII 名称；真实样本暴露该限制后改为保留并在实际比较处停止，未用跳过未知行来推进。

Ghidra 默认分析缺少 7 个选定函数，最初共 14 次代码查询失败；后续显式覆盖查询和 9 个有界 LLVM 窗口保留这些缺口。没有修改 Ghidra 元数据，`default_function_coverage_status` 仍为 `unsupported`。窗口的选定范围解码检查通过，不代表完整函数边界或完整控制流已恢复。

探索时曾从一处指令中间开始窗口解码，随后改用已经核对的起点；该初始窗口没有用于事实。另一次类绑定把偏移 +20 交给仅遍历到 +12 的最小槽位探针，触发拒绝；后改为对较大偏移独立读取并核对目标。原始查询/窗口/回归日志保留在 private，未修改上游或覆盖 P0 来制造通过。

完整检查见 `round28-tests.json` / `round28-readiness.json`：研究 Python 350 项通过、零跳过；系统 Python 347 项通过、3 项跳过；上游合成检查 26 项通过、8 项商业 fixture 缺失而跳过。跳过不计作通过。20 个关键原文件摘要及 12 份冻结 P0 报告保持一致。

ARM64 0.6.0 构建及 10 个既有图片样本核验见 `native-app-round28.json`。本轮还实际通过 CUA 界面完成导入、五次 data8 版本选择，并观察到 20 → 29 → 145 → 257 → 266 → 715 条记录的状态变化；最终列表 76 行、for 第 207 行 offset 8770，与命令行相符。`gui-replay-round28.json` 保存这一次观察的脱敏元数据；生成命令只核对已保留的观察和 CLI/应用摘要，不伪称自己执行了 UI 自动化。`verify_native.py` 自身不操作界面，其 GUI 字段仅表示该命令未执行回放。其他界面路径为 `not_tested`。

## 复现

使用用户合法持有且摘要匹配的原目录与研究副本。JAVA_HOME、GHIDRA_INSTALL_DIR 和所有输入路径由使用者提供：

```sh
.venv/bin/python tools/rea_static.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-list-plan.json --output private/p1-round28/native-reproduced \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
.venv/bin/python tools/rea_static.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-list-helper-plan.json --output private/p1-round28/helper-confirmed \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
.venv/bin/python tools/rea_static.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-list-path-plan.json --output private/p1-round28/path-native \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
.venv/bin/python tools/native_windows.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-list-windows.json --output private/p1-round28/windows
.venv/bin/python tools/review_native.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-list-plan.json --facts docs/native-list-facts.json \
  --evidence-dir private/p1-round28/native-reproduced --output reports/p1/list-native-report.json
.venv/bin/python tools/review_native.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-list-helper-plan.json --facts docs/native-list-helper-facts.json \
  --evidence-dir private/p1-round28/helper-confirmed --windows-dir private/p1-round28/windows \
  --output reports/p1/list-helper-native-report.json
.venv/bin/python tools/review_native.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-list-path-plan.json --facts docs/native-list-path-facts.json \
  --evidence-dir private/p1-round28/path-native --output reports/p1/list-path-native-report.json
.venv/bin/python tools/list_bindings.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL"
.venv/bin/python tools/verify_list_execution.py \
  --assets-dir "$ASSETS_DIR" --script-file data0.pack/startup.s
python3 tools/build_native.py
.venv/bin/python tools/verify_native.py --game-dir "$GAME_DIR" --assets-dir "$ASSETS_DIR" \
  --output reports/p1/native-app-round28.json
.venv/bin/python tools/verify_gui_observation.py \
  --observations private/p1-round28/gui-observations.json
.venv/bin/python tools/research_checks.py --game-dir "$GAME_DIR" --stage round28 \
  --artifact reports/p1/list-native-report.json --artifact reports/p1/list-helper-native-report.json \
  --artifact reports/p1/list-path-native-report.json --artifact reports/p1/list-binding-report.json \
  --artifact reports/p1/list-execution-report.json --artifact reports/p1/native-app-round28.json \
  --artifact reports/p1/gui-replay-round28.json
```

保留历史查询失败时可给第二次 review 加 `--attempts-file private/p1-round28/helper-attempts.json`。当前阶段下一步是核对三参数 `for` 的初始化、条件、更新与退出时点，再接入循环；仍需继续完成列表操作、区域比较、资源后端加固、画面演出、音频、分支和存档。

用户随后要求加速，优先命令行，直至完整运行后再继续 UI。因此 0.6.0 界面保持冻结，以上界面构建与回放只作为已完成的历史验证；后续按核心功能批次推进，复用已核对证据，不再逐个增量重复界面工作。GUI 观察若要再次执行，可导入自有研究副本、选择 startup.s，再按 GUI 报告 selected_sources 的顺序选择版本；这属于手动复现，不是上述摘要命令的功能。
