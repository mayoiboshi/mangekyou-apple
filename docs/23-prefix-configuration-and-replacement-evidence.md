# 23 — 正文前缀配置与替换列表证据

2026-11-07，P1 第十二轮。只读核对第四作主程序候选和既有研究副本，未执行游戏，未开发解释器、播放器或界面。当前结果继续区分声明、选定指令、静态候选和完整执行语义。工具版本仍见 `toolchain-lock.json`，程序摘要与 P0 清单相同。

## 读取器字段获得声明名称

从原文件中的类名及自指针找到 `TImoReader`，VMT 地址 `0x694198`，Win32 声明大小 172 字节。交叉核对类名、TypeInfo、字段和方法表后，得到 28 个方法、19 个字段。与本轮相关的声明如下：

| 偏移 | 声明名称 | 当前用途范围 |
|---|---|---|
| `+0x10` | `buffer` | 声明类型名为 TStringList；完整装载语义未知 |
| `+0x1c` / `+0x20` | `FLabelIndex` / `FLabelLine` | 标签位置声明 |
| `+0x2c` | `FExceptText` | 上轮观察到的普通正文前缀字段候选 |
| `+0x30` | `FNoWordLineText` | 无内容行的替代文本候选 |
| `+0x34` | `FRepList` | 替换列表声明 |
| `+0x38` / `+0x3c` | `AbsLine` / `AbsPos` | 位置声明；不等同于研究副本字节偏移 |
| `+0x4c` | `data` | TSRSaveData 声明；本轮没有解析其完整布局或存档 |
| `+0x9c` / `+0xa0` | `TempBuf` / `TempBufLength` | 当前处理缓冲区声明 |

该类的初选计划误读三个正向槽，将后随数据当成代码指针，探针明确拒绝。本轮计划改为只读取已核对的 `-4` 析构槽，正向槽数为零，仍检查类自指针、类型、方法地址及字段边界。**这不表示对象不存在虚方法，也不表示掌握完整 ABI。** 错误的初选假设在 `text-prefix-report.json.rejected_slot_assumption` 保留为 `unsupported`。

相应修正元信息报告：若尚有未作槽位比较的方法，不再仅因“矛盾数为零”就写完整覆盖为 verified。当前一项比较匹配，27 项为 `not_tested`；28 项方法签名仍未解释。`reader-metadata-report.json` 给出每个声明的原始字节引用，元信息访问累计 5,405 字节，包含重复读取。

## et / nt 的条件赋值路径

在选定的 `0x6ba248` 分派器中，编号减法链将 ASCII `et` 和 `nt` 引向两个参数解析路径；它们分别向读取器 `+0x2c`、`+0x30` 赋值。初始化和替换列表重置路径都存在清空这两个字段并启用替换开关的候选行为。

这是有原生指令及类型声明支持的 **Hypothesis**，前提是脚本命令实际进入该对象分派器。相同短命令名可能用于其他对象，本轮没有通过名字自动绑定运行对象，也没有假定配置命令按文件顺序一定执行。

对 379 份副本重新哈希和词法解析后，得到：

| 项目 | 数量及范围 |
|---|---|
| et 候选记录 | 4，均为单参数 |
| nt 候选记录 | 4，均为单参数 |
| 非空单个双引号字面量形状 | 4，开头为反斜线，内部词法观察出现 subp |
| 空字符串字面量形状 | 4，不推定运行时空指针语义 |
| 涉及的物理文件版本 | 2，均保留，不自动选择覆盖优先序 |

这八项仅分布于 `data7.pack/avg/imoscripter_format.s` 和 `data8.pack/avg/imoscripter_format.s` 两个版本。不能将条数误当成八份互相独立的配置，也不能据此认证纯净发行版或启动可达性。

新增 `text_prefix_analysis.py` 只检查单个双引号对的字面量形状，记录前导字符类别、长度和候选命令名称。表达式拼接、嵌套引号和变量不求值；超限、控制字符及超出有界 ASCII 命令形状的项显式记录未知或拒绝。公开报告不保存前缀全文、选择对象参数、台词或其他参数值；参数始终可由父字段的源文件摘要、字节偏移、长度和区间摘要追溯。虚拟字面量内的词法位置没有冒充原始脚本字节位置。

`namespace_binding`、`actual_startup_reachability`、`generated_command_semantics` 均为 `not_tested`。同一行 scp 参数只形成脱敏的词法上下文指纹，不当成实际对象解析。前缀中的 subp 必须继续核对；不能用普通 sub 或顺序显示台词代替其执行行为。

## 两个预处理入口与五类替换路径

`0x69687c` 的伪代码显示空函数体，但汇编实际上是比较 `+0x58` 的字节后返回。早期将其概括成“只有返回”不准确，已用汇编纠正。比较会影响处理器标志并读取内存，不能宣称全局无操作；本轮只确认该本体未观察到字符串写入。

`0x695ce4` 在开关非零且列表非空的选定路径上，从 Count-1 开始倒序取项。首字段为零时跳过，第三字段经无符号上限 4 检查后进入分派。五个区域分别调用 `0x4e08f0`、`0x6675f8`、`0x667978`、`0x667828`、`0x667918`。它们是否涉及字面替换、模式匹配、捕获组、大小写和空匹配，本轮没有确认，不给模式编号猜名字。

