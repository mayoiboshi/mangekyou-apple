# 19 — 更新发生阶段与调用返回上下文

2026-11-07，P1 第八轮。仍仅静态研究，不求值脚本、不创建变量执行后端、不运行游戏 EXE/DLL，也未开发播放器或界面。主程序候选继续以同一摘要固定；不能据此认证目录为纯净发行版。

## 实际产物与证据层次

`native-call-update-plan.json` 固定本轮 44 个选择器。当前 MCP 取证后，又通过独立命令取得全部 44 项，错误 0、工具进程关闭成功；44 个 evidence ID 全部相同。完整观察只写入 `private/p1-round8/`。

`call-update-facts.json` 定义 17 项有限的静态指令事实。生成器要求：机器事实来自汇编查询、每个锚点地址落在其原始字节引用内、锚点按已审阅顺序出现、源 EXE 摘要与 P0 及计划一致。公开的 `call-update-report.json` 包含原始文件的相对路径、SHA-256、offset、length、范围摘要和 evidence ID，不包含完整伪代码。

顺序检查只证明选定观察中的指令顺序，不能自动证明路径必定执行或完整行为等价。指令事实是 `verified`，行为解释和语料角色继续是 `inferred`，实际执行是 `not_tested`。

## `++/--` 在 tokenizer 内调用存取函数

tokenizer 的两条路径分别传入 `+1`、`-1`，调用 `0x69fd90`。该函数查找目标，在类别 1 路径调用读取函数，修改描述符中的 32 位字段，再调用写入函数；类别 2/3 有各自分支。表达式入口先调用 tokenizer，再调用结构变换函数。证据分别是：

- `tokenizer_increment_call` / `tokenizer_decrement_call`
- `update_read_add_write`
- `tokenizer_precedes_transform`

由此形成 **Hypothesis / inferred**：被这条路径识别的更新会在词法处理阶段触发写入，早于后续结构变换与运算归约。不能直接将现有 `postfix_update_candidate` 当作 C/JavaScript 后缀语义，也不能只在循环结尾统一更新。

仍未确认：返回表达式如何捕获旧值、同名重复引用看到哪个值、嵌套索引的副作用顺序、字符串目标的处理、读写失败及后续语法失败是否回滚。当前没有按新值或旧值模型实现执行器。

`tools/value_use_analysis.py` 新增可选的 `--native-contract-report`。它核对来源摘要和必要机器事实，将规则作为 `tokenization_write_candidate` 假设关联到重新解析的脚本位置；不改变 AST 的执行置信度，不修改输入记录，不运行更新。

`update-site-report.json` 保留原有 8,130 个字段、两处空字段失败和全部排除计数；407 处更新候选获得阶段假设，其中 6 处嵌套更新另列位置。它们包含各包版本的重复出现，不是 407 条已执行路径。动态展开后可能出现的更新也不在该统计的验证范围内。

## `ret` 的可选字段指向上下文候选

二级分派的 SUB/JZ 链累计为 `0x746572`，可与已有 ASCII 命令编号候选交叉核对。选定路径首先取第一个参数并调用 `0x6c06f0`；这个函数对一条 `@@` 字面路径直接复制，对另一条路径调用表达式包装，再取字符串字段。

后续区别如下：

| 静态路径 | 已观察的操作 | 当前解释 |
|---|---|---|
| 解析结果为空 | 取上下文数量，减二 | 默认返回调用者上下文候选 |
| 解析结果非空 | 按该字符串查找上下文，结果减一 | 命名目标与非局部返回候选 |
| 合法目标 | 取对应记录、恢复不透明文件/位置字段，裁剪上下文 | 恢复调用现场候选 |
| 记录标志非零 | 通过 `+0x68` 调用额外恢复函数 | 另有辅助状态恢复，含义未完整确认 |

这些不是对“返回值”的证明。第二轮发现的两条一参数 `ret` 来自同一逻辑脚本的两个包版本；本轮将它们标注为 `context_target_expression_candidate`，未将其当作返回结果寄存器赋值。

`tools/call_update_analysis.py` 对已有 4,261 个转移记录重新核对研究副本字节，并重新词法分析，核对命令及参数数量，防止仅凭旧报告的 arity 得出结论。检查涉及 280 个源文件：

| 命令样式 | 记录数 |
|---|---:|
| `sub` | 1,804 |
| `go` | 95 |
| `ret` | 1,912 |
| `jmp` | 450 |

