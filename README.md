# Project Mangekyou — 第四作原生移植

**当前工作范围**：用户授权完整应用，随后要求加速并优先命令行推进。现在冻结 UI 开发及常规界面打包/回放，先补齐命令行核心并验证完整运行能力，再继续 UI。静态取证、原目录只读、资源不外传和未知行为明确停止的约束继续生效。**整作尚不能游玩**。

目标是将《美少女万華鏡 -罪と罰の少女-》移植到 Apple Silicon。P0 与多轮 P1 已建立资源/脚本的可追溯证据；用户随后明确授权完整应用开发。现已构建 ARM64 原生应用，支持只读导入、包尾检查和有限图片预览，**整作可玩性尚未实现**。以下 P1 说明按当时范围保留；支持状态以实际测试为准。

原生开发版：`python3 tools/build_native.py` 后打开 `build/Mangekyou.app`。运行此应用无需 Python、Java 或 Wine，也不包含商业资源。13 项 Swift 自建测试通过；真实目录清单及 10 个图片副本已通过原生核验。[开发版范围与复现](docs/31-native-app-foundation.md) · [机器状态](reports/p1/native-app-foundation.json)。

**开发版 0.2.0** 新增实验性脚本核心和界面检查入口。379 份文本的原生解码、scalar 字节跨度和字段指纹与现有模型一致；真实启动副本可处理一段声明/计算/分支及同文件调用，随后在未支持的双参数调用处停止。38 项 Swift 测试通过；仍不能开始完整游戏。[脚本核心、停止证据与复现](docs/32-native-script-core.md) · [机器报告](reports/p1/native-script-report.json)。

**开发版 0.3.0（历史）** 接通显式脚本目录表、跨文件调用/返回及版本选择。默认保留不同版本的歧义；明确选定副本后，真实启动片段可进入另一文件，再停在未实现的 `table` 声明。48 项原生测试通过；仍不能开始完整游戏。[文件绑定、版本选择与复现](docs/33-module-binding-and-variant-selection.md) · [机器报告](reports/p1/module-execution-report.json)。

**开发版 0.4.0（历史）** 接入有界的字符串变量、表对象、作用域、配置载入和查询。明确选定脚本与配置副本后，真实启动片段从 25 条推进至 49 条记录，载入 68 个条目并执行一次查询；随后在未支持的变量下标表达式处停止。60 项 Swift 自建测试通过；原引擎等价性仍为 `not_tested`，此次独立界面重放因自动化连接超时未完成。[范围、停止证据与复现](docs/37-native-table-core.md) · [执行报告](reports/p1/table-execution-report.json) · [应用核验](reports/p1/native-app-round26.json)。

**开发版 0.5.0（历史）** 接入有界的一维整数/字符串数组、整项读写和尺寸限制。真实启动片段可完成两次表载入、21 次查询并返回调用者；明确选择下一个模块后处理 260 条记录，再停在未支持的 `list` 声明。74 项 Swift 自建测试通过；多维数组、对象列表、完整游戏和原引擎等价性仍未实现或未验证。[证据、限制与复现](docs/38-native-array-core.md) · [执行报告](reports/p1/index-execution-report.json)。

**当前开发版 0.6.0** 接入独立的字符串列表、变量类别检查和有证据支持的当前脚本目录资源候选。明确选择副本后，真实启动片段处理 715 条记录，保留 76 行列表文本、完成 27 次变量检查及共 48 次查询，再停在未支持的三参数 `for`。85 项 Swift 自建测试通过。列表中的非 ASCII 名称保留为未知比较；查询若需要经过它会停止，没有静默跳过。[证据、限制与复现](docs/39-native-list-and-exists-core.md) · [执行报告](reports/p1/list-execution-report.json)。仍不能完整游玩。