原程序还保留 `TReplaceData` 声明：大小 12 字节、两个受管理字段、三个字段。

| 偏移 | 原样保留的声明名 | 类型名 |
|---|---|---|
| 0 | `SerchWord` | string |
| 4 | `ReplaceWord` | string |
| 8 | `_Type` | Integer |

`SerchWord` 的拼写来自原始元信息，未作修正。第三字段的 Integer 声明本身不等于完整模式枚举。

新增项和已有项还存在优先序风险：比较助手返回零的路径更新三个字段后直接跳向尾部；另一条分配和插入路径才调用排序。排序回调读取首字段并调用 `0x4149b4`，已有项匹配使用另一个助手 `0x414b08`。二者的比较规则、区域设置、大小写处理及排序稳定性均未知，不能直接用宿主字典或一次普通 replace 代替。

这些结论由 `native-prefix-facts.json` 的 12 项指定指令事实和 `prefix-native-report.json` 的引用支持；高层解释保留 `inferred`。模式、排序、字符串转义及完整执行语义仍为 `not_tested`。

## 默认覆盖缺口与失败保留

独立命令重新完成 29 项观察，错误数零、清理完成；这只表示采集完成。读取器构造函数、排序回调和创建调用所在位置均没有默认包含函数，其中两处还无法默认解码，合计五项覆盖缺口。排序回调虽未归入函数，其入口指令可被默认解码，二者没有混为一谈。

早期两次直接请求构造函数和回调伪代码失败，REA 的地址回退最终报告无文件偏移映射。它们记录在 `historical_failed_lookups`，没有把失败说成空函数，也未反复重试相同请求。后续只用已固定源摘要的选定 LLVM 窗口核对局部指令。

初始窗口和最终收窄窗口分别保留。初始创建窗口从算术偏移开始，线性解码起点缺乏函数边界证据；最终仅审阅构造调用和已观察上下文，仍不宣称完整父函数或实际可达性。所有窗口的边界解释为 inferred，解码成功不等于指令会执行。

新扫描的首次真实尝试曾错误假定所有词法辅助记录都有行号，报错后生成私有失败报告。现仅在命令记录上读取行号，并增加 BOM、空白及同行上下文回归测试。开发夹具还修正了临时目录别名和选择命令写法；生产中的符号链接拒绝规则保持有效，没有修改游戏或上游来使测试通过。

## 复现

使用者提供环境变量与合法受限副本。原始目录只读，计划只适用于固定程序摘要。

```sh
.venv/bin/python tools/delphi_metadata.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-prefix-metadata-plan.json --output reports/p1/reader-metadata-report.json
.venv/bin/python tools/rea_static.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-prefix-plan.json --output private/p1-round12/native-reproduced \
  --rea-command "$REA_COMMAND" \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
.venv/bin/python tools/native_windows.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-prefix-initial-windows.json --output private/p1-round12/windows-initial
.venv/bin/python tools/native_windows.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-prefix-windows.json --output private/p1-round12/windows
.venv/bin/python tools/review_native.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-prefix-plan.json --facts docs/native-prefix-facts.json \
  --evidence-dir private/p1-round12/native-reproduced \
  --windows-dir private/p1-round12/windows \
  --exploratory-windows-dir private/p1-round12/windows-initial \
  --output reports/p1/prefix-native-report.json
.venv/bin/python tools/text_prefix_analysis.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" --assets-dir "$ASSETS_DIR"
.venv/bin/python tools/research_checks.py --stage round12 --game-dir "$GAME_DIR" \
  --artifact reports/p1/reader-metadata-report.json \
  --artifact reports/p1/prefix-native-report.json \
  --artifact reports/p1/text-prefix-report.json
```

如需附带本机的两次历史失败，review_native 命令可额外接收 `--attempts-file private/p1-round12/default-query-errors.json`。不提供该历史输入仍能独立重建实际指令和字段结论，不会伪造过去失败。

新增两个零正向槽/边界测试和十个前缀测试，覆盖参数脱敏、空字面量、复杂表达式不求值、超限、源位置、版本保留、符号链接拒绝和 BOM 辅助记录。新工具最多 2,000 个文件、128 MiB 总输入、512 个记录、单字段 8,192 字符，独立命令限制 120 秒；失败写入私有目录。复用既有只读辅助和词法探针，不引入第三方执行后端。

下一步最有价值的是核对 subp 与这两份格式脚本的对象绑定，以及五个替换助手和两个比较助手的真实规则。完整正文演出、等待、分支恢复和存档仍未闭合，目前仍不能宣布原生移植完成。

最终研究环境 212 项通过；系统 Python 209 项通过、3 项可选集成检查跳过；上游 26 项通过、8 项商业夹具检查跳过。跳过不计成功。`round12-readiness.json` 还核对了 20 个原始关键文件摘要和冻结 P0 报告，本轮前后保持一致；这不等于对全部游戏文件重新哈希或验证整作兼容。