`ret` 中零参数 1,910 条、一参数 2 条，没有发现其他 arity。全部检查只验证来源与词法形状；运行时目标是否存在、是否真的恢复到预期现场仍未执行验证。`go/jmp/sub` 未因此获得完整转移语义，`subp/subr` 也未纳入这份旧转移语料表，报告明确列出范围。

脚本 offset 属于解码后的研究副本，不是压缩 PACK 内的偏移；包来源可通过 `corpus-report.json.items[].origin` 追溯。原生机器事实的 offset 则属于固定摘要的原始 EXE。

恢复函数使用的字段 `+4`、`+0xc`、`+0x38`、`+0x3c` 暂时保留不透明含义；未将其擅自解释成字节位置、行号或时间戳。

## 上下文裁剪会关联变量层清理

`0x6c111c` 重复移除末项，直到数量不大于目标索引加一。移除入口取得对象、调用释放入口，再删除列表项。具体虚表创建方法和完整析构链仍未知。

二级分派结束时，如果上下文数量与进入时不同，将新数量减一传到 `0x69f264`，再经包装进入 `0x6a00b8`。后者对更深非空层调用清理函数，并把层数设为新索引加一；某些路径还按容量分块释放对象。

因此“调用深度变化与变量层回收有关”有指令依据，但缓存、别名、对象引用及系统/全局存储的全部生命周期仍未闭合。不能只实现压入/弹出一个脚本返回地址而忽略变量层和额外状态。

## 参数槽与 `subr` 额外状态

共享调用路径从字段 `3 + slot` 读取最多 16 个槽。遇非零字段时，保存的数量变成 `slot + 1`；这与简单计算非空项总数不同。该数值后来传向参数数量的写入路径。类型转换、旁路模式和精确空字段到指针的构造仍需核对。

真实 `sub` 样式中的参数字段数最多 11，未发现超过所审阅 16 槽或原始稀疏空字段的案例。存在两处引号空字符串形状，已记录位置。`raw == ''` 与 `raw == '""'` 分开观察；两者不能不经原字段解析规则就等价为零指针，也没有把字段数量宣称为已确认的运行时参数数量。

编号 `subr` 的路径还调用 `0x6c17c8`，分配辅助记录并保存状态；返回时存在对应的条件恢复路径。完整记录字段和外部效果尚未恢复。保留独立状态是下一阶段的要求，不能把它归并成普通 `sub`。

两个探索性选择器也如实记录：最初命名为 `postfix-expand` 的 `0x69b2e8` 解释的是列表展开，未提供更新时点证据；名为 `context-push` 的 `0x6c17c8` 实际分配辅助记录，不能冒充尚未定位的虚表创建方法。分析文件名是研究标签，不是恢复出的原函数名。

## 独立复现

前提是已有合法的 P0/P1 研究副本、第二轮完整契约报告及已记录版本的本机工具。所有输入路径均由参数提供。

```sh
.venv/bin/python tools/rea_static.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-call-update-plan.json \
  --output private/p1-round8/native-reproduced \
  --rea-command "$REA_COMMAND" \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
.venv/bin/python tools/call_update_analysis.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --assets-dir private/real-assets
.venv/bin/python tools/value_use_analysis.py \
  --assets-dir private/real-assets --private-dir private/p1-round8 \
  --output reports/p1/update-site-report.json \
  --native-contract-report reports/p1/call-update-report.json
.venv/bin/python tools/research_checks.py --stage round8 \
  --game-dir "$GAME_DIR" \
  --artifact reports/p1/call-update-report.json \
  --artifact reports/p1/update-site-report.json
```

本轮新增 14 项合成测试：证据顺序、范围、类型和重复项检查，原始程序摘要不符时拒绝生成事实，`ret` 参数角色与脱敏，更新阶段证据约束，以及原始空字段与引号空字符串、超出已审阅槽位的保留。它们验证分析工具，不验证原游戏执行。

最终数量与完整性结果见 `round8-tests.json`、`round8-readiness.json`；两处字段失败及未验证的执行语义继续保留。下一步应优先定位虚表创建/析构方法，核对更新的值捕获、逻辑短路和错误回滚，再连接完整调用状态。存档、对象演出与事件时序仍未完成，不能宣布完整原生移植成功。

本轮实际研究环境 157 项通过；系统 Python 154 项通过、3 项可选检查跳过；上游 26 项通过、8 项商业夹具检查跳过。20 个已有摘要的原始关键文件、全部冻结 P0 报告与本轮开始前快照一致。商业内容和完整原生观察继续只在被 Git 忽略的目录中。
