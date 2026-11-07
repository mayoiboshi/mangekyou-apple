# 正文替换路径与大小写规则：P1 第十五轮

本轮继续第四作的限定静态研究，没有运行游戏或实现替换执行器、解释器、播放器和应用界面。REA/Ghidra 只分析固定摘要的主程序；正文副本仍从 `--assets-dir` 读取，保留不同包里的版本。主程序身份与 P0 相同，不能据此认证原版发行完整性。

## 实际交付与证据范围

| 产物 | 实际范围 |
| --- | --- |
| `replacement-native-report.json` | 52 项独立复现查询、12 项选定指令事实；整体 `inferred`，执行 `not_tested` |
| `replacement-metadata-report.json` | 五个正则相关记录声明，累计元信息读取 1,702 字节；没有读取完整方法 ABI |
| `replacement-audit-report.json` | 五个字节常量、五项模式分派、379 份真实副本上的脱敏词法候选 |
| `tools/replacement_audit.py` | 可重运行的只读、有界扫描与字节核对，不调用任何正则引擎或脚本求值器 |
| `round15-tests.json`、`round15-readiness.json` | 自动化、上游适配、关键原始文件摘要和 P0 冻结检查 |

文件均位于 `reports/p1/`。完整反汇编、伪代码、MCP 证据与独立比较保留在忽略目录 `private/p1-round15/`，不提交商业代码正文。

`verified` 只用于原文件声明字节、指定指令、表项与调用目标等原子证据；分支用途是 **Hypothesis / `inferred`**。没有用当前标准库的同名 API 为这个游戏背书。源码声明、上游测试和本地测试沿用既有 P0/P1 范围；本轮没有声称增加真实引擎执行覆盖。

## 五项分派与共享实现

`replacement-audit-report.json.native_byte_checks` 重新检查 `0x695d58` 的无符号上限四、`0x695d68` 的五项跳表，以及各区域直接 E8 调用。负模式值也不能被有符号比较的假设误放行。

| 模式值 | 区域入口 | 助手 | 有限的静态解释 |
| --- | --- | --- | --- |
| 0 | `0x695d7c` | `0x4e08f0` | 条件选择标志后调用字面搜索与替换路径 |
| 1 | `0x695d9f` | `0x6675f8` | 取匹配相关列表；Count 为正时，将替换字段、原文本传给双字符串助手 |
| 2 | `0x695dd9` | `0x667978` | 转发到模式四助手 |
| 3 | `0x695dfc` | `0x667828` | 取得字符串片段列表；非空时清空结果，再循环拼接 |
| 4 | `0x695e71` | `0x667918` | 经记录包装调用正则相关替换后端 |

模式二的 `0x667978` 保存并转回原有寄存器与栈参数后调用 `0x667918`，没有观察到另一种模式算法。依据 `mode_two_forwards_to_four`。这只证明此输入版本的选定静态包装关系，不证明两个模式在所有动态环境里已经执行等价。

模式一第三参数为零，助手中相应路径枚举匹配相关记录，将字符串加入列表。分派器只检查列表 Count 是否为正，不逐个执行替换。其后调用 `0x407934` 的参数来源是替换字段和原文本，形似加前缀；本轮没有独立验证该字符串助手的全部别名/分配行为，仍不把它写成 Verified 的文本变换。

模式三包装最终形成字符串动态数组并复制到列表。分派器在正 Count 路径清空输出；每轮依次压入旧输出、替换字段、当前片段，然后以数量三调用 `0x407a18`。因此不能直接用宿主的普通 `join` 冒充：首片段前的字段处理、空片段、捕获结果和异常路径仍需核对。对应 `mode_three_clear_and_concat`，没有执行实际替换。

## 正则记录声明与后端差异

有界元信息探针新增只读的“仅记录”计划，不再为了读取记录而要求存在一个无关类；空计划、重复种子和超过十六项的类别仍拒绝。未请求类的报告将虚表关联覆盖写为 `not_tested`，不会因零项比较而产生虚假的 Verified。

| 记录声明 | 字节数 | 相关字段 |
| --- | --- | --- |
| TGroup | 20 | FIndex、FLength、FSuccess、FValue、FGroupName |
| TGroupCollection | 8 | FList、FNotifier |
| TMatch | 36 | FNotifier、FGroup、FGroups、FRegExp |
| TMatchCollection | 4 | FList |
| TRegEx | 24 | FNotifier、FEvaluator、FRegExp |

