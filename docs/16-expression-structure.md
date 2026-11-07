# 16 — 表达式处理组与可追溯结构树

2026-11-07，P1 第五轮。新增有边界限制的表达式结构解析器，仍不执行表达式，不修改变量，不展开宏，也不实现游戏解释器。完整原生移植继续进行。

## 证据层次

`expression-operator-plan.json` 固定了当前 EXE 中 19 个内部运算符 tag 的字节位置。`tools/expression_analysis.py` 重新核对 EXE 与 P0 的摘要，读取两字符 UTF-16 tag 及终止符，并核对原有 REA tokenizer 证据中存在相应的常量引用。

`operator-report.json` 分开记录：

- `literal_status=verified`：实际字节及其位置已读到且与固定计划一致。
- `mapping_status=inferred`：源符号到内部 tag 的解释，依据的是分词函数中的分支与引用。
- 分组顺序及左结合处理是有源码观察支持的解析模型，尚不代表所有表达式执行语义已确认。

依据 `0x69b684` 的顺序处理组，以及 tag 的实际字节，当前模型从高到低为：

1. `* / %`
2. `+ -`
3. `<< >>`
4. `^ & |`
5. `== != <= >= > <`
6. `&& ||`
7. `=`

其中 `&&` 与 `||` 在同一组，三种位运算符也在同一组。因此直接使用 C 或 Python 的表达式解析器会引入未经证实的规则。当前解析器显式保留这个组表；处理组不等于已证明短路行为、数值类型或溢出策略。

## 函数模型的扩展与失败记录

本轮把第四轮的临时数据库方法扩展到：

- tokenizer 候选 `0x69c600`；
- 处理组候选 `0x69b684`；
- 归并帮助函数 `0x69b580`。

首次尝试要求函数地址跨度内每个字节都组成连续指令，两个区域因此被拒绝：一个清理区后续位置被识别为数据，另一个区域包含 switch 数据。失败完整保存在 `private/p1-round5/failed-linear-model/`，没有修改游戏或上游来制造通过。

包装器现改为保留已有代码/数据定义，沿受限控制流分析入口，只对明确指定的正常流后续尾部补充指令。扩展函数体时保留原来的地址集合，追加尾部，不把整个含数据的跨度强行改成代码。合成正例和错误后续地址反例重新验证后，三个真实候选的受约束模型均可生成反编译视图；选定内存范围与原文件摘要未变。

归并帮助函数确实是无值返回的候选，因此计划显式写 `expects_value_return=false`，不能为了通过检查而给它编造返回值。其他两个计划要求值返回。报告整体仍为 `inferred`，完整执行等价性为 `not_tested`；原始/派生伪代码只保存在 `private/`。

这些是同一临时数据库内按计划顺序进行的局部对比。后一个函数的基线可能处于已有前一个函数元数据改动的数据库中，不能当成整个数据库从未改动的全局基线。所有改动均为分析假设，原始机器指令证据继续独立保留。

## 结构解析器

`tools/qlie_expr.py` 提供词法 token 和候选 AST，支持当前模型中的二元运算、括号、`+ - ^` 前缀形状、下标以及后缀 `++/--` 形状。后缀更新只保留结构及未确认的副作用说明，不执行更新；函数调用、未经证实的前缀及未知字符显式拒绝。

字符串使用双引号；反斜线保持字面内容，不套用 C 转义。数字和标识符都只是候选形状，不做数值转换、类型推断或名称查找。单个字段最多 8,192 字符、1,024 token、64 层树深；整体最多 100,000 节点及 20,000 字段，超过限制生成明确失败或拒绝。

每个节点关联研究副本的相对文件名、文件摘要、字节偏移、长度和范围摘要。UTF-16 非 BMP 字符及 CP932 别名通过原始解码跨度定位，不通过重新编码计算位置。偏移属于**解码后的研究副本**，不是压缩 PACK 的字节位置；PACK 来源可通过 `corpus-report.json.items[].origin` 追溯。

完整树含正文、字符串和变量名称，仅写入忽略的 `private/p1-round5/ast/`。公开示例将所有原子值替换为摘要，只保留结构、运算符、位置和置信度；每个候选节点的执行语义继续是 `not_tested`。

## 实际覆盖和未支持项

输入保留全部 379 份文本副本，没有用第三轮的条件赢家视图删除其他版本。本轮只选 `cal`、`if`、`for`、`case` 的操作数字段；其他命令的排除计数也进入报告，不能把这个覆盖范围说成游戏的所有表达式。

| 范围 | 实际数量 |
|---|---:|
| 候选表达式字段 | 8,130 |
| 生成候选 AST | 8,126 |
| 明确未支持 | 4 |
| AST 节点 | 37,312 |
| 没有表达式字段的零参数 `for` 记录 | 8 |

4 个未支持字段来自两个逻辑场景的各两个包副本：

- `$` 前缀且后续呈十六进制字符形状的输入，目前没有把它当成十六进制值或宏，保留未知。
- 空的 `cal` 操作数字段，目前没有替换为 0、空字符串或默认表达式；它是否应跳过，要与引擎该调用点的检查规则核对。

这两个场景的具体位置和摘要在 `expression-report.json.unsupported_examples`，完整内容仅在私有 AST 记录。源码中 `cal` 为 4,761 个字段、`if` 为 2,137、`for` 为 1,107、`case` 为 125。未支持字段、零参数记录和其他命令的排除均未静默忽略。

结构可解析不能证明实际台词顺序、控制流、赋值是否合法、变量生命周期、整数宽度/溢出、字符串转换或逻辑短路。当前没有用解析率计算“游戏兼容率”。

## 独立复现

前提是已重现 P0、P1 文本副本与第三轮原生证据，且 Ghidra/JDK 版本按工具清单准备好。

```sh
.venv/bin/python tools/ghidra_tail_probe.py --synthetic \
  --private-dir private/p1-round5/flow \
  --ghidra-dir "$GHIDRA_INSTALL_DIR" --java-home "$JAVA_HOME"
.venv/bin/python tools/ghidra_tail_probe.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --private-dir private/p1-round5/flow \
  --plan docs/native-expression-flow-plan.json \
  --public-report expression-flow-report.json \
  --ghidra-dir "$GHIDRA_INSTALL_DIR" --java-home "$JAVA_HOME"
.venv/bin/python tools/expression_analysis.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --assets-dir private/real-assets
.venv/bin/python tools/research_checks.py --stage round5 \
  --game-dir "$GAME_DIR" \
  --artifact reports/p1/expression-flow-report.json \
  --artifact reports/p1/operator-report.json \
  --artifact reports/p1/expression-report.json
```

本轮新增 15 项合成测试，覆盖与 C 不同的处理组、括号、结合方向、下标与更新候选、明确拒绝的语法、字符串路径、UTF-16/CP932 原始字节定位、树脱敏、边界限制、失败字段原始引用，以及无值返回帮助函数的模型检查。

完整环境目前 118 项通过；系统 Python 115 通过、3 项可选检查跳过；上游 26 通过、8 项商业夹具检查跳过。Ghidra 实验独立记录，不混入 unittest 计数。实际验证、原始关键文件摘要及 P0 保护结果见 `round5-tests.json` 和 `round5-readiness.json`。

下一步应核对 `$` 前缀字面量、空字段处理、整数与字符串基本值及赋值引用规则，再把表达式树与调用/分支上下文连接起来。当前仍未完成完整执行语义或原生游戏运行时。
