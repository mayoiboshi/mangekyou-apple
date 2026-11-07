# 17 — 基本值格式与空字段取证

2026-11-07，P1 第六轮。仍限静态研究，不实现表达式执行器、游戏引擎、播放器或界面。新增整数格式假设模型、原生证据摘要，以及 `$` 字面量的结构识别。

## 环境与证据范围

重启后通过当前 MCP 连接实际读取了 14 项 REA/Ghidra 原生观察。REA 6.8.0、Ghidra 12.1.4 和 ARM64 原生反编译器可用；SDKMAN 安装的 Microsoft Java 21.0.13.0.2 已实际运行确认。REA 配置固定 `JAVA_HOME`，SDKMAN 全局默认 Java 8 保持不变。安装来源、版本和许可见 `toolchain-lock.json`；没有为此升级其他依赖。

主程序候选仍以 P0 摘要和 `native-scalar-plan.json.source_sha256` 双重固定。目录内带汉化及补丁，不能证明它是纯净原版。下列结论只适用于这个摘要对应的文件。

`scalar-report.json` 区分以下证据：

- `queries`：固定选择器的原生观察、输出摘要及工具版本；完整伪代码与汇编留在 `private/`。
- `machine_facts`：7 项 `verified` 的静态指令观察，附相对文件名、原始 EXE 的 offset、length、SHA-256 和 REA evidence ID。
- `inferred_contracts`：4 项字段意义或行为解释，全部保留 `inferred`。
- `synthetic_format_examples`：18 个自行构造的格式输入及模型输出，不能冒充商业样本在原代码中的执行结果。

`tools/scalar_analysis.py` 要求证据的目标摘要、操作、选择器和提供方相符，也要求指定指令观察存在；缺失时明确失败，不生成成功结论。公开摘要不包含原始伪代码、游戏台词、参数正文或完整资源。

## 数值路径

值解析候选函数 `0x69af88` 的指令观察显示：未解析描述符先检查首个 UTF-16 单元。`$`、`-`、`+` 和 ASCII 数字可进入 `0x415aa8`；转换报告成功后设置 tag 0，并写入偏移 4 的 32 位字段。双引号路径设置 tag 1，并经 `0x415a90` 填充同一数值字段，调用时提供的失败回退参数为 0。tag 及字段赋值是静态事实；“数值”“字符串缓存”等名称是解释。

`0x415aa8` 调用 `0x404ffc` 并检查错误位置输出是否为 0。对 `0x404ffc` 的汇编和伪代码交叉阅读支持如下 **Hypothesis**：

| 格式或边界 | 当前模型 |
|---|---|
| 十进制 | 有符号 32 位，`-2147483648` 至 `2147483647` |
| 十六进制前缀 | 核心帮助函数接受 `$`、`x`、`X`、`0x`、`0X` |
| 十六进制结果 | 保留完整 32 位；`$FFFFFFFF` 的位模式为 `0xffffffff` |
| 前导符号 | 一个 `+` 或 `-`；十六进制负号按 32 位取负解释 |
| 空白 | 核心只跳过前导 ASCII 空格；不接受尾随空格 |
| 超长前导零 | 按累积值判断，不能简单用数字位数拒绝 |
| 非法输入 | 不产生默认数值；保留拒绝原因 |

核心帮助函数的支持范围不等于脚本字面量语法。例如 `xA` 和前导空格可进入核心模型，但不满足值解析候选函数的原始首字符门槛；前置 tokenizer 是否改变输入需要另行核对。`+xA` 满足门槛也不代表整个脚本表达式已确认可用。

`tools/integer_format.py` 是脱离游戏执行的纯格式模型，只处理一个数值文本，不求值表达式，不读写变量。长度上限 8,192 字符；内嵌 NUL 保留 `not_tested`，没有冒充原帮助函数的 NUL 终止行为。模型输出同时记录 `bits_u32` 和 `signed_i32`，避免无说明地套用宿主语言的任意精度整数。全部正常模型结果仍是 `inferred`，原代码执行等价性为 `not_tested`。

## 运算与类型风险

