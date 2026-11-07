# 33 — 文件字段、跨文件调用与版本选择

本轮已将上一轮停止的双参数 `sub` 接入原生实验核心，并在 GUI 和命令行验证跨文件进入。没有运行原版 EXE/DLL，也没有把资源检查器或局部运行称为完整移植。**完整游戏仍不能开始。**

## 原程序中的依据

固定主程序摘要沿用 P0。通过 REA/Ghidra 读取选定路径，再用独立进程复取 9 项观察、核对 8 项指令事实；错误 0，分析清理完成。定义在 `docs/native-module-plan.json`、`native-module-facts.json`，脱敏结果在 `reports/p1/module-native-report.json`。原始伪代码/汇编仍只在 `private/p1-round22/`。

已核对的事实：

- `0x6b76d8..0x6b7737` 读取字段索引二、转小写、比较 `self`，并把零字段指针导向同一个默认分支。
- `0x6b7737..0x6b7775` 对另一路字段求值并调用转换助手；没有由此宣称已掌握所有对象/数字到文件名的转换。
- `0x6b7775..0x6b778d` 向读取器 `0x695c34` 传递选定文件和规范化目标，随后检查 AL。
- `0x695c34` 的选定指令将非 self 文件交给 `0x69556c`，通过条件后才调用标签定位 `0x696134`。
- 标签定位先检查未找到的 `-1`，命中后更新索引/偏移并进入行读取。加载路径另有更新对象 `+0x24` 字符串的选定指令。

结合既有“字段三起才是参数槽”的证据，**第二个字段是此调用路径上的文件选择，不应直接当作第一个业务参数**。完整契约仍为 `inferred`。加载 helper 的默认反编译体在清理 RET 截断，尚未补证全部正常返回、文件预处理或异常展开；本轮不借 caller 的 AL 检查宣称恢复了完整 callee ABI。源码声明、机器指令事实和新运行时的行为分别记录。

## 原生实现

`ScriptRepository.swift` 提供只读来源目录与显式目录表，目录表绑定逻辑文件名、物理相对路径和 SHA-256。没有增加 PACK 解包算法，也没有把无许可证解析器塞进应用。

`experimental_static_contracts_v2` 对 `sub` 支持一个字面目标及可选文件字段：

1. 缺省文件、裸 `self` 或字符串值 self 保留当前程序。
2. 其他字符串值只从显式目录表查找；拒绝绝对路径、路径穿越、非法分隔、符号链接、摘要变化和目录表之外的文件。
3. 同一逻辑文件若各版本字节相同，只作确定性的来源选择；这不是包优先级证明。若摘要不同，默认停止在 `ambiguous_module_variants`，不会选择“最新”或覆盖文件。
4. 调用进入新候选局部帧，保留调用者程序快照和下一记录位置；零参数 `ret` 恢复来源程序及调用者局部状态。跨文件返回由自建样本验证，真实片段尚未走到返回。

对象/数字文件转换、原始空字段到零指针的映射、后续参数槽、动态目标、跨文件 jmp/go、subp/subr 仍未实现。包含 include 的目录表程序会拒绝装载，因为原程序在标签定位前有包含/预处理路径，不能把未经展开的标签表冒充同一结果。快照缓存是新运行时策略，不声称原版的重载或错误回滚行为相同。

路径比较使用 ASCII 大小写折叠，字节键避免 Swift String 自动将不同 Unicode 组合序列视为同一标识符。没有据此认定原引擎所有 Unicode 路径规则已验证。原有整数、条件块和单指令原子提交限制保持不变，详见 `docs/runtime-profile-v2.json`。

GUI 对已有研究副本采用显式 `dataN.pack/相对资源名` 目录布局适配；这里的 `dataN.pack` 是**研究目录**，不是被应用打开的归档。每个候选文本都计算摘要；实际调用时仍须通过文本解码和结构检查。该适配不推断原游戏的散文件根目录或挂载顺序。其他布局可通过原生命令行提供显式目录表。

## 三条真实验证路径

保留全部 379 份已有文本，原生与 Python 的解码、逐字符原始字节跨度及记录/字段摘要交叉核验仍无差异，共 291,273 条记录。这是项目模型之间的一致性，不是原引擎 oracle。

从固定摘要的 `data0.pack/startup.s`、全新的候选状态运行：

| 实验 | 实际结果 | 当前限制 |
|---|---|---|
| 不指定版本 | 处理 20 条记录，停在入口副本字节 1,012 | 目标 `misc/value.s` 在 data7/data8 中摘要不同，未进入任何一个 |
| 显式选 data7 副本 | 处理 25 条记录，进入该副本，停在字节 35 | 尚未实现的 `table` 类型变量声明 |
| 显式选 data8 副本 | 处理 25 条记录，进入该副本，停在字节 72 | 同类未支持声明；不能把偏移差异当成兼容性优劣 |

