# 省略模式与空指针取值：P1 第十六轮

本轮解决上一轮实际样本提出的问题：六处带同行 `scp,rep` 字面量提示的 `a` 登记候选都省略第三参数，究竟应不应该补模式零？现在有指令和元信息支持的条件解释，仍没有运行游戏、实现解释器或验证真实登记。

结论为 **Hypothesis / `inferred`**：若该命令片段按观察到的通用分派与 rep 分派正常处理，未发生预处理改写、对象遮蔽、列表突变或异常，缺少的字段三会被补为空指针；选定计算分支将其转成整数零，登记函数收到这个零作为模式。这个结论由链路推导，不是仅根据脚本文字“给可选参数设默认值”。

## 产物与身份

| 公开产物 | 范围 |
| --- | --- |
| `reports/p1/default-field-native-report.json` | 26 项查询、12 项指令事实，两个默认函数缺口、历史限制与线性窗口 |
| `reports/p1/default-field-metadata-report.json` | TReturnValue 声明和类型枚举的字节引用 |
| `reports/p1/default-field-audit-report.json` | 九字段补齐、槽位与返回布局核对，六处脱敏来源的条件投影 |
| `tools/default_field_audit.py` | 只读、有限的缺项来源审计；不计算实际表达式，不执行脚本 |
| `reports/p1/round16-tests.json`、`round16-readiness.json` | 测试与关键原始文件、P0 冻结检查 |

原始程序仍以 P0 的相对文件名和 SHA-256 识别；本轮固定计划均要求 `ad02b1115887b8e5b453d4b5760077e8b63e153bba1161e1704209cf3db5cda5`。输入身份一致不等于认证纯净发行版本。没有新的上游实现复用；REA、Ghidra、JDK 和原有解析器的版本、许可与复用界限沿用既有锁定文件。

完整伪代码和反汇编仅在 `private/p1-round16/`，没有商业正文或参数全文写入公开报告。所有 Verified 指令事实只证明指定字节与顺序；跨调用的用途解释单独列为 `inferred`。源码声明、上游测试与本地合成、真实静态检查的范围继续分开，未新增真实执行测试。

## 从字段补齐到登记模式的链路

1. **调用入口**：`0x6aadd4` 将 ECX 设为九，`0x6aadd9` 传入逗号，`0x6aade0` 调用字段解析器 `0x699fd0`。证据 `command_minimum_nine`。九是这个调用点的值，不外推为所有命令和所有调用点的统一上限。
2. **解析器保留参数**：`0x699fe3` 将传入数量保存在父帧 `-4`，构造选定 TStringList；非空解析尾部把父帧和列表地址传给 `0x699fa4`。证据 `split_saves_parent_count`、`split_calls_padding`。容量设置和补齐数量是两件事，本轮没有仅凭 Capacity 推断 Count。
3. **缺项补零指针**：`0x699fa4` 从父帧 `-4` 读取请求数量，取得当前 Count，按缺少项数循环，以 EDX 零调用虚槽 `+0x38`。证据 `padding_parent_count`。已有字段多于最小值时不截断，也没有给源文本中已经存在的字段强行补值。
4. **列表存取**：固定 VMT `0x432d50` 的类名为 TStringList；选定 Get、Count、Add、AddObject、InsertItem 槽位和代码地址均按源字节核对。Count 入口的选定本体读取实例 `+0x20`。Add 转发到 AddObject，未排序路径使用 Count 为插入位置；线性插入窗口将字符串放到八字节条目并递增同一 Count。Get 的正常区域从 `+0x1c` 取数组、按八字节条目取字符串，再交给 `0x407460`。完整列表 ABI、排序状态初始化、事件回调和失败策略没有恢复。
5. **空指针保持为空**：`0x407460` 的源指针为零时跳过字符串内容处理，用交换写入目的指针。旧目的非空仍可能触发引用计数清理，不能称为全局无副作用。证据 `nil_string_assignment`。
6. **模式取值**：rep 的 `a` 分支在 `0x6ba3fa` 请求列表字段三，经 Get 和 `0x6be1d8` 取值；后者保留输出指针，携带上下文编号调用计算入口 `0x69bab4`。证据 `registration_mode_source`、`value_wrapper_preserves_output`。
7. **空指针结果**：`0x69bb17` 判断原始输入指针是否为零。为零时写出标签零、整数零、空字符串，再跳到公共清理区。证据 `null_value_result`。这条分支不尝试解析普通表达式；与非空文本的解析失败、`vtError`、原文本回退路径不能混为一谈。
8. **模式存储**：调用者从返回记录取整数并作为栈参数传给 `0x696548`；后者在已有项更新和新增项两条选定路径都写入记录 `+8`。证据 `registration_mode_store`。登记是否实际到达、命中已有项与优先序仍未执行验证。