原表达式核心 `0x69bab4` 的候选反编译视图在内部字符 `0x38` 路径调用 `0x69a948`，与第五轮 `*8` 标签映射交叉对应。该帮助函数在双方 tag 为 0 的路径使用 32 位 ADD，随后直接跳转，无溢出异常分支；这一局部指令事实不能外推所有运算的错误规则。

前置函数 `0x69daac` 只检查双方是否为 tag 4，没有建立通常编程语言的统一类型转换规则。`0x69a948` 对相同与不同 tag 分别处理；不同 tag 时两个字段均有更新。因此尚不能把原行为替换成 Python、Swift、Rust 或 C++ 默认的字符串/数字转换。字符串字段的内存和复制契约、变量生命周期、赋值引用、下标、除零及逻辑短路仍未确认。本轮没有实现这些运算。

## 空字段与真实覆盖

`cal` 处理点 `0x6b02b7` 比较取出的参数指针；零值分支跳到 `0x6b030d` 的下一字段处理，绕开 `0x6b02dc` 的求值调用。这是静态观察。**研究副本中的空文本字段是否恰好构造该零指针仍为 `inferred`，没有执行原程序验证。**

结构词法新增 `$` 加完整十六进制单词的候选识别；`$Background`、`$ColorName` 等不会被部分吞成数字。对全部 379 份文本副本重新扫描后：

| 范围 | 第五轮历史结果 | 第六轮结果 |
|---|---:|---:|
| 候选字段 | 8,130 | 8,130 |
| 候选 AST | 8,126 | 8,128 |
| 未支持字段 | 4 | 2 |
| AST 节点 | 37,312 | 37,322 |

剩下两项是同一逻辑文件在两个包版本中的空 `cal` 字段，继续以 `unsupported` 保留原始位置、范围摘要和原因，没有替换为 0 或静默删除。8 个没有表达式字段的零参数 `for` 记录继续单独列出。数字浮点/指数形状仍只是词法候选，整数帮助函数没有证明它们是有效脚本字面量。

本轮完整 AST 和独立来源核对写入 `private/p1-round6/ast/` 及 `ast-source-audit.json`。公开报告为 `expression-round6-report.json`、`operator-round6-report.json`；第五轮历史报告保留。更新后的解析器再次执行第五轮命令会得到更新后的候选覆盖，历史计数不是当前源码的固定预期。

## 独立复现

前提是已有合法导入的 P0/P1 研究副本及第三轮原生证据。输入目录由使用者提供；所有原生操作仅静态读取，不启动目标程序。

```sh
.venv/bin/python tools/rea_static.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-scalar-plan.json \
  --output private/p1-round6/native-reproduced \
  --rea-command "$REA_COMMAND" \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
.venv/bin/python tools/scalar_analysis.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --native-dir private/p1-round6/native-reproduced
.venv/bin/python tools/expression_analysis.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --assets-dir private/real-assets --private-dir private/p1-round6 \
  --expression-report reports/p1/expression-round6-report.json \
  --operator-report reports/p1/operator-round6-report.json
.venv/bin/python tools/research_checks.py --stage round6 \
  --game-dir "$GAME_DIR" \
  --artifact reports/p1/scalar-report.json \
  --artifact reports/p1/expression-round6-report.json \
  --artifact reports/p1/operator-round6-report.json
```

本轮 `tests/test_integer_format.py` 新增 13 项测试，覆盖有符号边界、完整十六进制位模式、前缀与调用门槛的区别、前导零、空白、非法输入不归零、限制、原始字节映射、脱离原代码执行的置信度，以及原生观察缺失时拒绝生成事实。最终测试数量、跳过项和完整性以 `round6-tests.json`、`round6-readiness.json` 为准；跳过不计通过。

实际独立取证 14 项均成功、错误 0、分析进程关闭成功；与当前 MCP 所获 14 个 evidence ID 全部相同。研究环境 131 项测试通过；系统 Python 128 项通过、3 项可选检查跳过；上游 26 项通过、8 项商业夹具检查跳过。20 个已有摘要的原始关键文件保持一致，冻结 P0 报告与本轮开始前快照完全一致。这不是全部游戏内容的执行或完整性认证。

下一步仍应核对赋值/下标的引用与生命周期、参数传递和条件分支契约。需要原生运行时开发前，先解决当前工作范围约束；本轮不宣布完整 P1 或原生移植完成。
