# 21 — 状态声明、控制块关联与命令门控

2026-11-07，P1 第十轮。只读核对第四作主程序候选及已有研究副本，未运行游戏、未实现脚本解释器。完整原生移植仍未完成。输入程序沿用 `program-probe.json` 中的 SHA-256，不能据此认证纯净发行版。

## 声明事实与行为分开记录

`delphi_metadata.py` 新增受限枚举头读取，格式参考 Delphi 官方 [TTypeData](https://docwiki.embarcadero.com/Libraries/Athens/en/System.TypInfo.TTypeData) 的序数类型、范围、基类型引用和名称表。文档修订号为 316431；只研究格式，没有复制 RTL 实现。当前二进制布局通过自身引用、值域、逐项短字符串和实际字节范围核对，不能从官方页面直接推定本程序编译器版本。

探针只接受本次观察到的自基类型枚举，最多 256 项；拒绝反向范围、超大范围、非自身基类型和重名符号。报告中声明字节为 `verified`，元信息布局解释为 `inferred`，执行语义为 `not_tested`。

`TScriptBlock.State` 的声明偏移为 `+0x34`，类型信息地址为 `0x6a7250`。十二项名称和值如下，**这些名字本身不证明执行语义**：

| 值 | 声明名称 | 本轮候选结构关联 |
|---:|---|---|
| 0 | `rsNone` | 初始化写入；不建立脚本块关联 |
| 1 | `rsSub` | 第二分派中的写入；调用语义仍未闭合 |
| 2 | `rsIfThen` | if 家族 |
| 3 | `rsForThen` | for 家族 |
| 4 | `rsSwitchThen` | case 家族 |
| 5 | `rsIfSkip` | if 家族 |
| 6 | `rsIfElse` | if 家族 |
| 7 | `rsForSkip` | for 家族 |
| 8 | `rsForBreak` | for 家族 |
| 9 | `rsForContinue` | for 家族 |
| 10 | `rsSwitchSkip` | case 家族 |
| 11 | `rsSwitchElse` | case 家族 |

`TScriptRoutine.State` 的另一个声明枚举有 11 项：`ssPlay`、`ssStopBrk`、`ssStop`、`ssWait`、`ssClick`、`ssTimer`、`ssSndTimer`、`ssMessage`、`ssScroll`、`ssButton`、`ssWave`。这里只记录声明，不从名称生成等待、点击或声音调度实现。

来源见 `reports/p1/state-enum-report.json` 各类 State 字段的 `type_info.enum_header`；每个成员均有源文件摘要下的偏移、长度和区间摘要。访问累计 7,336 字节，包含重复读取，不是唯一区间总大小。上一轮未解析的签名、缺少类型引用和一处虚槽差异仍保留，未因枚举支持而消失。

## 选定原生指令支持的结论

六项 REA 查询由独立命令重新采集并完成清理，公开报告保留 10 项有序指令事实及 4 项 `inferred` 契约。原始汇编和伪代码只在 `private/p1-round10/`。事实定义见 `native-control-state-facts.json`，每项通过 `control-native-report.json.observations` 定位原始字节与 Evidence ID。

1. `ancestor_threshold`：`0x6bb098` 以无符号比较检查控制块状态是否达到 5，满足时置外层标志。`skip_overrides_handled`：尾部可以将处理结果由 0 改为 1。`caller_control_gate`：调用者检查返回的 AL，非零时绕过第二分派调用。由此形成“外层跳过参与命令门控”的假设，尚未核对非命令正文的跳过路径。
2. `then_compare_and_state` 与 `if_compare_and_state` 使用 `0x6bb9a4`；`else_compare_and_state` 使用 `0x6bba58`。原文件对应的四字节 UTF-16LE 常量分别确认为 `1` 和 `0`，证明范围仅限常量字节。比较路径对状态 2/6 或 4/11 分别赋值，不能替换成宿主语言的一般非零判断。
3. `for_exact_one_states` 将局部整数与精确的 1 比较，然后写状态 3 或 8；`parent_skip_distinct_states` 的另一创建路径写状态 7。由声明名称及指令可知，必须保留条件不成立和外层跳过的区别。完整循环转移仍为 `inferred`。
4. `loop_update_before_condition` 先以选项 `+0x18` 调用表达式函数，再使用 `+0x14`，随后与 1 比较并可能恢复位置。更新/条件含义沿用表达式及元信息证据形成假设；副作用、异常、全部入口和回滚没有执行验证。
5. `if_numeric_tag_and_assignment_flag` 保留标志检查和诊断调用；没有因为看到诊断函数就声称其一定终止执行。

新的扫描器只认已审阅的 x86 `C6 /0`、`+0x34`、立即字节存储编码。来源是选定函数反汇编中的指令边界，不在任意原始数据中搜字节模式。每项重新核对原 EXE 编码后才记录声明名；对象身份仍为 `inferred`。共 21 项：控制分派 17、第二分派 3、初始化 1。所选观察中未知存储为 0，**不代表覆盖所有状态写入**。动态值、其他修改指令或枚举外数值都保留为 `unsupported`。

## 清理后返回路径

默认视图在 `0x6bb984` 的清理 RET 结束，未展示后续值返回。独立窗口观察到前面的 `PUSH 0x6bb98c`，以及续接处 `0x6bb98c` 读取局部处理标志至 EAX、恢复寄存器并在 `0x6bb996` 返回。

三个线性窗口中，调用者较宽窗口在 `0x6aaed1` 出现未知解码。该地址不在本轮调用门控事实的 `0x6aae14..0x6aae2f` 内，仍完整保留在 `linear_windows`，总体线性解码覆盖为 `unsupported`。没有将后续线性解码结果当成实际可执行路径，也没有缩短窗口来隐藏未知。

继续复用既有受限模型工具：自造正例与错误续接反例通过后，仅在一次性数据库中将该清理 RET 的正常流连向已审阅续接。真实源内存摘要前后一致，派生视图出现返回值。`control-flow-model-report.json` 的 `experiment_status` 和 `decompiler_model_recovery` 为 `verified`，整体模型仍为 `inferred`；异常展开和与原引擎执行等价为 `not_tested`。没有修改原文件或据伪代码编写解释器。

## 真实脚本中的可追溯关联

对 379 个已有副本重新词法解析并核对全文摘要，没有直接信任旧缓存中的命令或参数。既有候选语法仍是 if/for/case 与 end 配对，并不是已经证明的引擎语法。

| 项目 | 数量 | 当前证明范围 |
|---|---:|---|
| if 候选块 | 2,137 | 同文件词法边界及状态家族假设 |
| for 候选块 | 377 | 同上 |
| case 候选块 | 125 | 同上 |
| then / else 标记 | 2,121 / 357 | 最近匹配家族的词法关联 |
| of / ans 标记 | 408 / 69 | case 家族的词法候选 |
| brk / cnt 标记 | 24 / 17 | 最近 for 家族的词法候选 |
| dbrk | 7 | 无已审阅关联规则，`unsupported` |

共 2,639 个候选块、2,996 项 `inferred` 标记关联，另有 7 项未支持记录。候选配对未发现语法问题；不能据此宣称动态跳转、包含文件或异常情况下的栈匹配全部正确。各标记都明确 `execution_target=not_tested`，不能把“最近词法块”当成实际运行目标。块名不是资源路径，不生成臆测的背景/语音边。

完整关系在被 Git 忽略的 `private/p1-round10/control-links.json`，公开 `control-state-report.json` 只保留统计、脱敏实例和失败原因。保留其余命令及非命令记录的排除计数，避免把结构分析范围误当成全文执行覆盖。`dbrk` 不因为词面相似就归入普通 break。

## 独立重现

环境变量均由使用者指定；代码和计划不包含本机游戏绝对路径。需已有合法受限研究副本及固定版本 REA/Ghidra，不能从命令成功推断游戏可玩。

```sh
.venv/bin/python tools/delphi_metadata.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --output reports/p1/state-enum-report.json
.venv/bin/python tools/rea_static.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-control-state-plan.json \
  --output private/p1-round10/native-reproduced \
  --rea-command "$REA_COMMAND" \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
.venv/bin/python tools/native_windows.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-control-windows.json --output private/p1-round10/windows
.venv/bin/python tools/ghidra_tail_probe.py --synthetic \
  --private-dir private/p1-round10/flow \
  --ghidra-dir "$GHIDRA_INSTALL_DIR" --java-home "$JAVA_HOME"
.venv/bin/python tools/ghidra_tail_probe.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-control-flow-plan.json \
  --private-dir private/p1-round10/flow --public-report control-flow-model-report.json \
  --ghidra-dir "$GHIDRA_INSTALL_DIR" --java-home "$JAVA_HOME"
.venv/bin/python tools/review_native.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-control-state-plan.json --facts docs/native-control-state-facts.json \
  --evidence-dir private/p1-round10/native-reproduced \
  --windows-dir private/p1-round10/windows \
  --output reports/p1/control-native-report.json
.venv/bin/python tools/control_state_analysis.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" --assets-dir "$ASSETS_DIR"
.venv/bin/python tools/research_checks.py --stage round10 --game-dir "$GAME_DIR" \
  --artifact reports/p1/state-enum-report.json \
  --artifact reports/p1/control-native-report.json \
  --artifact reports/p1/control-flow-model-report.json \
  --artifact reports/p1/control-state-report.json
```

新增 4 个枚举测试和 15 个状态/关联测试，不含商业数据：覆盖非自基类型、范围、重复符号、编码一致性、可执行段检查、未知数值、动态存储、指令边界、嵌套家族选择、未知命令、公开元数据脱敏和处理时限清理。扫描命令在支持的 POSIX 主机上限制为 120 秒，失败尝试写入私有错误报告并以退出码 2 结束。计数与跳过原因见 `round10-tests.json`，原始关键文件摘要及冻结 P0 检查见 `round10-readiness.json`；跳过不算成功。

本轮研究环境 188 项通过；系统 Python 185 项通过、3 项因 Python 版本及可选集成依赖跳过；上游 26 项通过、8 项商业夹具检查跳过。已核对的 20 个原始关键文件摘要与 P0 清单一致，冻结 P0 报告也与本轮开始前逐字节摘要一致。这个完整性检查不等于对所有游戏文件重新哈希。

下一步最合理的范围仍是静态核对非命令正文如何受跳过状态约束、dbrk 和跨例程转移的状态传播，以及等待/事件/结果恢复关系。完整控制流、音画时序、存档恢复和整作可玩性没有得到验证，目前不建议据这些结果直接开发完整运行时。
