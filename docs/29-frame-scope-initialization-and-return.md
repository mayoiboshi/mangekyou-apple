# 调用帧的作用域初始化与返回：P1 第十八轮

本轮继续授权范围内的只读静态研究，没有实现解释器、调用栈执行器、播放器或界面。后续最小解释器验证的范围问题仍未收到回复；完整移植目标保持未完成，不能以研究报告代替原生运行。

本轮更有依据的 **Hypothesis / `inferred`**：选定调用创建新例程时，经已核对的虚槽进入 Init，清空新例程自己的十六个 Scope 槽；返回裁剪后，当前例程重新成为被保留的目标例程。非局部返回的恢复数据来自“目标的下一项”，不必是原栈顶。实际脚本执行、回调和错误恢复仍 `not_tested`。

## 产物和证据范围

| 产物 | 范围 |
| --- | --- |
| `reports/p1/frame-scope-native-report.json` | 33 项查询、12 项原子指令事实、3 个默认函数缺口和 3 个线性窗口 |
| `reports/p1/frame-scope-metadata-report.json` | 线程、例程、控制块与结果记录声明，不实例化 |
| `reports/p1/frame-scope-audit-report.json` | 379 份副本的 3,720 处直接调用/返回候选与条件标注 |
| `tools/frame_scope_audit.py` | 只读槽位核对、返回索引几何与源位置审计，不执行栈操作 |
| `reports/p1/round18-tests.json`、`round18-readiness.json` | 自动化、上游适配、关键原始文件和冻结 P0 检查 |

所有机器事实只针对 P0 固定的主程序 SHA-256，原始字节引用仍使用相对文件名、文件摘要、offset、length 和区间摘要。Verified 不外推完整路径可达性、ABI 或执行等价；行为契约单列 inferred。完整代码正文和 MCP 导出仅在 `private/p1-round18/`，公开报告不包含商业剧本文字或参数全文。既有上游来源、commit、依赖和许可范围没有改变。

## 新例程的 Scope 清理链

选定调用成功路径的两次虚调用分别是线程 `+0xc`、随后当前例程 `+0xc`，见 `call_creates_two_layers`。声明与原始槽位将它们连接到：

| 对象/位置 | 已核对目标 | 范围 |
| --- | --- | --- |
| TScriptThread `+0xc` | `0x6c11d4` Add | 创建并追加例程的选定窗口 |
| TScriptRoutine `+0xc` | `0x6c1074` Add | 创建并追加控制块的选定窗口 |
| TScriptRoutine `+8` | `0x6c14b4` Init | 例程初始化窗口 |

线程 Add 以明确的类引用调用 `TScriptRoutine.Create`（`0x6c13d4`），再把返回对象追加到自身容器。例程 Create 调用基类构造 `0x6c19ec`；基类建立容器后通过当前对象虚槽 `+8` 调用 Init。依据 `routine_calls_base_create`、`base_calls_virtual_init` 及固定槽位读取。

Routine.Init 的窗口显示：先作基类清理，再调用 `0x6c1018`，随后重置 State、等待/跳转/事件字段，释放已有结果记录并清除恢复标志。`0x6c1018` 从实例 `+0xc` 开始，用零指针写十六个四字节字符串槽。清理循环与 Scope 的六十四字节、十六元素声明一致。

因此选定初始化确实会清空新例程 Scope；本轮检查的添加路径中没有显式复制调用者 Scope。这个结论比仅根据新分配内存假定全零更具体，但仍以实际接收对象符合已核对类/槽位为条件；其他回调、别名、重入或未检查的后续路径可能改变状态，完整运行中的继承行为继续 `not_tested`。

调用者的例程对象仍留在容器中，控制块保存调用位置。不能据这一结构把 Scope 实现成只有一个全局可变数组，也不能仅凭类名推断所有调用都会继承对象选择。这里提供的是条件契约，没有实际创建或改变任一游戏例程。

## 返回先取哪里，再移除哪些项

选定返回路径以目标编号加一为 ESI，取该例程，再取其中控制块零号项。该块的文件、标签及两个位置字段送入读取器恢复路径，见 `return_selects_first_removed` 和既有返回指令观察。字段的 Line/Pos 声明并不证明它们等于研究副本的字节偏移，具体单位与完整位置映射仍未恢复。

随后检查**同一个例程**的 `FResultRestory +8`。标志非零时，从 `ResultRecord +0x68` 调用结果恢复函数；最后才调用裁剪函数，参数为要保留的目标编号。依据 `return_result_flag_source`、`return_trims_after_restore`。

`0x6c111c` 在有效索引范围内循环移除末项，直到 Count 不大于目标加一。当前例程包装 `0x6c1160` 总是取容器最后一项。正常裁剪完成后，当前例程因而成为被保留的目标例程，其 Scope 来自这个被保留对象；没有在本轮返回区域观察到单独的 Scope 拷贝恢复步骤。

索引示例只用于说明几何关系，不是游戏执行测试：

| 裁剪前数量 | 保留目标 | 恢复数据来源 | 保留数量 | 移除数量 |
| --- | --- | --- | --- | --- |
| 4 | 2 | 3 | 3 | 1 |
| 5 | 1 | 2 | 2 | 3 |

后一种非局部返回使用编号二的恢复数据，而不是必然使用原栈顶四。是否恢复结果还取决于编号二的标志，不能替每个被移除例程自动执行一遍结果恢复。命名目标如何求值、能否命中，以及析构中所有外部影响仍未执行验证。