三个命令行调用均返回退出码 2，实际 `unsupported` 停止保留在机器报告。后两条证明本机新运行时发生了有来源可查的跨文件调用，**没有证明两版都是原游戏实际采用的版本，也没有证明整段启动成功**。初始系统计数器的零值等沿用候选模型，不能外推原存档/原程序初始化后的路径。

`reports/p1/module-execution-report.json` 分别保留 24、30、30 项核对过的源字节引用，包含跨文件目标和条件跳过区间。验证器只从锁定语料查找被引用文件，每个文件单独检查全文摘要、范围摘要、记录、命令和行号；不再把所有 offset 都错误地套在入口文件上。新增反例验证未经授权的外部来源、错误目标摘要和新增正文/变量字段都会被拒绝。

GUI 0.3.0 已实际导入全部 410 份副本，筛选启动文件，观察到默认歧义停止和两个版本选项。明确选 data8 后，界面显示已处理 25 条记录、调用深度 3、载入 2 个脚本，停在该副本第 8 行、字节 72。选择后从头重查，不继承上一次实验状态，也不写存档。只观察元数据与诊断，未上传商业正文/图像/声音。独立 GUI 自动重放仍为 `not_tested`。

## 测试、限制与复现

本轮新增 10 项 Swift 模块测试，全部原生测试共 48 项通过；新增一项多来源轨迹反例后，Python 边界测试共六项。覆盖双向跨文件来源恢复、调用者/被调者局部隔离、不同版本的默认拒绝与显式选择、相同字节别名、路径和摘要检查、Unicode 标识符、self、include 拒绝以及快照预算。

最终整体检查见 `round22-readiness.json`：研究 Python 297 项通过；系统 Python 294 项通过、3 项跳过；上游 26 项通过、8 项商业夹具缺失跳过。跳过不计成功。20 个既有关键原文件摘要及冻结 P0 报告保持一致，三个新增公开报告通过正文/原始参数字段检查。检查通过不等于完整运行时完成。

目录表最多 2,000 项，程序快照最多 512 个、累计 128 MiB，单文件 16 MiB；沿用 64 帧、默认 10,000 步、文本/表达式数量与单调时钟限制。导入根目录和原始游戏目录均只读。公开报告仅为元数据，完整本机输出在 `private/`；全作运行、音画、存档及 M4 性能仍未完成。

```sh
swift test --package-path native
python3 tools/build_native.py
open build/Mangekyou.app
.venv/bin/python tools/verify_module_execution.py --assets-dir "$ASSETS_DIR" \
  --script-file data0.pack/startup.s \
  --compare-source data7.pack/misc/value.s --compare-source data8.pack/misc/value.s
python3 tools/verify_native.py --game-dir "$GAME_DIR" --assets-dir "$ASSETS_DIR" \
  --output reports/p1/native-app-round22.json
.venv/bin/python tools/research_checks.py --game-dir "$GAME_DIR" --stage round22 \
  --artifact reports/p1/module-native-report.json \
  --artifact reports/p1/module-execution-report.json --artifact reports/p1/native-app-round22.json
```

上述 `$ASSETS_DIR` 为此前合法取得的研究副本根目录。原生单次运行可使用 P1 自有元数据格式，未指定 `--select-source` 时保持严格歧义拒绝：

```sh
swift run --package-path native mangekyou-script --assets-dir "$ASSETS_DIR" \
  --script data0.pack/startup.s --experimental-run \
  --catalog reports/p1/corpus-report.json --select-source data8.pack/misc/value.s
```

从零重新采集本轮静态观察：

```sh
.venv/bin/python tools/rea_static.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-module-plan.json --output private/p1-round22/native-reproduced \
  --java-home "$RESEARCH_JAVA_HOME" --ghidra-dir "$RESEARCH_GHIDRA_DIR"
.venv/bin/python tools/review_native.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-module-plan.json --facts docs/native-module-facts.json \
  --evidence-dir private/p1-round22/native-reproduced --output reports/p1/module-native-report.json
```

## 下一项实际阻塞

脚本执行已从“不能识别文件字段”推进到 `table` 对象声明。下一步应实现有依据的对象/表存储、作用域和调用参数接口，再连接其后出现的对象指令；不能先放一个空 table 或跳过声明让启动计数变长。

资源导入依然缺少分发许可明确、经过验证的归档内容读取。固定 GPL mangekyoupack 的 `filepack31.c` 包含 x86 MMX 类型/操作，已有 P0 构建证据不足以支持直接在 ARM64 调用；本轮只是复查来源，不声称完成移植或新的构建验证。无许可证 qlie-unpack 仍仅限研究。后续若复用 GPL 工具需完整处理相应义务，独立进程不是许可豁免；不能为推进界面就把该阻塞藏掉。