**P1 第二十三轮静态研究**补证表对象、文本载入和结果写入：主调查与辅助函数调查合计 41 项独立静态观察、23 项指定指令事实及 7 个有界窗口；5 个默认函数识别缺口仍明确保留。两份配置脚本关联到 4 份文本副本，42 处查询形成 84 条有条件的版本关联，其中 80 条有行位置候选、4 条未能匹配，均未执行原引擎查询。[证据、限制与复现](docs/34-table-text-and-query-evidence.md) · [机器报告](reports/p1/table-analysis-report.json)。

**P1 第二十四轮静态研究**继续核对编码、区域比较和对象初始标志：51 项独立观察、25 项指定指令事实及 3 个有界窗口。379 份文本中，125 份无 BOM 数据在 CP932/CP936 下都能严格解码，其中 54 份得到不同内容；原程序的所选缺省路径传代码页 0，并用用户区域设置比较名称。19 项新增自建测试覆盖歧义、来源字节、构造参数顺序和异常输入；没有增加应用支持范围。[证据、订正与复现](docs/35-encoding-locale-and-initial-flags.md) · [机器报告](reports/p1/encoding-audit-report.json)。

**P1 第二十五轮资源读取验证**实际构建固定 GPL Rust 归档库和研究适配器：ARM64 上 9 个游戏包的 10,940 个条目名称与 P0 一致，410 个既有受限样本的解码 SHA-256 全部一致，未保存新的商业资源副本。这提供了许可证声明明确的候选后端；内部 BPE 分配上限、完整输入安全与正式分发方案仍未解决，也没有接入应用。[范围、限制与复现](docs/36-gpl-archive-reader-crosscheck.md) · [机器报告](reports/p1/gpl-archive-report.json)。

2026-11-06 已完成真实目录的静态调查：10 个 FilePackVer3.1 索引共 10,947 项（其中游戏 9 包、10,940 项，另有卸载包 7 项）；受限解码 410 个资源，283 份 `.s` 可按原始字节位置分析。P0 静态调查通过；完整游戏兼容性仍为 `not_tested`。用户提供的目录包含汉化 EXE 和补丁，不视作经过认证的纯净发行版。

随后按用户授权完成 **P1 第一轮静态基础**：379 份文本的字节覆盖、行内候选命令、跨包差异、符号与资源候选图，以及 ABMP12 内部验证。P1 整体尚未完成，尚不具备进入完整运行时开发的条件。[本轮说明与复现](docs/07-p1-static-foundation.md) · [下一轮研究入口](docs/11-p1-next-steps.md) · [机器状态](reports/p1/readiness.json)。

2026-11-07 继续完成 **P1 第二轮取证**：2,639 个候选结构块、11 组补丁差异的字节定位、300 个存档边界候选，以及通过 REA/Ghidra 对主程序的 17 项选定静态观察。已验证工具在 Apple Silicon 上可用；全作原生移植仍未完成。[脚本与存档边界](docs/12-p1-semantic-evidence.md) · [原生取证和复现](docs/13-native-static-evidence.md) · [第二轮机器状态](reports/p1/round2-readiness.json)。

**P1 第三轮**进一步找到包槽位倒序查询和一处不限定槽位的脚本读取，形成保留所有版本的 202 个逻辑路径条件视图；还定位了 Ghidra 漏掉的两个清理后函数尾部。实际运行版本和完整执行语义继续保留未知。[证据、缺口与从零复现](docs/14-precedence-and-function-tails.md) · [第三轮机器状态](reports/p1/round3-readiness.json)。

**P1 第四轮**用自建正反例验证了临时数据库中的正常流模型，再对两个真实函数恢复了受约束的值返回视图；模型整体保留 `inferred`。新的只读编号探针覆盖 40,824 条命令记录、245 种命令名，尚不执行命令。[模型边界、失败记录与复现](docs/15-normal-flow-models-and-command-ids.md) · [第四轮检查](reports/p1/round4-readiness.json)。

**P1 第五轮**新增表达式结构解析器：8,130 个候选字段中，8,126 个生成可追溯的候选 AST，4 个未支持项保留位置和原因；没有执行表达式或声称游戏兼容。[处理组、覆盖边界与复现](docs/16-expression-structure.md) · [第五轮检查](reports/p1/round5-readiness.json)。

