# 24 — subp 参数打包、字段分组与前缀引用

2026-11-07，P1 第十三轮。继续对固定摘要的第四作程序候选与既有副本作只读研究，没有运行游戏、解释脚本或开发播放器。上一轮定位了前缀字段，本轮补查其调用变体、对象类型线索和字段边界。

## subp 在共享调用之前另做处理

原生二级分派将 sub、subp、subr 引向共享区域，又为 subp 单独选择一段处理。选定指令支持以下顺序：

1. 共享入口将字段列表补到至少 19 项。这里包括命令名、两个目标字段及 16 个参数槽；这是最小补齐数量，不是允许的最大输入字段数。
2. subp 路径从列表尾部向前找非零字段。
3. 从字段索引 3 起，把保留范围中的原始字段用逗号拼接，写回索引 3。
4. 从字段 4 起将后续项置零，再进入共享参数处理和调用上下文路径。

因此 subp 不能直接当成普通 sub，也不是逐字节取得“剩余原文”的保证。中间空字段和尾部空字段的待遇不同；带双引号的空字符串形状与零字段也要分开。后续仍有参数值解析、转换和上下文处理，本轮没有实现或执行这些行为。

`native-subp-facts.json` 中的 `subp_selector`、`call_pad_nineteen`、`padding_appends_zero`、`subp_last_present_scan`、`subp_tail_merge`、`subp_clear_later_fields`、`common_sixteen_slots` 分别给出选定指令与原字节引用。逗号常量也从原文件单独核对，完整契约仍为 `inferred`。

字段列表的 Get/Put 接口通过已核对的 TStringList VMT 和选定槽位定位。Get 的短窗口包含越界检查，不能先假定越界返回空值；补齐到 19 项的指令解释了共享参数循环访问至字段 18 的局部条件。未核对所有异常、动态虚表修改或完整 ABI。

本次保留语料重新统计：sub 1,804 条、subp 4 条，未观察到 subr。四条直接 subp 均为三个词法参数。未出现 subr 只限定这批副本，不证明引擎或动态生成脚本不会使用它，也不把它算作真实测试成功。

## 内建 rep 与分派器形成条件证据链

原文件中三处带长度的 UTF-16LE rep 常量分别用于类型诊断、内建注册和对象工厂。选定注册调用将同一常量地址作为名称与类型输入；工厂的一条匹配路径调用构造函数，该构造路径将对象 `+0xc` 的类型字节设为 14。

另从原文件直接核对对象分派守卫、表项 14 和调用指令：它们把该类型候选与 `0x6ba248` 前缀分派器联系起来。前一轮的 et/nt 字段写入证据与这一分派器同源。

这些观察支持“脚本选择 rep 时可能进入前缀配置处理”的条件解释，没有把整个对象身份升级为 verified。注册回调如何真正连接工厂、变量是否遮蔽内建名称、临时上下文及执行顺序仍未闭合；`creation_callback_link`、`namespace_shadowing` 保持 `not_tested`。

扫描还在八个 et/nt 源记录前找到同一词法标签区间内最近的字面 scp 选择，均与内建名称候选相符。每条线索保留 scp 的源引用，参数本身不公开；遇新标签时重置线索。它不是运行中的作用域状态，跨调用、分支、包含和对象替换仍可能改变实际绑定。

TStringList 的类引用在这里是直接 VMT，不能套用另一处读取器构造中的自指针单元间接形式。早期错误的间接读取假设保留为 `preliminary_reference_assumption=unsupported`；最终核对了 VMT 自指针、类名和选定槽位，没有由此声称掌握所有类布局。

## 从前缀字段追到词法接收区域

四个非空前缀字面量中均能观察到 subp，另四个配置记录为空字符串形状。两种非空模板的目标字段是字面标签；其中一种还带有两个原始空字段，另一种没有显式文件字段。图中只表达静态候选关系：

```mermaid
flowchart LR
  R[内建 rep 注册] -.->|条件关联| F[工厂类型 14]
  F -.->|表项与调用证据| D[前缀分派器]
  D -.->|作用域仍未知| P[et / nt 前缀字段]
  P -->|字面量词法观察| S[subp 候选]
  S -->|精确标识符候选| L[标签区间]
  L -.->|词法出现| A[ParamStr 第零槽]
```

扫描保留所有包版本，得到四个接收标签区域和八条前缀到标签的候选边，其中四条在同一物理源文件内。另四条跨版本候选没有被选作实际目标；同一文件线索也不等于运行目标，因为缺省文件字段与当前读取器、包含和加载顺序有关。