其中 TRegEx 的 `FRegExp +0x10` 和 TMatch 的 `FRegExp +0x20` 都引用声明名 `TSkRegExp`。这是声明和静态调用支持的后端线索，源码版本、是否修改过、完整语法与许可仍 `not_tested`；没有取得或内嵌该实现。

当前 [Delphi TRegEx 文档](https://docwiki.embarcadero.com/Libraries/Athens/en/System.RegularExpressions.TRegEx) 描述的是 TPerlRegEx/PCRE 路径，布局和字段也与本次输入不同。因此既不能据同名记录认定 PCRE 兼容，也不能将 Python、ICU、Swift Regex 等库直接当成经过验证的替代品。相同名称只提供调查线索。

三个模式助手读出的选项常量均为 `0x11`，原字节位置分别是 `0x667824`、`0x667914`、`0x667974`。`regex_option_bit_mapping` 显示位 `1/2/16/4/32` 分别调用引擎选项编号 `0/1/3/2/4`；另有位八条件调用另一引擎助手。没有把这些位命名为“忽略大小写”“多行”等，因为本轮在文件中未找到可对应的精确 TRegExOption 枚举声明，[当前选项文档](https://docwiki.embarcadero.com/Libraries/Athens/en/System.RegularExpressions.TRegExOption) 也不能证明旧版或定制实现的编号。

在选定后端循环 `0x663cd0`，取某个匹配相关长度值后，非正值绕过输出块，随后仍有推进调用。依据 `engine_positive_length_gate`。这不等于完整掌握零宽匹配：终止、推进、捕获、替换模板及错误处理都尚未确认，禁止用宿主默认规则填空。

## 字面路径与两套大小写规则

模式零的包装先调用 `0x4e0880`，再根据返回 AL 选择常量二或三传给 `0x41e80c`。常量字节与分支均有定位依据。后者检查标志二以选择比较转换，检查标志一以选择是否继续搜索原文本剩余部分。**Hypothesis**：这是“首处/全部”替换的条件切换，不能统一改成始终全部替换。

`contains_lower_and_position` 显示它先处理两个输入，再查询子串位置并据正值写 BL。宽字符路径的 `0x41493c` 只对 ASCII A–Z 作 OR `0x20`，按两个字节前进。结合包装输入来源，形成“替换文本包含搜索文本时选择另一标志”的候选解释；非宽路径和全部返回语义没有执行验证，不推断它的设计动机。

这里还遇到默认分析缺口：`0x4e0880` 的默认函数体停在清理调用后的 RET，伪代码因此显示 void；它不是没有返回值的充分证据。文件中 `0x4e08e8..0x4e08f0` 实际包含 `MOV EAX,EBX` 和恢复/返回序列，已保存为独立 LLVM 窗口。正常返回解释仍为 `inferred`，没有修改分析数据库或执行该函数。

`0x41e80c` 的另一比较路径调用 `0x414c3c`，后者调用导入的 `CharUpperBuffW`。此 API 的用途是原位大写转换，且有 Windows 特定规则；例如它对 i 的处理不能简单照搬语言区域习惯。[Microsoft API 文档](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-charupperbuffw) 支持这一平台接口含义，**没有证明 macOS 的转换结果已与它等价**。

登记查找的 `0x414b08` 又是另一条路径：两个 WORD 的失配分支分别对 ASCII a–z 减 `0x20` 后作差。排序回调所用 `0x4149b4` 的首 WORD 失配路径则直接作差。对应 `lookup_ascii_folding`、`sort_word_subtraction`。此前“新增才排序、命中只更新”的观察继续成立，但完整比较规则、排序稳定性和宽字符串表示仍未闭合，不能用 Python `casefold` 或宿主字典默认顺序替代。

## 实际剧本的候选范围

对全部 379 份受限副本重新验证摘要并用显式 `native_grouping` 模式扫描，发现 563 个 `a` 命令拼写。不同对象都可能使用这个短名称，**这不是 563 个已证实的替换登记**。

- 321 项具有两个文本字段和可选第三字段的词法形状；242 项的形状超出本轮审查范围，保留 `unsupported` 与原因，不能解释成游戏不支持它们。
- 309 项省略模式字段；另外 12 项第三字段不是精确单个 `0..4` 十进制字面量。没有进行求值，`mode_literal_counts` 为空，没有伪造模式分布。
- 仅六项存在同一物理行的 `scp,rep` 字面量提示，涉及 `data7` / `data8` 的三个逻辑脚本的两份版本。这六项全部省略第三字段，其中四项具有简单双引号模式形状，另两项为表达式或复杂引号形状。
- 四个简单引号候选含 `^` 字符，但只记录字符统计，未运行或验证正则语法。不能因出现它就认定实际使用正则模式。

最重要的新缺口是 **省略模式时的处理**：仅根据文本外形，不能擅自设默认零。控制参数仍经过原引擎的字段取得与表达式转换路径，其补齐、缺项值和对象解析尚未确认。下一步应优先跟踪这个真实出现的路径，再选择替换执行方案。

同行提示、标签范围内最近提示分别保存，均不能当成实际对象绑定。跨行提示不冒充同行证据；跨标签清除候选提示，包含与运行时恢复规则继续未知。公开报告没有正文、模式全文、替换全文或逐条模式参数值；只有字节引用、字段形状、选定特殊字符计数和汇总。

## 检查、限制与下一步

新增十三项扫描/字节测试和两项元信息计划测试，均用自建样本：CP932/UTF-16 字节引用、参数脱敏、空字段区别、省略模式不补零、非目标命名空间、不求值、尺寸限制、版本保留、哈希失配、符号链接拒绝，以及损坏常量/分派/调用的反例。没有把合成样本与真实原引擎的运行兼容混为一谈。

原生采集的 52 项查询全部独立复现，证据 ID 与 MCP 保存记录一致，采集和清理错误为零。这份计划未包含独立的 resolve/inspect 查询，故 `default_function_coverage_status=not_tested`；`default_body_completeness` 也明确 `not_tested`，清理后尾部再次说明“有伪代码”不能证明完整函数。

扫描最多 2,000 个输入、128 MiB 累计字节、10,000 个候选，每字段 8,192 字符，命令处理时间 120 秒。失败写入私有失败报告，字段超限和未支持形状进入脱敏结果。只读类型探针继续沿用 1 MiB 元信息读取预算、每类/记录最多 64 个字段/方法；没有为真实数据绕过限制。

当前仍不具备完整运行时开发条件。最合理的后续范围是：确认省略模式字段的值来源、对象选择与调用上下文，再调查替换模板、零宽匹配和字符串拼接的具体规则。候选后端都需要先与这些行为做有范围的对照；不能预先宣称 ICU、PCRE、Rust 或 Swift 实现最优。TSkRegExp 的来源和许可必须在复用前单独确认。

## 重复运行

输入变量由使用者设置，所有命令在本机执行。没有自动读取或上传商业数据。

```sh
.venv/bin/python tools/delphi_metadata.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-replacement-metadata-plan.json --output reports/p1/replacement-metadata-report.json
.venv/bin/python tools/rea_static.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-replacement-plan.json --output private/p1-round15/native-reproduced \
  --java-home "$JAVA21_HOME" --ghidra-dir "$GHIDRA_DIR" --analysis-budget-seconds 600
.venv/bin/python tools/native_windows.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-replacement-windows.json --output private/p1-round15/windows
.venv/bin/python tools/review_native.py --game-dir "$GAME_DIR" --exe "$EXE_REL" \
  --plan docs/native-replacement-plan.json --facts docs/native-replacement-facts.json \
  --evidence-dir private/p1-round15/native-reproduced --windows-dir private/p1-round15/windows \
  --output reports/p1/replacement-native-report.json
.venv/bin/python tools/replacement_audit.py --game-dir "$GAME_DIR" --exe "$EXE_REL" --assets-dir "$ASSETS_DIR"
.venv/bin/python tools/research_checks.py --game-dir "$GAME_DIR" --stage round15 \
  --artifact reports/p1/replacement-metadata-report.json --artifact reports/p1/replacement-native-report.json \
  --artifact reports/p1/replacement-audit-report.json
```

复核命令同时运行规定的系统 Python 测试和研究 Python 测试，并调用上游适配验证。跳过项单列，不计成功；P0 摘要不改写。本轮开始前的 P0 快照另保存在私有目录，完整机器检查见 `round15-readiness.json`。

本轮实际结果：研究环境 252 项全部通过；系统 Python 249 项通过、3 项跳过；上游 26 项通过、8 项商业夹具缺失跳过。20 个关键原始文件摘要一致，P0 与回归前和本轮开始前两份快照一致。三个公开研究报告均通过禁用正文/原始参数字段检查。上述证据没有外推至完整目录不可变或全作执行兼容。