**P1 第六轮**核对基本值解析的 14 项原生观察和 7 项指令事实，新增有边界限制的整数格式假设模型。补充 `$` 字面量结构识别后，8,128 个字段生成候选 AST；两处空 `cal` 字段仍明确未支持。SDKMAN Java 21 与当前 REA/Ghidra 连接均已实际验证。[证据范围、类型风险与复现](docs/17-scalar-formats-and-empty-fields.md) · [第六轮检查](reports/p1/round6-readiness.json)。

**P1 第七轮**补充赋值、变量查询、权限与下标路径的 31 项原生观察、14 项指定指令事实，并关联 5,088 处赋值和 407 处更新候选。成功赋值返回值、存储优先序和索引处理形成新的有依据假设；没有建立变量执行后端。[证据、Unknown 与复现](docs/18-assignment-storage-and-index-evidence.md) · [第七轮检查](reports/p1/round7-readiness.json)。

**P1 第八轮**补充更新时点与调用返回的 44 项原生观察、17 项指令事实；重新核对 4,261 个转移记录，为 407 处更新候选关联阶段假设。`ret` 的参数进入上下文目标路径，仍未执行验证。[阶段、参数槽与恢复边界](docs/19-update-phase-and-return-context.md) · [第八轮检查](reports/p1/round8-readiness.json)。

**P1 第九轮**从原程序类型元信息定位线程/例程/控制块的两层创建链，以及结果记录的声明布局。新增只读元信息探针，默认函数覆盖缺口、派生视图和逻辑值规则分别报告；没有实例化或执行游戏对象。[类型声明、创建链和逻辑边界](docs/20-rtti-context-layout-and-logical-rules.md) · [第九轮检查](reports/p1/round9-readiness.json)。

**P1 第十轮**读取 12 个控制块和 11 个例程状态的声明，核对选定函数的 21 处状态写入、10 项指令事实，以及 2,639 个候选块的词法关联；7 处 `dbrk` 明确未支持。命令门控和清理后返回形成受限模型，完整执行语义仍未验证。[状态、控制流边界与复现](docs/21-declared-states-and-control-flow.md) · [第十轮检查](reports/p1/round10-readiness.json)。

**P1 第十一轮**核对片段读取、正文前缀路径与 11 项例程状态分派，补充 28 项原生观察和 9 项指令事实。新增字节候选探针揭示默认分析覆盖缺口；`dbrk` 获得局部证据，全局效果继续未知。错误起点和跳表线性解码的历史问题均保留。[读取、等待入口和证据限制](docs/22-reader-state-dispatch-and-coverage.md) · [第十一轮检查](reports/p1/round11-readiness.json)。

**P1 第十二轮**找到读取器的前缀字段和替换记录声明，核对 et/nt 的条件赋值路径、五类替换分支及八处脱敏脚本候选。新增 29 项原生观察、12 项指令事实，纠正“空伪代码即无操作”和“无矛盾即全覆盖”的误判风险；仍未执行替换或正文播放。[前缀、替换顺序与复现](docs/23-prefix-configuration-and-replacement-evidence.md) · [第十二轮检查](reports/p1/round12-readiness.json)。

**P1 第十三轮**补查 subp 的尾部字段打包和内建 rep 的条件绑定，建立前缀到标签的脱敏候选图。词法工具新增显式分组模式；379 份实际副本、40,824 条命令的新旧字段跨度一致，分组差异仅由合成样例覆盖。新增 30 项原生观察、14 项指令事实，完整执行仍未知。[调用变体、字段模式与证据限制](docs/24-subp-field-grouping-and-prefix-bindings.md) · [第十三轮检查](reports/p1/round13-readiness.json)。