接收区域中共观察到八处未加引号的 ParamStr 第零槽词法出现，每处都有命令和父字段的字节引用。没有据此断言读写方向、实际求值或正文一定走过该路径。目标标签以指纹和源位置公开，原参数与正文继续保留在私有副本中。

旧的 4,261 条转移记录只覆盖 sub/go/jmp/ret，本轮没有改写它们来制造已有覆盖。subp 的直接记录和前缀派生记录在新报告中分开：派生项是配置模板的来源数，不是游戏执行调用次数。参数表达式、文件目标和实际标签解析继续为 `not_tested`。

## 拆字段模型明确版本化

原生 `0x699fd0` 在判断分隔逗号时，还检查引号状态及括号/方括号深度。两个括号种类使用同一个有符号计数，不是类型匹配栈；这不证明表达式语法验证也使用相同规则。

`tools/qlie_lex.py` 现在提供两个明确模式：

| 模式 | 用途与范围 |
|---|---|
| quote_only | 保留默认值供旧报告独立复现，只抑制引号内的逗号 |
| native_grouping | 新研究显式选择；命令字段还抑制正深度括号内的逗号 |

新模式只改变已识别命令的字段边界。行标签、冒号键值、预处理、表达式和完整执行语义没有因此得到确认。静态 IR 仍保留尾部空字段以追踪原始位置；这不是原生列表数量的模拟，原生解析与补齐路径另有证据。未闭合双引号等情况的探针拒绝也不等于引擎必然拒绝。

新增模型对分组深度限制为 64，超限明确生成未支持记录。CP932 别名和 UTF-16 代理对继续通过原始解码跨度定位，不重新编码来伪造偏移。

对 379 份实际副本的 40,824 条命令逐条比较新旧字段跨度，变化 0、解析错误 0。**没有声称修复了这批真实数据中的错误字段，也没有将合成分组样例算作真实兼容测试。** 分组差异目前由选定原生指令和明确的合成测试覆盖；现有语料的字段边界恰好一致。

## 覆盖、失败和可重复命令

本轮独立采集 30 项观察、14 项指令事实，采集错误数零、清理完成；30 个选定 Evidence ID 均与 MCP 观察相同。Get 入口可被默认解码，但未归入默认函数，所以仍保留一项默认函数覆盖缺口，未称为完整反编译支持。

类指针探查的错误间接形式、默认函数缺口、动态绑定、缺省文件以及参数转换均分别记录，不把任何一个空缺当成“无操作”。真实视图只在 `private/p1-round13/`；公开 `subp-native-report.json` 和 `subp-analysis-report.json` 不包含脚本正文或完整伪代码。

```sh
.venv/bin/python tools/rea_static.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-subp-plan.json --output private/p1-round13/native-reproduced \
  --rea-command "$REA_COMMAND" \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
.venv/bin/python tools/native_windows.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-subp-windows.json --output private/p1-round13/windows
.venv/bin/python tools/review_native.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-subp-plan.json --facts docs/native-subp-facts.json \
  --evidence-dir private/p1-round13/native-reproduced \
  --windows-dir private/p1-round13/windows --output reports/p1/subp-native-report.json
.venv/bin/python tools/subp_analysis.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" --assets-dir "$ASSETS_DIR"
.venv/bin/python tools/research_checks.py --stage round13 --game-dir "$GAME_DIR" \
  --artifact reports/p1/subp-native-report.json \
  --artifact reports/p1/subp-analysis-report.json
```

使用者提供路径，输入目录只读。新分析最多 2,000 个文件、128 MiB 总输入、512 个前缀；各类标签、转移、变化记录和边分别限制数量，元数据输出上限 32 MiB，独立命令限制 120 秒。新增 16 个自造测试覆盖分组、历史模式、源字节、深度上限、空字段、引用保留、精确匹配、参数脱敏、守卫/表项/调用编码及越界拒绝，没有商业夹具。

下一步应继续闭合对象创建回调及遮蔽、参数转换和接收格式脚本的演出关系。当前只有可追溯的静态候选，不建议据此直接开发完整运行时，也未达到原生移植完成状态。

最终研究环境 228 项通过；系统 Python 225 项通过、3 项可选集成检查跳过；上游 26 项通过、8 项商业夹具检查跳过。跳过不计成功。`round13-readiness.json` 核对的 20 个原始关键文件摘要及冻结 P0 报告与本轮开始前一致；没有据此声称已逐字节复核全部安装内容或验证整作运行。
