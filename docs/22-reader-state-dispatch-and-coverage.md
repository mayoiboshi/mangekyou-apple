# 22 — 片段读取、例程状态分派与覆盖缺口

2026-11-07，P1 第十一轮。继续只读静态研究，没有执行游戏，也没有实现等待调度器、播放器或界面。REA/Ghidra 版本继续使用 `toolchain-lock.json`，源程序 SHA-256 与 P0 清单相同。完整原生移植仍未完成。

## 默认交叉引用不能代表完整调用关系

起点是前一轮的命令分派入口 `0x6aacf8`。默认 REA/Ghidra 只观察到 `0x6bed0f` 和 `0x6d180b` 两处引用。跟入第二处，可见片段读取助手 `0x695a7c`；默认只列一处引用。

新增只读探针 `tools/reader_analysis.py`，在 PE32 的文件支撑可执行段内寻找两个目标的 **E8 字节候选**。它不实现通用反汇编器，不将任意匹配当成指令，更不执行候选。源文件、区间和五字节候选均有摘要，数量、文件大小、扫描字节和处理时间受限。

| 目标 | 默认引用数 | E8 字节候选数 | 未出现在默认引用中的候选 |
|---|---:|---:|---:|
| `0x6aacf8` 命令分派候选 | 2 | 7 | 5 |
| `0x695a7c` 片段读取候选 | 1 | 2 | 1 |

其中六个未列出的地址是 `0x6ab95d`、`0x6ac51e`、`0x6adb0c`、`0x6adbb7`、`0x6c9aef`、`0x6ac512`。对每个地址分别查询函数归属和原生指令，默认分析都报告没有包含函数、无法解码。28 项独立采集完成、错误 0、清理完成，**不代表 28 项功能均支持**；`reader-native-report.json` 保留 12 项默认覆盖缺口。

字节候选可能处于数据或另一条指令的操作数中。新增合成测试专门放入这种假阳性，确认探针仍给出 `instruction_boundary=not_tested`。没有将九个候选升级为完整调用图。`0x6ac512` 与 `0x6ac51e` 经下述独立窗口和分派表关联，获得更强的局部结构证据；其余候选的完整父函数和动态可达性尚未确认。

## 声明枚举与一个状态分派表对上

选定窗口从例程候选的 `+0x4c` 读取无符号字节，比较上限 10，再通过绝对索引跳表分派。读取 `TScriptRoutine.State` 的真实类型声明后，核对序号 0..10 与 11 个表项。跳表地址为 `0x6ac4c2`，长度 44 字节；越界分支指向 `0x6ac652`。守卫编码、表项原始字节、声明名和目标范围均单独检查。

| 值 / 声明名称 | 表项指向 | 本次观察到的主要调用目标 |
|---|---|---|
| 0 `ssPlay` | `0x6ac4ee` | `0x695a7c`、`0x6aacf8`，另有访问上下文的调用 |
| 1 `ssStopBrk` | `0x6ac528` | `0x6cae58` |
| 2 `ssStop` | `0x6ac534` | `0x6cad08` |
| 3 `ssWait` | `0x6ac559` | `0x6bb010` |
| 4 `ssClick` | `0x6ac57e` | `0x6bb010` |
| 5 `ssTimer` | `0x6ac5a3` | `0x6bafec` |
| 6 `ssSndTimer` | `0x6ac5c8` | `0x6bbb14` |
| 7 `ssMessage` | `0x6ac5e6` | `0x6baba0` |
| 8 `ssScroll` | `0x6ac5ff` | `0x6baba0` |
| 9 `ssButton` | `0x6ac618` | `0x6bed78` |
| 10 `ssWave` | `0x6ac636` | `0x6bac3c` |

表格中省略公共访问器，机器报告保留选定分支中的全部直接调用观察。若等待助手返回值满足选定分支条件，七条路径存在将 `+0x4c` 写零的直接指令；另外两条路径将该字段地址传给助手。字段实际对象绑定、条件可达性、助手的副作用及完整状态转移仍为 `inferred` 或 `not_tested`。

同一个助手用于两个状态，不证明它们的语义相同。不能合并 Wait/Click 或 Message/Scroll，也不能根据枚举中的 Timer、Wave 等名字直接实现时间线。当前输出是状态声明、分派表和调用编码的关系，**不是调度器**。

来源见 `reader-analysis-report.json.native_state_dispatch`。各表项和直接调用都有原始文件偏移、长度及区间摘要；表项绑定整体为 `inferred`，执行语义为 `not_tested`。本轮没有用人工函数入口或清理 RET 覆盖来伪造这些缺失父函数的完整反编译结果。

## 跳过标志与正文前处理

值为 0 的分支取当前控制块，比较 `+0x34` 与 5，以比较结果作为片段读取的标志，再把所得字符串交给命令分派。该阈值与上一轮的控制块跳过状态一致；完整祖先状态传播仍未证明。

对片段读取、行推进和行加载助手做了汇编交叉核对，形成以下限定结论：

- `reader_quote_delimiter_checks`：选定扫描路径比较引号与反斜线，切换引号标志，将分隔计数与 2 比较。不能仅靠任意反斜线切分全文；宽字符特殊路径、转义和所有畸形输入仍未恢复。
- `reader_label_gate_and_output`：非零标志绕过标签跟踪更新后，仍到达输出字符串赋值。这不是直接清空或丢弃整段正文的证明。
- `line_advance_load`：行推进调用 `0x69630c`；`line_preprocessor_order` 显示后者调用两个预处理函数，然后进入前缀判定链。两个预处理函数本轮尚未解释。
- `line_prefix_exclusions` 与 `line_prefix_field`：选定路径检查反斜线、空格、制表符、斜线和 @，并可能将对象 `+0x2c` 字段与当前行交给拼接候选函数。这个可配置前缀的赋值来源、空行默认项和全部文本转换仍未追溯。