对于一个命令字段加两个源参数，原始字段数候选为三；读字段三已经超出这三个源字段，但位于补齐后的九字段列表内。因此结果来源是“追加的空指针候选”，不是从原稿伪造一个有字节位置的数字零。

工具的 `slot_projection` 只做这种有界的来源与数量推导。若槽位本来来自源字段，值转换保持 `not_tested`；即使文字看起来为空或数字，也不在这个工具中求值。槽位在投影后的列表外则保留 `unsupported`，拒绝负数、超出六十四、浮点数和布尔伪整数。

## 返回记录和类型标签

原始元信息 `0x696c58` 的真实记录名为 **TReturnValue**，不是根据用途另造的结构名称。声明大小十二字节，三个字段为：

| 字段 | 偏移 | 声明类型 |
| --- | --- | --- |
| ValueType | 0 | TScriptValueType |
| IntValue | 4 | Integer |
| StrValue | 8 | string |

枚举的标签零声明为 `vtInteger`。字节探针同时核对这个声明与布局，不能仅因“第一个字节是零”就推断整个对象为零或任意场景下都等价整数零。记录初始化、全部托管行为和编译器版本仍 `not_tested`。

## 清理后返回与窗口边界

计算入口的默认 Ghidra 本体在清理区 `RET` 结束，但 `0x69c525` 明确压入正常后续地址 `0x69c552`。单独 LLVM 窗口显示该处恢复寄存器、栈并以 `RET 4` 返回，证据 `null_cleanup_continuation` 和 `linear_windows`。没有修改原始程序或分析数据库来制造包含关系，也没有宣称异常时仍会正常返回。

第一次计算尾部窗口过宽，进入后随数据，出现 `0x69c561` 未知解码；随后在 `0x69c563` 打印的两字节指令还越过了指定末尾 `0x69c564`。这揭示一个真实的报告风险：解码器按起始地址决定打印指令，不保证完整指令都在 stop-address 内。

`review_native.linear_decode_issues` 现在分别报告未知指令、跨出字节引用区间的指令，以及缺少字节列的行。源区间摘要不再被误用为覆盖跨界指令的证明。原过宽窗口保存在 `windows-expanded` 并公开标 `unsupported` 的覆盖范围；最终窗口止于 `0x69c55b`，覆盖完整返回指令。最初 Get 窗口还包含后随另一入口，保留在私有 `windows`，未把它冒充整个 Get 的函数边界。

默认包含函数查询对 Get `0x43eb54` 和 InsertItem `0x43ec84` 都返回不存在；两个缺口保留 `unsupported`，线性观察不取消这个结论。工具最初按邻近地址猜选 AddObject 的假设被包含函数查询否定；读取真正虚槽后改为 `0x43e8cc`，历史限制同样保留。整个 TImoScript 声明有三十八项方法、七十五项字段，超过整类探针六十四项上限；没有提高上限或跳过字段来宣称全类支持。

## 实际副本复核与剩余条件

重读并核对 379 份副本摘要，保留全部包版本，仍得到 563 个 `a` 拼写候选。仅选择六处同一物理行有字面量 `rep` 提示的记录做条件投影；其余 557 处明确以“无同行提示，命名空间未确认”保留 `not_tested`，没有静默丢弃。

