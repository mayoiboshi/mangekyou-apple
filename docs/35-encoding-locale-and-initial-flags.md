# 35 — 文本编码、区域比较与对象初始标志

本轮仍只做 P1 静态研究，未修改原游戏、未执行游戏 EXE/DLL，也未扩展应用、解释器或播放器。目标是缩小上一轮表文本的编码和比较缺口；不能把研究工具的解码成功称为原版兼容。

## 证据与复核

研究对象沿用 P0 主程序摘要 `ad02b1115887b8e5b453d4b5760077e8b63e153bba1161e1704209cf3db5cda5`。原始目录含补丁和汉化程序，纯净发行版身份仍为 `not_tested`。

`native-encoding-plan.json` 固定 51 个静态查询，`native-encoding-facts.json` 固定 25 项保序指令事实。独立进程 REA/Ghidra 采集完成，指定锚点缺失数为零，源摘要前后一致且清理成功。公开摘要为 `reports/p1/encoding-native-report.json`；原始伪代码和汇编仅在 `private/p1-round24/`。Ghidra 的函数边界和 Delphi 参数恢复存在缺口，完整函数体/异常 ABI 继续 `not_tested`。

默认函数识别漏掉三个编码前缀方法，显式否定观察仍为 `unsupported`。`native-encoding-windows.json` 的 LLVM 窗口补充读取到各自 RET 为止：`0x422924..0x42294b`、`0x4229bc..0x4229e3`、`0x422860..0x42288d`。其指令写入分别对应 FF FE、FE FF、EF BB BF。窗口边界由人工选择，整体解释为 `inferred`；没有因此宣称默认函数识别已恢复。

## 所选载入路径的编码选择

上一轮的临时字符串列表流包装将编码参数置零。本轮沿 `0x4219a8` 核对到以下路径（`encoding_nil_priority`、`prefix_size_and_bytes`、`preamble_length_cache`）：

1. 传入编码为空时，依次取得三个候选对象的前缀，逐字节匹配缓冲区开头。
2. 对应候选类声明分别为 `TUnicodeEncoding`、`TBigEndianUnicodeEncoding`、`TUTF8Encoding`。固定类指针单元、前缀虚拟槽和写入指令另由只读字节探针核对。
3. 都不匹配时，进入 `0x42245c` 的缺省对象路径；所列首次构造分支使用 `TMBCSEncoding`，代码页参数为 0。
4. `0x422678` 将代码页存入对象 `+12`；所列解码方法 `0x422744` 将该字段交给 `MultiByteToWideChar`。已有编码对象、所有错误处理和运行时修改未作完整恢复。

