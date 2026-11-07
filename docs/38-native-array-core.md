# 38 — 一维变量数组进入原生核心

原生开发版 0.5.0 已支持有界的一维整数/字符串数组。真实启动片段越过上一轮 49 条记录处的下标读取，完成配置初始化的一段调用并返回；明确选择下一个模块后推进到 260 条记录，仍在未知类型处停止。不能开始完整游戏，步骤数不能换算为游戏完成比例。

## 下标含义的证据

`index-native-report.json` 记录 28 个选定静态查询、8 项指定指令事实；`index-allocation-native-report.json` 记录 8 个查询、3 项指定指令事实。两组均由有界 REA/Ghidra 命令独立采集、摘要核对并清理，没有运行原程序。

重要联系如下，均可由报告的事实 ID、来源范围和摘要定位：

- `name_descriptor_zeroes_four_coordinates`：名称描述符先清零四个坐标；`declaration_clamps_four_dimensions_to_one`：声明路径对四个尺寸作小于一则写一的处理。
- `storage_binds_integer_and_string_constructors` 和 `storage_applies_declared_dimensions`：存储工厂选定整数/字符串类型，随后将声明尺寸交给 `0x69de68`。
- `dimension_setter_stores_four_counts` / `dimension_product_reaches_allocation_slot`：四个计数的乘积交给分配虚方法；未宣称所有多维顺序已经恢复。
- `flatten_uses_base_and_three_strides` / `read_dispatches_by_linear_bounds`：第一个坐标直接参与线性下标，其余坐标与三个步长相乘；结果必须非负且小于 FCount，再调用读取虚方法。

`tools/index_bindings.py` 重新读取固定摘要的原文件，用现有受限 Delphi 元信息探针绑定三个类、类型单元、字段和虚表槽：

| 类型 | VMT | 字段和方法 |
|---|---|---|
| TValueArrayCustom | 0x696d6c | FCount +20、FArrayCount +32、FArrayPitch +48 |
| TValueArrayInteger | 0x697504 | FData +64；读取 +8 → 0x69dff4，写入 +12 → 0x69e104 |
| TValueArrayString | 0x6977f4 | FData +64；读取 +8 → 0x69e190，写入 +12 → 0x69e2dc |

另有 7 个有界 LLVM 窗口保留完整私有输出；本次未出现未知解码或跨出声明范围的指令。字符串读取方法设置 tag 1，从 FData 中按元素下标取指针，并调用所选字符串赋值帮助函数；没有取字符串内字符的指令路径。6 组小范围原始指令字节在 `index-binding-report.json` 中有独立摘要与位置核对。

结合无维度声明的最小尺寸和这些元素方法，将该路径解释为“数组元素，而非字符”的契约标为 **Hypothesis / inferred**；原引擎实际执行等价性仍为 `not_tested`。未恢复的多维顺序、全部隐式转换和所有权没有从类名猜测补齐。

## 原生实现和限制

`ScriptExpression` 新增单坐标变量引用和根赋值，显式向宿主请求索引存储；不使用宿主语言 eval。`ScriptBinding` 保存元素，普通变量名选择第零项。`ScriptStorage` 管理类型、边界、帧遮蔽和内存预算；全局结果写入只更新元素零。声明尺寸表达式不允许写入，低于一按所选原生声明路径收敛为一。

每个绑定最多 4,096 个元素，所有绑定总共最多 65,536 个元素；字符串仍受每项 8,192 字节及累计 8 MiB 限制。超限或未知类型明确停止，失败指令不提交。以下仍为 `unsupported`：多维声明、多坐标与连续下标、对象数组、索引副作用、非整数隐式转换、完整 `list` 对象。错误原子性是本核心策略，原程序异常回滚为 `not_tested`。

## 真实副本结果

`index-execution-report.json` 固定源码、ARM64 执行文件、已有表/编码证据及本轮三个证据报告的 SHA-256。379 份文本、291,273 条词法记录再次与 Python 字节模型交叉检查，零差异。它不比较原引擎执行后的变量值，不是运行语义等价测试。

| 明确选择 | 处理记录 | 观察到的停止点 |
|---|---:|---|
| 不选择副本 | 20 | 模块歧义 |
| 只选 data8 初始化模块 | 29 | 配置歧义 |
| data7 或 data8 初始化模块及两份配置 | 257 | 初始化模块已返回；下一模块有歧义 |
| 再选同包的 script/config/value.s | 260 | 新模块中未支持的 list 声明 |

两组 257 条路径均完成 2 次表载入、21 次查询、23 次计算和 1 次模块返回；最终表有 36 个条目，这是第二次载入替换后的状态，不是累计条目数。六个场景保留了版本歧义，没有自动选择更大包号作为胜出版本。260 条路径分别核对 306 个来源字节引用。