新工具的 `return_projection` 只计算这些整数关系，不持有、移除或恢复任何运行对象。数量上限 1,024 是研究投影的范围限制；不代表原引擎在异常或追加后超限时具有相同回滚策略。无有效调用者或目标不在保留范围时显式返回 unsupported，不捏造成功返回。

## subr 的附加记录

共享调用路径比较保存的编号是否为 `subr`，匹配时调用 MakeResult，再调用保存函数。MakeResult 分配 `0x10c` 字节，写到例程 `+0x68`，并设置 `+8` 标志。依据 `subr_snapshot_gate`、`result_record_size_and_flag`。

元信息名称是 TScriptRoutineResult，大小 268 字节，与分配一致。它含 ResultStr、ResultInt、ResultObj、按钮及子调用等结果字段；保存/恢复助手读取具名结果存储的选定路径，为其提供结果寄存器快照的解释线索。记录命名与方法命名仍有差异，三处字段缺少类型引用，完整转换和外部副作用没有自动补齐。

该结果记录不能仅凭“保存/恢复”字样就当成 Scope 快照；Scope 位于例程自己的字段中。源模型保留 `scope_snapshot=not_tested`，并将 subr 的附加结果角色与 subp 的尾字段合并角色分开。没有以普通 sub 合并两种变体，也没有开发结果寄存器执行后端。

## 真实源码候选

重新验证 379 份受限副本的摘要，按显式分组模式扫描，得到 3,720 个直接拼写候选：

| 命令 | 数量 | 范围 |
| --- | --- | --- |
| sub | 1,804 | 已定位直接源记录 |
| subp | 4 | 已定位直接源记录 |
| ret | 1,912 | 已定位直接源记录 |
| subr | 0 | 真实直接拼写覆盖 not_tested；机器分支与自建样例另记 |

包含各包重复版本，不是执行次数；引号中的模板及动态生成命令不属于这个直接计数。模型为每条记录保留源字节位置和摘要，附上调用创建/返回契约；实际目标、对象归属和调用到达仍 `not_tested`。零/一参数 ret 分别保留默认目标与命名上下文角色，不当成返回值赋值。

## 缺口与验证

三个默认包含函数查询仍返回不存在：线程 Add、例程 Add、例程 Init。改用同一输入摘要下的三个只读 LLVM 窗口，不修改默认函数数据库。33 项观察在独立进程重取，采集和清理错误为零，证据 ID 与 MCP 导出一致；这只证明采集复现，不取消函数覆盖缺口。

元信息报告有 21 项未解释的方法签名、19 项未比较的方法/虚槽、3 处缺少类型引用的结果字段，绑定覆盖保持 `not_tested`。单独核对的三个创建/初始化槽位只证明这一小组绑定，不外推整类 ABI。

新增八项自建测试覆盖普通/非局部返回的索引关系、无效目标和数量限制、变体角色区分、ret 目标角色与不支持的参数数量、非目标命令拒绝、CP932/UTF-16 来源、参数脱敏、版本保留、摘要和符号链接拒绝。测试对象是研究工具；没有运行原始代码或调用栈。

扫描继续限定 2,000 个副本、128 MiB 总输入、20,000 条候选、单文件 16 MiB、120 秒处理时间；元信息沿用累计 1 MiB 预算和六十四成员限制，原始输入只读，失败写入私有失败报告。整作原生运行、完整对象生命周期、事件重入、异常回滚、存档兼容和音画时序仍未完成。

## 重复运行

```sh
.venv/bin/python tools/delphi_metadata.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-frame-scope-metadata-plan.json --output reports/p1/frame-scope-metadata-report.json
.venv/bin/python tools/rea_static.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-frame-scope-plan.json --output private/p1-round18/native-reproduced \
  --java-home "$JAVA21_HOME" --ghidra-dir "$GHIDRA_DIR" --analysis-budget-seconds 600
.venv/bin/python tools/native_windows.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-frame-scope-windows.json --output private/p1-round18/windows
.venv/bin/python tools/review_native.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-frame-scope-plan.json --facts docs/native-frame-scope-facts.json \
  --evidence-dir private/p1-round18/native-reproduced --windows-dir private/p1-round18/windows \
  --output reports/p1/frame-scope-native-report.json
.venv/bin/python tools/frame_scope_audit.py --game-dir "$GAME_DIR" --exe "$EXE_REL" --assets-dir "$ASSETS_DIR"
.venv/bin/python tools/research_checks.py --game-dir "$GAME_DIR" --stage round18 \
  --artifact reports/p1/frame-scope-metadata-report.json --artifact reports/p1/frame-scope-native-report.json \
  --artifact reports/p1/frame-scope-audit-report.json
```

复核命令运行系统与研究 Python 测试、上游适配验证，并检查关键原始文件和冻结 P0。本轮开始前的快照独立保存在私有目录；通过检查不等于证明完整目录不可变或完成原生移植。

实际回归结果：研究环境 284 项全部通过；系统 Python 281 项通过、3 项跳过；上游 26 项通过、8 项商业夹具缺失跳过。跳过不计成功。20 个关键原始文件 SHA-256 与 P0 一致，P0 与本轮开始前及回归前的快照一致，三个公开研究报告通过正文/原始参数字段检查。完整原生运行仍为 `not_tested`。
