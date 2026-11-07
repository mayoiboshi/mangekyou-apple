# 对象作用域与注册表比较：P1 第十七轮

本轮沿 `scp,rep` 追踪命令接收者，继续限定的静态研究，没有解释或执行商业脚本，没有运行 EXE/DLL，没有开发解释器、播放器和界面。后续范围确认尚未收到回复，原约束继续适用。

取得的实质进展：选择对象的命令先清空当前例程作用域，再将计算出的字符串或对象名称写入原槽位；对象分派遇空槽停止，处理成功的分支仍继续下一槽。注册表先作字段/哈希判断，再按字符串比较设置的条件标志决定是否匹配。这些规则为未来运行时提供了具体约束，六处实际登记候选仍不能直接宣称已绑定内建 rep。

## 产物与证据层次

| 产物 | 实际范围 |
| --- | --- |
| `reports/p1/scope-native-report.json` | 24 项静态查询、16 项指定指令事实及两个正常返回窗口 |
| `reports/p1/scope-metadata-report.json` | TScriptRoutine 和 TReturnValue 的有界声明；不实例化 |
| `reports/p1/scope-audit-report.json` | 真实副本的选择参数形状、位置和同行候选图，参数正文脱敏 |
| `tools/scope_audit.py` | 只读字节绑定、结构形状与关系扫描；不计算变量值 |
| `reports/p1/round17-tests.json`、`round17-readiness.json` | 测试、上游适配、原始关键文件和 P0 冻结检查 |

仍只接受 P0 固定的原始主程序摘要。计划、指令及声明均可由源文件 SHA-256、原始字节偏移、长度和区间摘要定位；完整代码正文和 MCP 导出在忽略目录 `private/p1-round17/`。源码声明、上游测试、本地合成和真实静态检查范围沿用既有记录，没有将原生查询算作运行验证。

下文 Verified 仅指字节、声明或指定指令顺序；跨函数解释为 **Hypothesis / `inferred`**。当前脚本执行到哪一处、变量的实际值、对象身份和调用继承均 `not_tested`。

## scp 如何写作用域

`selector_chain` 只读核对三个连续 SUB 和 JZ：`0x6afdeb` 减 `0x6b6c63`、`0x6afdf6` 减 `0xf500`、`0x6afe01` 减 `0x40210`，合计命令编号 `0x706373`；最后的零分支进入 `0x6b011e`。这是受既有 ASCII 命令编号模型支持的候选 scp 路径，不把之前的分支条件、控制块门控或运行可达性省略为已验证。

该路径的观察如下：

1. 经 `0x6c1160` 取得当前例程，调用 `0x6c1018` 清空它从 `+0xc` 开始的十六个四字节字符串槽。依据 `scope_clear_sixteen`、`scp_clears_before_fields`。
2. 按输入列表 Count 减一处理源参数，源索引为循环编号加一；原始指针为空时跳过写入，但仍递增编号。没有紧缩空槽。依据 `scp_preserves_slot_positions`。
3. 通过选定计算上下文求值，标签二和一才进入写入区域。TReturnValue.ValueType 的枚举声明分别为 `vtObject` 和 `vtString`；其他标签走另一条错误处理路径。错误是否终止、是否保留之前的写入仍未知。依据 `scp_accepted_tags`。
4. 从计算结果的字符串字段取名称，经 `0x41493c` 处理后写到当前例程 `+0xc+编号*4`。宽字符路径中的 ASCII 小写折叠已有前轮证据，不能外推完整 Unicode 规范化。依据 `scp_writes_evaluated_name`。

因此，裸标识符 `rep` 与字符串字面量 `"rep"` 的来源不同：前者需要变量/对象取值，后者有字符串语法形状；它们的实际名称可能不同。本轮真实选择参数里没有字符串字面量形状，不能用自建字符串样例声称真实字符串选择已执行成功。参数计算、局部/全局变量覆盖、对象创建名称和对象存续仍会影响接收者。

`0x6c1160` 通过包装取得容器最后一项；底层 `0x6c1ad0` 对负编号或超出容器 Count 的编号返回零。例程为空时上层是否先行保证有效、跨调用如何继承 Scope，都不在本轮完成范围。

## 声明范围与输入边界