六处均具有两个源参数，投影来源全部为 `appended_null_candidate`，由上述分支得整数零候选。没有将它们统计为六次已发生的模式零登记。每条带源文件、完整文件摘要、记录偏移/长度、区间摘要，以及对象选择提示记录的独立引用；追加空指针没有虚构的源字节区间。

仍需满足或验证的前提：

- 源命令片段经过预处理后确实按此形态到达通用解析器。
- 对象选择、宏处理、内建处理优先序没有提前消耗该命令或改变接收者。
- 列表构造、补齐、读取得以正常完成，没有回调突变或异常。
- 该零确实送入最终执行的替换记录，而不是随后被其他登记覆盖。

因此只把“省略模式的选定静态路径”从无依据的未知推进到 `inferred`。完整正文替换、对象生命周期、异常恢复、存档、音画时序和全作执行兼容依然未验证，不能据此宣布完成原生移植。

## 测试、安全和复现

新增十项缺项/绑定测试和三项反汇编窗口测试，全部用自建元信息、指令或文本夹具：槽位零的偏移、已有字段不求值、Count 不截断、越界索引、数量/类型限制、非目标候选跳过、参数脱敏、错误加载/调用/槽位，以及未知解码、指令越界和缺失字节列。

扫描继续限制为最多 2,000 个副本、128 MiB 总输入、10,000 个候选、单文件 16 MiB、每字段 8,192 字符，处理超时 120 秒。新投影最多六十四个字段，元信息仍有累计 1 MiB 预算；输入和输出重叠、符号链接和摘要不匹配继续拒绝。原始 EXE 仅当数据读取，没有执行游戏、安装程序或存档程序。

使用者自行设置自己的合法路径与工具环境变量：

```sh
.venv/bin/python tools/delphi_metadata.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-default-field-metadata-plan.json --output reports/p1/default-field-metadata-report.json
.venv/bin/python tools/rea_static.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-default-field-plan.json --output private/p1-round16/native-reproduced \
  --java-home "$JAVA21_HOME" --ghidra-dir "$GHIDRA_DIR" --analysis-budget-seconds 600
.venv/bin/python tools/native_windows.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-default-field-expanded-windows.json --output private/p1-round16/windows-expanded
.venv/bin/python tools/native_windows.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-default-field-windows.json --output private/p1-round16/windows-selected
.venv/bin/python tools/review_native.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-default-field-plan.json --facts docs/native-default-field-facts.json \
  --evidence-dir private/p1-round16/native-reproduced --windows-dir private/p1-round16/windows-selected \
  --exploratory-windows-dir private/p1-round16/windows-expanded --output reports/p1/default-field-native-report.json
.venv/bin/python tools/default_field_audit.py --game-dir "$GAME_DIR" --exe "$EXE_REL" --assets-dir "$ASSETS_DIR"
.venv/bin/python tools/research_checks.py --game-dir "$GAME_DIR" --stage round16 \
  --artifact reports/p1/default-field-metadata-report.json --artifact reports/p1/default-field-native-report.json \
  --artifact reports/p1/default-field-audit-report.json
```

如需附带本机已有的两项历史限制，review 命令可额外传 `--attempts-file private/p1-round16/exploratory-limitations.json`。历史尝试不是从零复现所必需的输入，省略不会伪造过去失败；原子指令、声明与当前缺口可以独立再生。MCP 导出与独立采集的二十六个查询证据 ID 一致，比较记录在 `independent-comparison.json`。

实际回归结果：研究环境 265 项全部通过；系统 Python 262 项通过、3 项跳过；上游 26 项通过、8 项商业夹具缺失跳过。跳过不计成功。20 个关键原始文件 SHA-256 与 P0 一致，P0 摘要同时与回归前和本轮开始前的快照一致，三个公开研究报告通过禁用正文/原始参数字段检查；这不等于全目录不可变或整作运行兼容证明。