最新停止引用：

- `data7.pack/script/config/value.s` 第 6 行，offset 29、length 12；源 SHA-256 `ec485c55279636e663991e317bbb7feeea85a969f5b8a8c522c76a59fb3e98b4`。
- `data8.pack/script/config/value.s` 第 6 行，offset 60、length 24；源 SHA-256 `c90c0a0c3ec2ecd2cc3397c7bc49671a69b59b713bad2f08c39e17a0ffe4ba3a`。

公开产物仅保存元数据、来源位置、指令事实说明和摘要，不保存完整剧本、配置值或游戏图像。应用仍不能直接读取 PACK 负载，上一轮 GPL 候选后端尚未接入；界面新核心独立重放为 `not_tested`。

## 测试与未成功的探查

新增 14 项 Swift 自建测试覆盖整项字符串、多字节字符、一维独立元素、计算尺寸、最小尺寸、边界、负数、类型、对象拒绝、帧遮蔽、失败原子性、全局结果和总元素预算；全部 Swift 测试合计 74 项通过。新增 3 项 Python 元信息/字节模式测试和 1 项 v4 证据边界测试。所有模型测试仍不能替代原程序对照。

首次 Swift 回归有一项旧测试仍断言 `a[0]` 必须在语法阶段拒绝；调整为真正未支持的连续下标，同时增加正反例。原始失败日志保留，修正后的 69 项及加入数组声明后的 74 项均已分别检查。

Ghidra 默认分析未找到 6 个元素/分配方法，最初 12 次伪代码/汇编查询失败。后续显式查询确认这些覆盖缺口，并用有界 LLVM 窗口核对字节；没有修改 Ghidra 元数据强行建立函数。失败元数据保存在 `index-native-report.json.historical_failed_lookups`，默认函数覆盖仍为 `unsupported`。探索阶段还尝试了不适合当前最小元信息探针的另外两类，未将它们计入本轮已绑定的三个类。

完整系统/研究 Python、上游、原文件摘要和 P0 冻结检查见 `round27-tests.json`、`round27-readiness.json`：研究环境 345 项通过、零跳过；系统环境 342 项通过、3 项跳过；上游合成检查 26 项通过、8 项缺少商业 fixture 而跳过。跳过不计作通过。20 个关键原文件摘要复核通过，12 份冻结 P0 报告与本轮起始快照一致。ARM64 应用构建与 10 个既有图片样本检查见 `native-app-round27.json`。

## 复现和下一步

这些命令对应该轮 v4 源码快照。当前源码已进入 v5，请按 `docs/39-native-list-and-exists-core.md` 重新核验；旧执行核验器会拒绝不同 profile，避免将新行为混入历史报告。

输入目录由使用者提供；所有命令只读游戏原文件，完整原生工具输出写入忽略的 private 目录：

```sh
.venv/bin/python tools/rea_static.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-index-plan.json --output private/p1-round27/native-reviewed \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
.venv/bin/python tools/rea_static.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-index-allocation-plan.json --output private/p1-round27/allocation-reproduced \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
.venv/bin/python tools/native_windows.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-index-windows.json --output private/p1-round27/windows
.venv/bin/python tools/review_native.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-index-plan.json --facts docs/native-index-facts.json \
  --evidence-dir private/p1-round27/native-reviewed --windows-dir private/p1-round27/windows \
  --output reports/p1/index-native-report.json
.venv/bin/python tools/review_native.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-index-allocation-plan.json --facts docs/native-index-allocation-facts.json \
  --evidence-dir private/p1-round27/allocation-reproduced \
  --output reports/p1/index-allocation-native-report.json
.venv/bin/python tools/index_bindings.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL"
.venv/bin/python tools/verify_index_execution.py \
  --assets-dir "$ASSETS_DIR" --script-file data0.pack/startup.s
python3 tools/build_native.py
.venv/bin/python tools/verify_native.py --game-dir "$GAME_DIR" --assets-dir "$ASSETS_DIR" \
  --output reports/p1/native-app-round27.json
.venv/bin/python tools/research_checks.py --game-dir "$GAME_DIR" --stage round27 \
  --artifact reports/p1/index-native-report.json \
  --artifact reports/p1/index-allocation-native-report.json \
  --artifact reports/p1/index-binding-report.json \
  --artifact reports/p1/index-execution-report.json \
  --artifact reports/p1/native-app-round27.json
```

失败历史可以额外传 `--attempts-file private/p1-round27/attempts.json`，不把历史失败当作成功。下一步应追踪当前 `list` 声明的实际工厂和元素/对象方法，再接入所需子集；资源后端加固、画面演出、音频、分支和存档继续是完整移植的剩余工作。