TScriptRoutine 的 `Scope +0xc` 为字符串数组，元信息声明六十四字节、十六个元素；紧邻 `State +0x4c`。原始数组头和字段引用在元信息报告中。Scope 清理循环上限与这个声明一致。

选择参数的写入循环却由输入列表 Count 决定，本轮选定写入尾部未观察到单独的十六项上限检查。只能将超过声明范围的风险标为 `inferred`：还没有验证上游全部限制，更没有执行过界写入。工具将超过十六个源字段的形状标为 `unsupported`，只保存前十六项形状、额外项数和整条记录引用，禁止模拟内存破坏。本轮真实样本没有超过此界限的记录。

这十六项是声明与选定写入契约，不是整个词法格式的字段上限。为避免一条超长逗号串生成海量字段对象，通用 `qlie_lex.split_fields` 另加每条四千零九十六字段的研究工具限制；超限保留 `unknown_record`、失败类别与完整字节覆盖，未作为游戏格式规定。引号模式与显式分组模式均受这一计数限制。

## 后续分派不是一次名称替换

对象分派 `0x6aacf8` 从作用域零号槽开始，每轮重新取得当前例程。`0x6aae7f` 检查该槽是否为空，空则跳出循环。非空名称交给选定上下文 `+0x11c` 的注册表，然后按对象类型分派；类型十四到 `0x6ba248` 的候选 rep 路径仍由固定跳表和 E8 指令核对。

成功标志非零时，`0x6ab2b0` 跳到 `0x6ab310`，这里递增槽号，并继续十六槽循环。依据 `scope_dispatch_continues`。因此选定成功路径会继续后续非空槽，错误路径、等待、副作用和重新进入例程可能影响最终处理，不能把静态循环直接当作全部执行轨迹。

原槽位位置很重要：如果中间槽最终为空，更后面的槽不会在这次普通遍历中被读到。扫描仅记录“原稿空字段后仍有源字段”的结构候选，原稿空字段如何映射到运行时指针仍单列 `not_tested`。它没有过滤空项后重排，也没有执行对象选择。

## 注册表与条件标志

`0x68adc8` 对名称做处理，先用实例 `+0xa4` 的缓存，以零为未命中结果；未命中再调用 `0x68acc0` 扫描 `+0xcc` 的对象容器，找到后取出对象。索引路径从前向后，先检查某个对象字段与名称计算值相等，再调用 `0x407b38` 比较名称；匹配后写入缓存。依据 `registry_cache_and_fallback`、`registry_name_guard`、`registry_cache_after_match`。

需要保留的 ABI 细节是：比较调用之后紧接 JNZ，没有先测试 EAX。`0x407b38` 的第一条是 `CMP EAX,EDX`，相同指针直接跳到 RET，EAX 可以仍是非零指针，ZF 却表示相等。它不是以 EAX 为标准真假结果的普通函数。默认伪代码在一处还把第二个比较条件显示成之前的布尔变量，机器指令则明确包含比较调用及条件跳转。只根据反编译 C 表面类型推断逻辑会丢失这层信息。

这支持“哈希/字段过滤后再按名称相等决定匹配”的条件模型，完整哈希算法、非宽字符转换、缓存失效、所有比较路径和对象删除仍未知。选定新增函数 `0x68a0b4` 只在名称查找索引为负一时追加对象；这不能证明所有变量或命名空间都不存在遮蔽。

两个查找函数还存在清理后的正常返回续段：`0x68ad8d` 返回保存的索引，`0x68ae44` 返回保存的对象指针。它们位于默认函数体末尾之外，已用独立 LLVM 窗口保存。初始对象返回窗口跨入下一入口，原样保留；最终在 RET 后收窄，没有修改默认分析数据库。本轮计划不含独立 resolve/inspect 查询，默认函数查找覆盖与完整函数范围都保留 `not_tested`。

## 实际扫描结果

重新核对全部 379 份副本的摘要，保留各包物理版本，得到：

| 元数据 | 数量 |
| --- | --- |
| scp 拼写候选 | 6,014 |
| 一个源字段 | 6,002 |
| 两个源字段 | 10 |
| 五个源字段 | 2 |
| 标识符结构 | 4,858 |
| 下标结构 | 1,166 |
| 原稿空字段 | 8 |
| 超过十六字段、原稿中间空槽后仍有源字段 | 均为 0 |
| 选择命令到同行后续命令的候选关系 | 5,793 |