**P1 第十四轮**追踪四个对象事件的声明和静态绑定，确认创建、读取两个桥接均调用同一工厂；默认交叉引用漏掉的一处调用由原始指令补证。核对参数转换标签四的回退路径，新增 22 项独立复现观察、11 项指令事实及 9 项合成测试。五处默认函数缺口和未解释的 ABI 继续保留；尚未实现参数执行或游戏运行时。[事件、回退与复现](docs/25-object-events-and-argument-fallback.md) · [第十四轮检查](reports/p1/round14-readiness.json)。

**P1 第十五轮**核对五种正文替换路径、正则相关记录声明、选项位和不同的大小写比较。新增 52 项独立复现观察、12 项指令事实，审计 563 处 `a` 拼写候选；其中仅六处有同行 `rep` 提示，而且均省略模式字段，不能认定默认模式或实际执行。完整正则兼容、异常恢复与对象绑定仍未知。[替换分支、证据边界与复现](docs/26-replacement-routes-and-case-rules.md) · [第十五轮检查](reports/p1/round15-readiness.json)。

**P1 第十六轮**沿字段补齐、取值和登记路径，补证省略模式条件下的整数零结果：通用解析入口要求至少九个字段，缺项以空指针追加，空指针计算结果为 `vtInteger/0`。六处真实词法候选均获得可追溯的条件投影，实际对象绑定和执行仍未验证。新增 26 项独立复现观察、12 项指令事实，并修正反汇编窗口越界识别。[缺项值、返回记录与复现](docs/27-omitted-mode-and-null-value-path.md) · [第十六轮检查](reports/p1/round16-readiness.json)。

**P1 第十七轮**追踪 `scp` 的作用域写入、对象查询与后续分派：处理成功仍继续下一槽，空槽停止，名称比较依赖条件标志。新增 24 项独立复现观察、16 项指令事实；审计 6,014 个选择候选及 5,793 条同行关系，实际绑定仍未验证。[作用域、名称比较与复现](docs/28-object-scope-and-registry-flags.md) · [第十七轮检查](reports/p1/round17-readiness.json)。

**P1 第十八轮**补接新例程构造中的 Scope 清理和返回时的例程选择：在已核对的类型绑定下，新例程初始化清空自身作用域；非局部返回从首个被移除例程取恢复数据，再保留目标例程。新增 33 项独立复现观察、12 项指令事实，为 3,720 个源码调用/返回候选标注条件契约；未执行脚本。[帧初始化、返回与复现](docs/29-frame-scope-initialization-and-return.md) · [第十八轮检查](reports/p1/round18-readiness.json)。

## 阅读结果

**P1 第十九轮**核验六份已有 DPNG、45 个非空拼片，并以 22 项独立原生观察和 11 项指令事实补接透明行填充路径。两份样本存在透明 RGB 差异，实际重叠和显示等价继续未知。[像素、原生写入与复现](docs/30-dpng-pixels-and-fill-evidence.md) · [第十九轮检查](reports/p1/round19-readiness.json)。

- [调查范围与证据规则](docs/00-project-scope.md)
- [真实目录与版本线索](docs/01-game-inventory.md)
- [FilePack 调查及工具复用边界](docs/02-filepack-analysis.md)
- [实际资源格式矩阵](docs/03-asset-format-matrix.md)
- [脚本结构、字节位置与工具不足](docs/04-script-analysis.md)
- [主要兼容风险](docs/05-compatibility-risks.md)
- [P1 范围及路线比较](docs/06-p1-recommendation.md)
- [机器报告](reports/p0/acceptance.json)、[第三方说明](THIRD_PARTY.md)
- P1：[跨包差异](docs/08-overlay-analysis.md) · [词法与符号](docs/09-script-structure-p1.md) · [ABMP 内部](docs/10-abmp-analysis-p1.md)

## 重复运行

核心扫描只需 Python 3.9+，不自动查找游戏、不联网、不执行输入文件：

```sh
python3 -m unittest discover -s tests -v
python3 tools/mangekyou_p0.py --game-dir "$GAME_DIR" --output private/real-p0
```

