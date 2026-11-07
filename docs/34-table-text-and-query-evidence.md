# 34 — 表对象、文本载入与查询的静态证据

本轮按用户最新提供的约束只做静态研究，不继续扩展引擎、播放器或界面。此前原生 0.3.0 的真实片段停在 `table` 声明；本轮没有改变该运行支持范围。仓库中尚未接入执行路径的 `ScriptTable.swift` 草稿虽有此前编译日志，**没有专项执行验证，不作为本轮成果或完整应用支持**。

## 证据身份与等级

研究对象仍是 P0 清单中主程序候选 `美少女万華鏡４.exe`，SHA-256 为 `ad02b1115887b8e5b453d4b5760077e8b63e153bba1161e1704209cf3db5cda5`。用户提供的目录含补丁、汉化程序，纯净发行版身份为 `not_tested`。未执行任何游戏 EXE、DLL 或存档程序。

`docs/native-table-plan.json` 固定 35 个查询；`native-table-facts.json` 定义 20 项逐地址、保序的指令锚点。独立 REA/Ghidra 采集结果在 `private/p1-round23/native-reproduced/`，脱敏摘要为 `reports/p1/table-native-report.json`。采集、清理和前后原文件摘要检查成功，指定事实缺失数为零；这只验证选定观察，不代表全部函数、全部表命令或执行语义已恢复。

以下等级必须分别理解：

| 对象 | 状态 | 范围 |
|---|---|---|
| 所列机器指令、字面量和类型声明的字节 | `verified` | 仅指定程序摘要与范围 |
| 载入、查找和结果写入的组合契约 | `inferred` | 由调用链形成的 Hypothesis，未运行原程序 |
| 静态脚本到资源、配置行的关联 | `inferred` | 仅字面量与有限直线顺序的候选 |
| 无匹配行的关联、默认函数识别缺口 | `unsupported` | 明确留存原因，不计作兼容成功 |
| 原版查询返回值、整作运行、时序与存档 | `not_tested` | 没有相应执行证据 |

## 对象与载入链

`table_analysis.native_bindings` 只读核对以下声明和指针，报告内保留文件相对路径、源摘要、offset、length 和范围摘要：

- `TImoObjectDataFastStringList`，VMT `0x6889b4`，声明实例大小 32，`obj` 字段偏移 24。
- `TFastStringList`，VMT `0x562d00`，声明实例大小 16，`FList` 偏移 4，`FNoneOptimize` 偏移 8。
- 工厂的 `table` 字面量参数、类指针单元、到构造器 `0x68f1e8` 的直接调用；构造器写对象类型字节 `0x24` 并保存列表。类型分派表的 36 号条目到处理器 `0x6cdd34` 另按原始字节核对。

`load_command_branch` 和 `load_stream_then_clear` 显示，编号 `0x6c` 的分支在取到非空资源流后，清除对象中的列表，再调用 `0x563a68`。汇编明确从 `[EBP-0x20]` 取列表指针，不能采信反编译中复用临时量造成的“传入零指针”表示。读取失败后的全部恢复、异常时列表是否保留部分修改，仍未知。

`stream_virtual_load`、`stream_line_bridge` 和 `line_loader_order` 连接了临时 `TStringList`、虚拟流读取与 `0x563b80`：先清除目标列表，逐行取得名称，非空名称再通过名称查值，而不是直接拿当前行的值；然后过滤、处理空值标记、写入目标列表。

已核对 `//`、`%%none%%`、`ResultStr`、`ResultInt` 的 UTF-16 字面量及长度。`slash_filter` 对名称和值均调用同一查找助手，正位置绕过真结果；结合行载入的调用顺序，形成“整项过滤”假设，不能当成去掉行尾注释。`marker_null_branch` 的等值路径将标记转为空字符串输入。`empty_optimization_gate` 显示空值是否实际保留受 `FNoneOptimize` 影响，故报告不把候选数宣称为原程序存储项数。

## 默认函数覆盖缺口

默认分析对 `0x68f2a0`、`0x68f2f0`、`0x43da78` 均明确返回没有包含函数。本轮保留这三个 `unsupported` 结果，用 LLVM 单独读取 4 个窗口补充观察：

- 表初始化 `0x68f2f0..0x68f306`。
- 属性方法 `0x68f2a0..0x68f2d0`，截止实际 RET 之后，排除后面的字符串数据。
- 名称索引循环 `0x43da78..0x43db40`。
- 清理后的正常返回 `0x43db42..0x43db4b`，将候选索引装入 EAX 后返回。