这不是执行次数，也不是 6,014 个已验证的对象绑定。全部参数形状可在有界结构语法下分类，但其求值标签和对象名称均未计算。

三十项选择具有单个裸内建名称 `rep` 的精确词法形状；其中同行的六条 `a` 关系与上一轮省略模式候选的源文件/偏移完全一致。完整同行 `a` 关系共有 186 条，其他对象的短命令拼写不能冒充 rep 登记。et/nt 与更早选择的跨行关系仍沿用前轮弱线索，当前图严格只跟随同一物理行，不把例程持久状态或跨调用行为虚构为已求解。

每条图边同时引用选择记录和接收命令记录；每个参数有独立字节引用与位置编号。公开文件没有参数全文、对象实际名称或台词。实际启动、变量值、作用域继承、处理器之间的作用域变更、错误回滚和完整正文替换继续 `not_tested`。

## 验证与下一步

新增十项作用域测试和一项词法计数测试，全部用自建样本。覆盖连续减法/JZ 的正反例、标识符与字符串区别、未支持语法、位置和空槽保持、同行重置、十六项边界、CP932/UTF-16 字节引用、参数脱敏、版本保留、摘要失配和符号链接拒绝，以及四千零九十六字段限制下的失败与完整覆盖。

独立进程重新采集 24 项观察，证据 ID 与 MCP 导出一致，采集和清理错误为零。TScriptRoutine 的十项方法声明只有一项析构槽被比较，九项未比较，所有十项签名尾部未解释；元信息绑定覆盖 `not_tested`。没有因类名、布局或代码可读而宣称对象运行兼容。

扫描限制为最多 2,000 个副本、128 MiB 累计输入、10,000 个选择候选、20,000 条关系、每字段 8,192 字符和 120 秒处理时间；所有超限、跳过和未支持形状显式记录。原始输入只读，不执行任何原版程序。

下一步应在获准的范围内验证调用/返回和事件处理时 Scope 如何继承、清理或变化，并核对字符串比较及错误路径。若进入最小解释器验证，初期必须保留未知命令的停止位置、原始字节追溯与明确的未支持结果，不能提前声称完整执行语义。

## 重复运行

```sh
.venv/bin/python tools/delphi_metadata.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-scope-metadata-plan.json --output reports/p1/scope-metadata-report.json
.venv/bin/python tools/rea_static.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-scope-plan.json --output private/p1-round17/native-reproduced \
  --java-home "$JAVA21_HOME" --ghidra-dir "$GHIDRA_DIR" --analysis-budget-seconds 600
.venv/bin/python tools/native_windows.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-scope-initial-windows.json --output private/p1-round17/windows-initial
.venv/bin/python tools/native_windows.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-scope-windows.json --output private/p1-round17/windows
.venv/bin/python tools/review_native.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-scope-plan.json --facts docs/native-scope-facts.json \
  --evidence-dir private/p1-round17/native-reproduced --windows-dir private/p1-round17/windows \
  --exploratory-windows-dir private/p1-round17/windows-initial --output reports/p1/scope-native-report.json
.venv/bin/python tools/scope_audit.py --game-dir "$GAME_DIR" --exe "$EXE_REL" --assets-dir "$ASSETS_DIR"
.venv/bin/python tools/research_checks.py --game-dir "$GAME_DIR" --stage round17 \
  --artifact reports/p1/scope-metadata-report.json --artifact reports/p1/scope-native-report.json \
  --artifact reports/p1/scope-audit-report.json
```

命令会运行规定的系统与研究 Python 测试和上游适配验证，跳过不算成功，并检查关键原始文件和冻结 P0。本轮开始前的 P0 快照另存在私有目录；这些检查不等于全目录不可变或全作兼容证明。

本轮实际回归：研究环境 276 项全部通过；系统 Python 273 项通过、3 项跳过；上游 26 项通过、8 项商业夹具缺失跳过。20 个关键原始文件摘要与 P0 一致，P0 与本轮开始前快照及回归前快照一致，三个公开研究报告通过正文/原始参数字段检查。全作原生运行依然 `not_tested`。