`GAME_DIR` 由使用者设定为自己的合法游戏目录；代码不包含本机游戏绝对路径。不指定输入会生成明确 `not_tested` 的无数据报告。

完整研究验证需要 Python 3.10+ 和 Pillow。本机使用 Python 3.13.15、Pillow 12.0.0：

```sh
uv venv --python python3.13 .venv
uv pip install --python .venv/bin/python -r requirements-research.txt
python3 tools/fetch_sources.py
.venv/bin/python tools/reproduce.py
```

上游源码按 [固定 commit 和 SHA-256 清单](docs/upstream-lock.json) 下载，仅取源码、构建清单和许可证；不整仓下载游戏附件。`reproduce.py` 生成无真实数据基线、源码检查、合成样本和自动化测试报告，会替换 `reports/p0/` 的真实摘要。使用真实数据时接着运行：

```sh
.venv/bin/python tools/mangekyou_p0.py \
  --game-dir "$GAME_DIR" --output private/real-p0 \
  --upstream-source .research/upstream/qlie-unpack
.venv/bin/python tools/sample_resources.py \
  --game-dir "$GAME_DIR" \
  --upstream-source .research/upstream/qlie-unpack \
  --archive-report private/real-p0/archive-report.json \
  --output private/real-assets --report private/real-p0/sample-report.json
.venv/bin/python tools/mangekyou_p0.py \
  --game-dir "$GAME_DIR" --assets-dir private/real-assets \
  --upstream-source .research/upstream/qlie-unpack \
  --probe-media --output private/real-p0
.venv/bin/python tools/summarize_real.py
```

文本提取交叉验证另需 Rust 2024 工具链，按固定源码原样构建，不使用游戏 EXE。构建结果只覆盖 QLIE 文本功能：

```sh
.venv/bin/python tools/build_msg_tool.py
.venv/bin/python tools/crosscheck_msg.py \
  --binary .research/msg-target/release/msg_tool
.venv/bin/python tools/summarize_real.py
```

`--probe-media` 可选，需要本机 `ffprobe`。报告只生成到独立输出树；拒绝输入/输出重叠及符号链接。退出码 2 表示错误或输入被拒绝；未知格式即使没有异常也会在报告中标记 `unsupported`，不能据退出码推断全部兼容。

抽样工具只解码全部 `.s`/`.txt` 和每包每种候选扩展名至多两个样本；单项 16 MiB、每包累计 128 MiB，不导出密钥，不覆盖不同内容的旧副本，不处理安装/卸载程序。样本选择有偏，不能外推至所有 CG、音频或演出。

## 报告与数据隔离

`verified` 必须附证据范围；`inferred` 是推断；`unsupported` 是当前工具不支持或明确失败；`not_tested` 是未验证。源码声称、上游测试、本地合成样本、真实样本分开列示。

`private/` 存放本机副本、完整脱敏 IR 和详细索引，`.research/` 存放源码缓存与构建产物，均被 Git 忽略。`reports/p0/` 只保留相对路径、摘要、统计、指令名称和不含台词的原始字节引用。商业资源、剧本正文、密钥、CG、音频和 EXE/DLL 不随项目分发。

P0 不运行游戏，未测试分支执行、存档、动画时间线或整作可玩性。下一阶段建议先确认包覆盖顺序与脚本语义，再决定原生运行时的语言和架构。

已有 P0 研究副本时，可独立重现 P1；该命令保持 `reports/p0/` 不变：

```sh
.venv/bin/python tools/reproduce_p1.py --game-dir "$GAME_DIR"
```

第二轮使用已有 P1 研究副本；完整步骤和本机原生工具要求见第 13 篇。`GAME_EXE_REL` 为主程序候选的相对路径，只读分析，不执行：

```sh
.venv/bin/python tools/reproduce_p1_round2.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL"
```

上游单独复验默认写入 `private/upstream-verification.json`，保留历史 P0 报告：

```sh
.venv/bin/python tools/verify_upstream.py
```