因此更有依据的 **Hypothesis** 是：普通正文先经过处理，可能被配置的命令前缀包装，再进入片段与命令管线。不能把 P0 提取出的台词按序播放当成还原引擎，也不能让当前静态词法记录直接代替原引擎的运行输入。

报告的 `non_command_line_skip_paths`、`text_prefix_configuration`、`all_wait_semantics` 继续为 `not_tested`。本轮仍未证明完整正文跳过规则。

## dbrk 的局部范围缩小了

真实源码编号构造规则将 ASCII `dbrk` 对应到 `0x6b726264`。通用分派在选定入口先将处理标志置 1；`0x6b08d4` 比较该编号，匹配时直接跳到共享处理尾部。此处没有专门的 dbrk 操作体。九项指令事实中的三项分别记录初始标志、相等跳转与尾部门控，避免把跨度很大的路径压成一个未经核对的断言。

对 379 个副本重新哈希、词法解析，找到七个无参数 `dbrk` 记录，均有源位置及摘要。机器报告将它们关联到上述局部分派事实，但 `lexical_family_binding` 和 `global_execution_semantics` 保持 `not_tested`。这不证明全引擎无操作，也不把 dbrk 猜成普通 break、调试断点或跨例程返回。上一轮的历史报告仍保留当时未支持的七项关联。

## 解码成功与边界正确是两回事

初始宽窗口将状态跳表当成指令线性解码，在 `0x6ac4ea` 出现 Unknown；这 44 字节现已按有守卫的表项读取。原宽窗口继续保留在 `exploratory_windows`，状态为 `unsupported`，没有删去历史未知或把表数据解释为可执行指令。

此外，一次初选的返回窗口从 `0x6b1e2c` 开始，落在默认汇编已观察到的 `0x6b1e28` 五字节 CALL 操作数内部。虽然 LLVM 可以从那里连续解码，边界仍无效。最终窗口改为已观察续接 `0x6b1e42` 到返回指令之后，旧计划和输出继续保留；`preliminary_boundary_review.status=unsupported` 给出覆盖该错误起点的原指令引用。不能因为最终窗口解码覆盖为 `verified` 就抹去这次边界失败。

这也说明 E8 扫描只输出候选的必要性：能拼成机器指令，不等于处在实际指令边界，更不等于会运行。

## 复现与验证范围

变量由使用者指定，原始目录始终只读。真实输入缺失或摘要不同不能使用本轮固定地址计划声称兼容。

```sh
.venv/bin/python tools/rea_static.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-reader-plan.json --output private/p1-round11/native-reproduced \
  --rea-command "$REA_COMMAND" \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
.venv/bin/python tools/native_windows.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-reader-exploratory-windows.json --output private/p1-round11/windows
.venv/bin/python tools/native_windows.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-reader-preliminary-windows.json --output private/p1-round11/windows-reviewed
.venv/bin/python tools/native_windows.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-reader-windows.json --output private/p1-round11/windows-final
.venv/bin/python tools/review_native.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-reader-plan.json --facts docs/native-reader-facts.json \
  --evidence-dir private/p1-round11/native-reproduced \
  --windows-dir private/p1-round11/windows-final \
  --exploratory-windows-dir private/p1-round11/windows \
  --output reports/p1/reader-native-report.json
.venv/bin/python tools/reader_analysis.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" --assets-dir "$ASSETS_DIR"
.venv/bin/python tools/research_checks.py --stage round11 --game-dir "$GAME_DIR" \
  --artifact reports/p1/reader-native-report.json \
  --artifact reports/p1/reader-analysis-report.json
```

新工具复用既有安全打开、PE32、元信息、词法和时间上限辅助，不内嵌第三方实现；最多 8 个目标、128 个调用字节候选、32 MiB 可执行段扫描、32 个表项、8 KiB 分支区间、128 个 dbrk 记录。整个独立分析限 120 秒，失败写入私有错误报告。所有正文与原生代码视图仍在 Git 忽略目录，公开报告仅含声明名称、地址、统计和摘要。

新增 12 个自造 PE/表项测试：覆盖前后向 E8、嵌入操作数的假阳性、截断、计数及目标范围、守卫与枚举不一致、表项越界、源字节逐项校验。开发中的首次运行有两项因集合合并写法错误而报错，已修正并重新通过；这不是游戏格式失败，也没有修改上游或游戏数据来让测试通过。

最终结果见 `round11-tests.json` 与 `round11-readiness.json`。这些检查证明研究工具、报告限定和原始关键摘要的状态，不证明整作分支、等待、音画或存档兼容。下一轮优先追溯前缀赋值与两个行预处理助手，再核对等待助手的条件、时间来源和结果状态恢复；仍不具备宣布原生移植完成的证据。

本轮研究环境 200 项通过；系统 Python 197 项通过、3 项可选集成检查因环境条件跳过；上游 26 项通过、8 项商业夹具检查跳过。跳过不计入通过。20 个已有摘要的原始关键文件保持一致，冻结 P0 报告与本轮开始前快照一致；没有将该抽样完整性检查外推成所有文件逐字节复核。