窗口边界为人工选择，整体状态 `inferred`；指定窗口内没有解码未知或越界，不等于已恢复完整函数。索引循环从零开始，比较相等即退出；比较本身是虚拟调用，不能据此宣布完整 Unicode、区域设置或大小写规则一致。

初次属性窗口误把尾随数据纳入线性反汇编，出现 2 个未知地址和 1 个跨界指令；原记录保留在报告的 `exploratory_windows`，没有改写为成功。另有一次对空 token 调用 `lower()` 的元数据过滤错误，修正后重计，记录在 `historical_failed_lookups`；它不是游戏兼容性失败或成功。

辅助调查另以 `native-table-helper-plan.json` 固定 6 项独立观察和 3 项指令事实，摘要为 `reports/p1/table-helper-native-report.json`：

- `0x407f10` 的原始指令包含逐 UTF-16 字扫描、余下字比较、失败后继续扫描，以及零值/位置两类返回路径，补强“任意位置子串”过滤假设（`slash_word_scan`、`slash_zero_or_position`）。
- `0x41de2c` 是位置包装路径，委派 `0x416b2c`，把非零指针转换成从一开始的字索引。委派助手与全部返回/异常路径仍未恢复（`name_position_pointer_index`）。
- 默认分析还未识别名称比较 `0x43ef14`、流读取包装 `0x43dc60`。先前直接反编译/读取汇编的 4 次错误原样保留于私有 RPC 记录；改用显式包含函数查询，取得两项否定观察，再以 3 个有界 LLVM 窗口补查，未改上游或伪造函数。
- 比较窗口 `0x43ef14..0x43ef2e` 检查对象 `+0x2a`，选择 `0x414d5c` 或 `0x414e28`；类型声明将该字段命名为 `FCaseSensitive`。字段初始化和比较助手的区域设置行为未验证，因此静态工具的 ASCII 比较仍是 Hypothesis。
- 流包装窗口 `0x43dc60..0x43dc6a` 将 ECX 置零并转交虚拟槽 `+0x74`，对应 `0x43dc6c`。另一个窗口截至其正常返回 `0x43dd5e`，可见流读取后调用 `0x4219a8`、`0x4224d0` 并经虚拟槽 `+0x2c` 写入文本。这里只记录调用链；未据函数名称猜测编码，编码选择继续 `not_tested`。

主调查与辅助调查合计 41 项独立观察、23 项指定事实、7 个最终窗口、5 个默认函数识别缺口；不包含初次失败查询作为成功项。

## 查询路径与结果变量

`query_command_branch` 对应 `0x763f` 的所选分支。`query_default_pair` 显示默认字符串和整数先置空/零；第二字段存在时，以求值描述符的字符串、整数两部分覆盖默认值。

`get_missing_null`、`query_missing_results`、`query_found_results` 显示：查找字符串为空指针时写默认结果；非空时写找到的字符串，并将其和默认整数交给 `0x415a90` 后写整数结果。两个分支均以相同参数调用 `0x6c1be4`，**不能凭该调用创造“找到/未找到”的布尔寄存器**。

两个结果写入包装器都从上下文 `+0xe8` 调用 `0x69f278`，再分别调用整数/字符串设置器（`result_integer_storage`、`result_string_storage`）。结合之前的类别存储证据，可形成全局结果变量的候选；重名遮蔽、权限、结果恢复、对象销毁及所有异常 ABI 仍未建立完整执行契约。

## 真实配置副本与静态引用

新工具 `tools/table_analysis.py` 不创建引擎对象，不运行查询，不输出配置名称、值、完整参数或正文。它按固定 corpus 清单检查摘要，只分析明确选定的两份 `misc/value.s`，保留全部资源版本：

| 副本 | 编码识别 | 行数 | 形态统计 |
|---|---|---:|---|
| data7 的 avg/setting.txt | CP932，编码选择 `inferred` | 211 | 143 空白行、65 个非空值、3 个空值 |
| data8 的 avg/setting.txt | UTF-16LE BOM，`verified` | 211 | 同上 |
| data7 的 avg/projectsetting.txt | CP932，编码选择 `inferred` | 36 | 36 个非空值 |
| data8 的 avg/projectsetting.txt | UTF-16LE BOM，`verified` | 36 | 同上 |

四份副本都没有 ASCII 归一后的重复名称。每份 projectsetting 有一行名称或值带外部空白，工具保留其字节和空白标志，不自动 trim。其他同形文本未因扩展名而纳入表解析结论。

两份脚本合计：2 个表声明候选、46 个 `scp` 选择候选、4 个 `l` 载入候选、42 个 `?v` 查询候选。默认字段形态为 20 个省略、16 个规范整数字面量、6 个简单字符串字面量。这只是源字段形态，绝不等于已求值。

