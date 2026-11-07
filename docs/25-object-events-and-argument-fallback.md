# 对象事件与参数转换回退：P1 第十四轮

本轮继续限定的静态研究。SDKMAN 的 Microsoft Java 21.0.13.0.2、REA 6.8.0 和 Ghidra 12.1.4 已实际配合完成分析，ARM64 反编译器可用。系统默认 Java 8 保持原状。版本和来源见 `toolchain-lock.json`；没有运行游戏、实例化游戏对象或改变原版目录。

证据输入仍是 P0 固定摘要中的主 EXE，SHA-256 为 `ad02b1115887b8e5b453d4b5760077e8b63e153bba1161e1704209cf3db5cda5`。文件身份核对不能证明它是未经修改的原发行程序。所有地址仅适用这一输入。

## 产物与证据层次

| 产物 | 范围与状态 |
| --- | --- |
| `reports/p1/callback-metadata-report.json` | 五类、一个记录的声明字节已读出；关联解释为 `inferred` |
| `reports/p1/callback-native-report.json` | 22 项静态查询、11 项选定指令事实；执行语义 `not_tested` |
| `reports/p1/object-callback-report.json` | 有界只读字节探针，事件布局、初始化存储、两处工厂调用、值标签与参数符号 |
| `reports/p1/round14-tests.json`、`round14-readiness.json` | 自动化、上游适配、原版关键摘要与 P0 冻结检查；不代表完整 P1 验收 |
| `private/p1-round14/` | 原生代码正文、完整 MCP 证据、独立采集、探索窗口和历史失败，禁止提交 |

指令事实的 `verified` 仅表示指定地址的指令及顺序与输入一致。跨函数绑定、数据用途及回退模型分别保持 `inferred`，不把静态链当作实际执行轨迹。上游解析器、商业样本及脚本提取的既有证据范围沿用 P0/P1 原报告，没有在本轮重新宣称覆盖。

## 四个事件声明与绑定

`TValueArrayEventSet`（类型地址 `0x697bc0`、扩展字段计数 `0x697bde`）声明尺寸 32 字节、无托管字段，含四个 kind 8 方法类型：

| 声明名 | 记录内 Code / Data 偏移 | 初始化 Code 值 |
| --- | --- | --- |
| ObjectCreate | 0 / 4 | `0x6bee50` |
| ObjectDestroy | 8 / 12 | `0x6bee38` |
| ObjectSave | 16 / 20 | `0x6bef7c` |
| ObjectLoad | 24 / 28 | `0x6bef28` |