这些步骤组成 `inferred` 契约，不是执行轨迹。数值 0 对应 `CP_ACP`，表示 Windows 系统缺省 ANSI 代码页，可能随机器或设置改变；不能从游戏语言直接断定为 932。[Microsoft 数值定义](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-ucoderef/5d543f48-e18b-4828-91d4-69b1488748cf)、[转换 API 的代码页说明](https://learn.microsoft.com/en-us/windows/win32/api/stringapiset/nf-stringapiset-multibytetowidechar)。

### 一处参数解释订正

初稿将 UTF-8 构造路径的解码/编码标志写反。重新按汇编核对：先压入 8，再压入 0；被调函数将 `[EBP+12]` 写入对象 `+16`，将 `[EBP+8]` 写入 `+20`，解码方法读取的是 `+16`。因此该路径的解码标志为 8，另一标志为 0；缺省代码页路径的两者均为 0。

订正已写入 `utf8_explicit_codepage` 和研究报告。工具新增对调用点立即数、两个栈到字段存储及解码字段读取的字节核对；测试 `test_x86_earlier_push_maps_to_decode_flag_not_last_push` 和 `test_unreviewed_constructor_instruction_forms_are_rejected` 覆盖顺序与不支持的形式。订正前的元数据保存在私有 `before-stack-correction-*` 文件，报告保留 `review_correction` 记录。

这次问题说明：指令锚点匹配只能证实所选观察存在，**不能自动证明分析者对 ABI、参数或完整语义的解释正确**。Python 严格解码也没有复刻 Windows 不同版本、不同标志下的全部错误替换行为。[Microsoft 对非法输入和标志的说明](https://learn.microsoft.com/en-us/windows/win32/api/stringapiset/nf-stringapiset-multibytetowidechar)。

## 名称比较与初始标志

上一轮确认 `TStringList` 的比较包装根据 `FCaseSensitive` 选择两个助手；本轮 `compare_sensitive_flags`、`compare_insensitive_flags` 显示它们均调用同一导入 `CompareStringW`，区域值为 `0x0400`，标志分别为 0 和 1，随后将返回值减二。`0x0400` 是用户或进程缺省区域，1 是忽略大小写标志。完整规则依赖 Windows 区域排序，并非字符串逐字节相等，也不能直接等同于 Swift/Python 的转小写。[区域常量](https://learn.microsoft.com/en-us/windows/win32/intl/locale-user-default)、[CompareStringW](https://learn.microsoft.com/en-us/windows/win32/api/stringapiset/nf-stringapiset-comparestringw)、[忽略大小写标志数值](https://learn.microsoft.com/en-us/windows/win32/api/oleauto/nf-oleauto-varbstrcmp)。

对初始标志的证据有所推进：构造包装保存参数并通过 VMT `-12` 调用分配方法；该方法进入 `0x405704`，写入类指针后按声明实例大小清零剩余字节。两种列表的父类链接口表指针均为零，所列构造后钩子指向一个 RET。结合构造器与字段声明，可形成“普通新建实例的 `FCaseSensitive` 和 `FNoneOptimize` 初始为零”的条件假设。该结论不适用于任意已有对象、后续标志修改或异常中断，实际存活对象值仍为 `not_tested`。

`Clear` 的 DL 参数决定清理分支，所列指令不是将 DL 直接写入 `FNoneOptimize`。本轮没有将它误认成优化标志设置器，也没有新增表对象运行代码。

## 导入名称的独立核对与未支持项

另用 REA 的只读 PE 导入解析器独立采集 `private/p1-round24/imports.json`。探针按固定跳转地址和 IAT 槽位核对 `CompareStringW`、`MultiByteToWideChar`、`GetCPInfo`，包括 JMP 编码、原始 IAT 值、名称记录和 DLL 名字节。这避免仅凭反编译出来的函数名认定调用目标。

该解析器报告总导入覆盖为部分覆盖：5 个延迟导入描述符使用虚拟地址形式，当前解析器未支持，原始问题全部保留在公开报告的 `native_bindings.import_issues`，`full_import_coverage=unsupported`。三项选定导入的字节绑定为 `verified`，不能外推全部 DLL 或所有导入已解析。

初次用现有完整字段表解析器读取三个编码类时，遇到空的扩展字段表指针而被拒绝。保留三条失败记录；新探针仅核对必要的类头、类名和指定槽位，完整布局继续 `not_tested`，没有改上游文件或把缺失字段补成伪造声明。

## 真实文本的编码歧义验证

新只读工具 `tools/encoding_audit.py` 复用既有编码模型，并对固定 corpus 中全部 379 个副本（6,724,955 字节、202 个逻辑路径）分别试用六个标准库严格解码器。报告不保存任何正文、配置名称或参数，只保留摘要、统计和失败字节引用。

| 观察 | 结果 | 证据范围 |
|---|---:|---|
| UTF-16LE BOM / 无 BOM | 254 / 125 | 前缀字节核对 |
| 六种编码试解码 | 2,274 次 | Python 严格解码，不是原引擎测试 |
| 严格接受 / 拒绝 | 1,129 / 1,145 | 每次拒绝都保留源范围，未静默回退 |
| CP932、CP936 都接受 | 125 个文件 | 接受不等于识别成功 |
| 两种结果不同 | 54 个文件 | 解码后 UTF-8 摘要不同，无正文输出 |
| 同名比较组 | 177 组 | 所有副本仍保留 |
| 字节不同、模型字符完全相同 | 113 组 | 仅移除匹配 BOM；没有归一换行、Unicode 或大小写 |
| 字节与模型字符均不同 | 11 组 | 不选择生效版本 |

113/11 与第一轮已有跨包统计一致；本轮新增了更严格的“无需换行归一即可相等”复核，而不是把它宣称为新发现的资源规模。

上一轮四份配置副本的两组对应关系，在既有 CP932/UTF-16LE 模型下均有完全相同的字符摘要；其中 data7 的两份无 BOM 文本在 CP932/CP936 下均严格成功却产生不同内容。实际 Windows 代码页、加载版本和行为一致性仍 `not_tested`。语料的编码标签仍来自既有研究模型，没有因某种编码“试起来不报错”而自动替换。

新测试还覆盖 BOM 对失败 offset 的影响、非法代理项、部分前缀、UTF-32 前缀误识别风险、换行/NFC/大小写差异保留、源摘要及标签不符、符号链接、尺寸上限、缺失扩展字段表、导入指针篡改及未知构造指令形式。UTF-16BE/UTF-8 BOM 的真实语料覆盖为 `not_tested`，这里只由指定原生指令和自建样本覆盖；不能把三个前缀的源码路径都算作真实样本测试通过。

订正后的完整复核：新增 19 项自建测试；系统 Python 327 项通过、3 项跳过，研究 Python 330 项通过、零跳过，固定上游 26 项通过、8 项商业 fixture 测试跳过。跳过不计作成功。`reports/p1/round24-tests.json` 和 `round24-readiness.json` 保存结果；20 个关键原文件摘要通过，检查期间及相对 `private/p1-round24/p0-before.json` 的 P0 摘要均未改变。检查通过不代表 Windows 执行等价或进入完整游戏运行阶段。

## 独立复现

使用已有合法研究副本；不要运行会覆盖冻结 P0 的旧总复现命令。REA、Java、Ghidra 使用此前安装的环境，路径由调用者设置：

```sh
.venv/bin/python tools/rea_static.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-encoding-plan.json --output private/p1-round24/native-reproduced \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
rea inspect-pe-imports "$GAME_DIR/$GAME_EXE_REL" \
  --format json --full-output > private/p1-round24/imports.json
.venv/bin/python tools/native_windows.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-encoding-windows.json --output private/p1-round24/windows
.venv/bin/python tools/review_native.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-encoding-plan.json --facts docs/native-encoding-facts.json \
  --evidence-dir private/p1-round24/native-reproduced \
  --windows-dir private/p1-round24/windows --output reports/p1/encoding-native-report.json
.venv/bin/python tools/encoding_audit.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" --assets-dir "$ASSETS_DIR" \
  --all-corpus --imports-evidence private/p1-round24/imports.json
.venv/bin/python tools/research_checks.py --game-dir "$GAME_DIR" --stage round24 \
  --artifact reports/p1/encoding-native-report.json \
  --artifact reports/p1/encoding-audit-report.json
```

也可用重复的 `--source-file` 替代 `--all-corpus`，限制到明确的相对文件名。历史探索窗口和失败记录可由 `review_native.py` 的可选参数重纳入；失败不转为成功。机器报告记录生成工具摘要和 Python 版本。

## 对后续移植的影响

未来导入层需要显式保存编码与兼容配置，不应照搬宿主 macOS 的默认区域或仅以转小写模拟 Windows 名称比较。应先用自建、可分发的区域/错误输入样本建立独立对照，再决定跨平台实现；不能上传商业数据作为云端测试样本。

下一轮静态研究可继续追踪默认编码对象是否被替换、列表标志后续写入、同名键的区域等价情况，以及结果辅助状态和未匹配查询。本轮没有证明表对象全部命令、资源覆盖顺序、分支、演出、音频或存档兼容；整作原生运行仍未实现。