工具将有限直线顺序中的声明/选择/载入提示关联起来，再按 ASCII 字面键查文本行，生成 84 条带版本条件的引用：80 条有配置行候选，4 条没有受支持的行匹配。4 条保留 `unsupported` 及原因；**没有匹配不证明原引擎查询失败，有匹配也不证明该行会被执行使用**。每条关联可以定位查询记录、之前的载入记录、具体文本副本和候选行。资源类型统一保持 `Unknown`，没有将这些配置引用冒充背景、立绘或音频引用。

假设比较仅限 ASCII；非 ASCII 键、动态文件名、动态键、无已知表选择、分支/调用打断、语料中缺少目标，都保留未知或未支持。分支、调用和标签会清除直线顺序的载入提示。实际资源覆盖优先级、包含展开、替换生成的命令及运行可达性继续 `not_tested`。

## 自建测试与复现

`tests/test_table_analysis.py` 使用自建数据覆盖首个重复值先过滤、`//` 出现在任一字段、标记与空值、额外等号、空白保留、CP932/UTF-16 字节位置、非 ASCII 键、畸形编码、大小/行数上限、越界路径、符号链接、摘要不符、所有版本保留、未知关联和正文脱敏。它验证研究工具的行为，不能作为原引擎对照测试。

本轮新增 14 项测试。完整检查见 `reports/p1/round23-tests.json`：系统 Python 308 项通过、3 项跳过；研究环境 311 项通过、零跳过；固定上游 26 项通过、8 项缺少商业 fixture 的测试跳过。跳过均未计作通过。`round23-readiness.json` 核验关键原文件摘要及检查期间 P0 报告不变；另外与 `private/p1-round23/p0-before.json` 对比，本轮开始时的冻结 P0 快照也一致。检查通过只代表本轮研究工具和报告检查通过，`runtime_development_ready` 仍为 false。

独立采集、窗口和摘要重建（变量值由调用者提供，不在工具内硬编码）：

```sh
.venv/bin/python tools/rea_static.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-table-plan.json --output private/p1-round23/native-reproduced \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
.venv/bin/python tools/native_windows.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-table-windows.json --output private/p1-round23/windows
.venv/bin/python tools/review_native.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-table-plan.json --facts docs/native-table-facts.json \
  --evidence-dir private/p1-round23/native-reproduced \
  --windows-dir private/p1-round23/windows --output reports/p1/table-native-report.json
.venv/bin/python tools/rea_static.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-table-helper-plan.json --output private/p1-round23/helpers-confirmed \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
.venv/bin/python tools/native_windows.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-table-helper-windows.json --output private/p1-round23/helper-windows
.venv/bin/python tools/review_native.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-table-helper-plan.json --facts docs/native-table-helper-facts.json \
  --evidence-dir private/p1-round23/helpers-confirmed \
  --windows-dir private/p1-round23/helper-windows --output reports/p1/table-helper-native-report.json
.venv/bin/python tools/table_analysis.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" --assets-dir "$ASSETS_DIR" \
  --script-file data7.pack/misc/value.s --script-file data8.pack/misc/value.s
.venv/bin/python tools/research_checks.py --game-dir "$GAME_DIR" --stage round23 \
  --artifact reports/p1/table-native-report.json \
  --artifact reports/p1/table-helper-native-report.json \
  --artifact reports/p1/table-analysis-report.json
```

历史失败记录和探索窗口可额外传给 `review_native.py` 的 `--attempts-file`、`--exploratory-windows-dir`；它们不会把失败覆盖成成功。初次辅助查询计划单独保留为 `native-table-helper-initial-plan.json`，可复现当时未识别函数的失败，而不是重写最终计划制造通过。不运行会重写冻结 P0 的旧总复现命令。

工具正常生成报告的退出码零不表示全部关联或格式兼容；须查看 `issue_count`、`unknown_reasons`、每行和每条关联的状态。若输出路径安全而输入校验失败，会写 `unsupported` 失败报告；输入输出重叠等不安全路径会拒绝任何写入并输出 JSON 错误。

## 下一步

继续静态追踪流解码调用 `0x4219a8` / `0x4224d0`、比较调用 `0x414d5c` / `0x414e28`、空值优化标志的初始化/写入、结果辅助状态，以及未匹配查询是否依赖动态生成或其他载入。当前证据可支撑后续有界契约设计，尚不支持宣布表对象完整兼容，更不能据此宣布游戏可运行。若以后恢复应用开发，仍需单独验证对象生命周期、作用域、真实资源版本选择、异常恢复和运行轨迹，并解决可分发 PACK 后端、演出、音频、分支与存档等缺口。