名称、偏移、类型编号来自真实 RTTI；Code/Data 两部分的解释参照 [TMethod 文档](https://docwiki.embarcadero.com/Libraries/Athens/en/System.TMethod)，kind 8 对应方法类型的解释参照 [TTypeKind 声明顺序](https://docwiki.embarcadero.com/Libraries/Athens/en/System.TypInfo.TTypeKind)。文档用于格式对照，没有复制厂商实现，也未据此认定游戏编译器版本或完整方法签名。

初始化窗口 `0x6beb3a..0x6beb77` 显示四组 EBP 相对存储，Data 来源均为 ESI，随后把记录地址传给 `TImoCalculation.Create`（`0x69a8c4`），将返回值写到实例 `+0xe8`。只读探针校验精确存储编码和可映射代码目标，不能验证 ESI 的运行时身份。

构造与注册的证据链如下：

1. `0x69a8c4` 复制八个 DWORD，将同一栈副本传入两次 `TValue.Create`（`0x69a4d8`）和一次 `TValueIndex.Create`（`0x69ffc0`）。依据 `manager_forwards_record`。
2. `TValue` 声明 `FEventSet +0x10`；其构造将 32 字节记录复制到该位置。依据 `table_event_copy`。
3. `TValue.Entry` 的选定分支将表 `+0x10` 传给 `TValueArrayObject.Create`（`0x69e560`），后者复制到 `+0x48`。依据 `register_forwards_event_set`、`object_event_copy`，及 `TValueArrayObject.FEventSet` 声明。
4. 数组增长的选定窗口 `0x69e8b8..0x69e8c4` 从 `+4`、`+0xc` 取参数，以 `+0x4c` 为 EAX，间接调用 `[对象+0x48]`。与事件记录布局对应的链保持 **Hypothesis / `inferred`**，实际到达、后续重赋值和命名空间遮蔽 `not_tested`。

特别保留一项异常：紧前方 `0x69e8aa` 检查的是 `[对象+0x52]` 的 WORD，不能把它改写成“检查创建回调是否存在”。该偏移与声明的另一槽位有交叠，其原因未知，完整增长路径尚未解释。

创建桥接 `0x6bee50` 在 `0x6bee67` 直接调用 `0x6befa8`；读取桥接 `0x6bef28` 在 `0x6bef41` 也调用该工厂。两处 E8 编码与目标均由原字节复核。前轮已观察到工厂的 `rep` 分支与类型编号 14；本轮补上静态创建路径的连接，**没有验证注册必然执行或运行时一定选中它**。

默认 Ghidra `xrefs(0x6befa8)` 只列 `0x6bef41`，没有列出 `0x6bee67`。因此空或不完整交叉引用不能证明不存在调用。公开报告保留 `native_xref_completeness=unsupported`，依据是本次返回与两处直接调用字节的对照，不能外推至其他工具或版本。

## 值类型与参数回退

表基类的 `FType +0x10` 指向 `TScriptValueType`，真实枚举声明为：0 `vtInteger`、1 `vtString`、2 `vtObject`、3 `vtUnKnown`、4 `vtError`。这是声明字节验证，不是各类型全部行为的验证。

共享调用参数路径的静态观察：

- `call_conversion_mode`：转换前传零给 `SetErrorMode`（`0x69d780`），转换后传一；助手名由方法表交叉核对，助手实际写 `+4` 并向关联表传播。异常路径是否恢复未知。
- `argument_tag_four_branch`：`0x6b7890` 比较局部描述符首字节与四。
- 等于四时，`fallback_integer_source` 将原始字符串和整数默认值零传入 `0x415a90`，再写 `ParamInt`；`fallback_string_source` 将同一原始字符串传入 `ParamStr` 写入入口。
- `integer_helper_default`：底层整数转换报告非零错误槽时，该助手返回保存的默认值。整数格式的既有假设模型见第六轮；没有新增表达式求值器。
- 非四时，`descriptor_field_sources` 使用描述符里的整数、字符串字段。包括声明值三在内的其他标签没有分别恢复语义，不能统一称为“求值成功”。

`ParamInt`、`ParamStr` 符号由两处 UTF-16 常量、长度前缀和终止符核对。没有输出商业脚本参数或正文。

结论是受限的 **Hypothesis**：在这一调用参数路径，声明值 `vtError` 会触发原文本回退，并非所有出现它的地方都必然中止脚本。实际参数的标签、转换结果、副作用与错误恢复仍 `not_tested`。`subp` 此时的“原始字符串”也可能已经过上一轮观察到的尾字段合并，不能冒充原文件未处理字节。

`TValueArrayObject.GetValue` 的线性窗口另外显示：写标签二、整数零，从 `FData +0x40` 取元素后调用 `0x407460`。结合字符串助手的既有解释，它更接近字符串形式的对象标识；这一用途仍 `inferred`。匿名数组元素类型、句柄全生命周期与对象身份未知，不能仅凭类名将它实现成原生对象指针数组。

## 覆盖缺口、测试与失败

五个选定入口的默认函数查询返回 `found=false`：对象取值、增长、初始化，以及创建、读取桥接。采用 LLVM 的五个有界选定窗口补充观测，窗口边界仍 `inferred`；未修改默认函数数据库来制造通过结果。

五类共 78 项方法声明中，仅四项已检查的析构槽位匹配，其余 74 项未比较；全部 78 项签名尾部尚未解释，两处字段缺少类型引用。元信息报告 `metadata_binding_coverage_status=not_tested`，没有把“未发现冲突”记作全覆盖。

探索窗口保留了过宽范围线性解到数据的历史样本；三个窗口共 12 个 `<unknown>` 地址在 `exploratory_windows` 单列，其中两个位于创建桥接之后的数据区域。最终选定窗口缩到受审查的代码跨度，未删除探索记录。第一次直接请求缺失函数的伪代码失败、一次命令输入编码失败及随后缺少事实计划的复核失败，均列入 `historical_failed_lookups`，纠正后再运行；这些失败不是兼容成功。

新增测试位于 `tests/test_object_callback_probe.py`：正确布局与证据边界、类型编号混淆、错名/错偏移、大小/托管字段/属性限制、创建与读取区分、存储编码破坏、越界目标、E8 调用与跳转混淆等九项，全部使用自建样本。系统 Python 的 Pillow 缺失跳过项与上游缺少商业夹具的跳过项继续单列，不算通过。

本轮实际回归：研究 Python 237 项通过、零跳过；系统 Python 234 项通过、3 项跳过；上游 26 项通过、8 项商业夹具缺失跳过。20 个关键原始文件的 SHA-256 与 P0 一致，P0 文件还与本轮开始前的独立快照逐项一致。没有将这些检查外推为全目录不可变证明或运行时兼容证明。

当前仍不足以进入完整运行时开发。下一步合理范围是：在保留字节位置的前提下统计调用参数的结构候选，研究对象标识与存储归属、异常恢复及正文替换的五种模式。不要先执行参数或顺序播放台词；存档完整布局、音画时序和执行等价仍阻塞原生移植。

## 独立复现

使用者自行设置合法输入 `GAME_DIR`、相对 EXE 名 `EXE_REL`，以及自己的 `JAVA21_HOME`、`GHIDRA_DIR`；代码未硬编码本机游戏路径。所有分析均在本机完成，不上传数据。

```sh
.venv/bin/python tools/delphi_metadata.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-callback-metadata-plan.json --output reports/p1/callback-metadata-report.json
.venv/bin/python tools/object_callback_probe.py --game-dir "$GAME_DIR" --exe "$EXE_REL"
.venv/bin/python tools/rea_static.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-callback-plan.json --output private/p1-round14/native-reproduced \
  --java-home "$JAVA21_HOME" --ghidra-dir "$GHIDRA_DIR" --analysis-budget-seconds 600
.venv/bin/python tools/native_windows.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-callback-selected-windows.json --output private/p1-round14/windows-selected
.venv/bin/python tools/native_windows.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-callback-windows.json --output private/p1-round14/windows-full
.venv/bin/python tools/review_native.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-callback-plan.json --facts docs/native-callback-facts.json \
  --evidence-dir private/p1-round14/native-reproduced --windows-dir private/p1-round14/windows-selected \
  --exploratory-windows-dir private/p1-round14/windows-full --output reports/p1/callback-native-report.json
.venv/bin/python tools/research_checks.py --game-dir "$GAME_DIR" --stage round14 \
  --artifact reports/p1/callback-metadata-report.json --artifact reports/p1/callback-native-report.json \
  --artifact reports/p1/object-callback-report.json
```

`--attempts-file private/p1-round14/default-query-errors.json` 可用于附加已保存的历史失败；不传时不会伪造失败历史。MCP 证据另存于 `mcp-evidence-bundle.json`；22 个查询的 Evidence ID 均与独立采集一致，对照结果在 `independent-comparison.json`。脱敏摘要来自固定计划和工具输出，完整证据保留在忽略目录中。
