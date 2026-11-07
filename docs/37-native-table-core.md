# 37 — 字符串、表对象和配置查询进入原生核心

用户最新明确授权“恢复完整应用开发”，覆盖此前静态研究阶段的范围限制。本轮更新 AGENTS.md 的工作范围，原始目录、资源隐私、许可证和未知语义的限制保持生效。应用版本为 0.4.0；仍不能开始完整游戏。

## 实际实现

`native/Sources/MangekyouCore/ScriptStorage.swift`、`ScriptTable.swift`、`ScriptMachine.swift` 以此前证据独立实现实验性契约 v3。契约见 `runtime-profile-v3.json`，不是对原引擎完整行为的声明。

| 范围 | 本轮支持 | 证据与限制 |
|---|---|---|
| 变量 | int 零值、str 空值、table 句柄声明；同类型标量赋值 | `ScriptStorage.declare/write`；对象别名、维度、释放时点未实现 |
| 作用域 | 最多 16 个明确 table 句柄；空参数清空；新调用帧为空、返回恢复调用者 | `docs/28-object-scope-and-registry-flags.md`、`29-frame-scope-initialization-and-return.md`；字符串对象选择与空槽映射拒绝 |
| 文本载入 l | 从固定摘要的资源目录读取；不同字节副本必须显式选择 | `ScriptRepository.readResource`；不从 PACK 直接读取，完整预处理不支持 |
| 表内容 | 以首个等号分隔、不修剪空白；首个同名值；双斜杠过滤；空值标记 | `docs/34-table-text-and-query-evidence.md` 的主/辅助报告；仅 ASCII 名称比较 |
| 查询 ?v | 查询键、有限字面量默认值；写全局 ResultStr / ResultInt | 原生分支 `0x6cded1` 及结果写入路径；额外结果标志、隐式类型转换未验证 |
| 编码 | 既有严格研究解码器和字节映射 | `docs/35-encoding-locale-and-initial-flags.md`；没有模拟 Windows CP0 与用户区域设置 |

表文本整体接受上限 1 MiB / 10,000 行，键和值各 8,192 UTF-8 字节；最多 512 个表、4,096 个变量。全局字符串 8 MiB，表来源累计 8 MiB、50,000 行、100,000 条目。超限、失败和未知项明确停止。对象句柄在本次执行内保留，原引擎所有权与析构等价性为 `not_tested`。

每条指令在候选状态上运算，仅成功后提交变量、表、帧和资源快照；失败时保留原状态和出错位置。这是本核心的明示策略，原引擎异常回滚行为为 `not_tested`。

## 真实副本结果

`reports/p1/table-execution-report.json` 固定本次源码、ARM64 二进制、语料清单和三个已有原生证据报告的 SHA-256。379 份文本、291,273 条词法记录再次与 Python 模型交叉检查，零差异。这只验证字节映射与模型一致，不验证所有记录的执行语义。

| 场景 | 处理记录数 | 停止原因 | 表/条目 |
|---|---:|---|---:|
| 不选版本 | 20 | 跨文件脚本副本歧义 | 0 / 0 |
| 仅选择 data8 的模块 | 29 | 配置副本歧义 | 1 / 0 |
| 明确选择 data7 模块和配置 | 49 | unsupported_expression_tail | 1 / 68 |
| 明确选择 data8 模块和配置 | 49 | unsupported_expression_tail | 1 / 68 |

两个明确选择的场景均完成一次表载入、一次查询、两次字符串声明和两次作用域选择。第三个预选配置尚未读取，不能把预选数量当作载入数量。它们分别核对 267 个来源字节引用，表行的分类、键和值摘要由既有 Python 模型重新构造并逐项比较。

当前终点是变量下标表达式，**没有**将下标零当成标量恒等或字符串首字。

- data7：`misc/value.s` 第 20 行，offset 286、length 40，源 SHA-256 `6d2791eca5a9c82ff4d525b3b99c31869de7dca383dd5ed51de8779522e63080`。
- data8：`misc/value.s` 第 20 行，offset 574、length 80，源 SHA-256 `2d4b82b51e9bf8f0a0cb24605c44f3ecad0efa773ae02a0077603be63b03c9e5`。

完整范围摘要见各场景的 `machine.currentLocation`。公开报告不保存脚本文本、查询参数、配置值或密钥，表行仅保留摘要、分类和相对位置。所列步骤包含空行和元记录，49 不是游戏进度百分比。

原生应用重新构建为 ARM64 0.4.0，签名检查通过。`native-app-round26.json` 记录 60 项 Swift 自建测试、56 个原目录文件路径/尺寸与 P0 一致，以及 10 个既有图片副本的解码、尺寸和摘要检查；图像显示等价仍未验证。独立界面检查看到了导入入口；选择既有研究目录后，自动化服务连续超时，未完成新核心的界面重放，仍为 `not_tested`。命令行核心核验不受此次界面连接失败影响。

## 测试与失败记录

新增 `TableTests.swift` 的 12 项自建测试：重复键先后关系、过滤时点、空白/等号、UTF-16 字节引用、CP932、整数转换边界、类型错误、默认值、多个作用域对象、帧恢复、失败原子性、版本歧义、全局结果类型冲突和未知输入。另有两项 Python 证据测试，拒绝伪造表摘要/计数/引用、泄漏正文和将 v3 字段混入旧契约。

首次 Swift 回归出现两项失败：未声明赋值的错误标识无意改变，以及旧测试仍把字符串声明视作不支持。前者恢复原标识，后者调整为真正未知的类型，并用新正例覆盖字符串。修正后 60 项通过。探索脚本曾导入不存在的 `parse_expression` 而失败，没有从该失败生成语义结论。初始日志保留在 private，未改写上游或旧报告制造成功。

完整 Python、上游、原文件摘要和 P0 冻结检查见 `round26-tests.json` / `round26-readiness.json`：研究环境 341 项通过、零跳过；系统环境 338 项通过、3 项跳过；上游合成检查 26 项通过、8 项商业 fixture 缺失而跳过。跳过不计作通过。20 个关键原文件摘要与 P0 一致，12 份冻结 P0 报告与本轮起始快照一致。

## 独立复现

以下是该轮 v3 源码快照的命令。当前源码已进入 v4，请使用 `docs/38-native-array-core.md` 的新报告命令；旧 v3 核验器会拒绝不同 profile，避免覆盖历史结果后误称同一测试。

先准备已经合法生成且摘要与固定语料清单一致的研究副本。输入参数由使用者指定，不自动搜索本机游戏目录：

```sh
swift test --package-path native
.venv/bin/python tools/verify_table_execution.py \
  --assets-dir "$ASSETS_DIR" --script-file data0.pack/startup.s
python3 tools/build_native.py
.venv/bin/python tools/verify_native.py \
  --game-dir "$GAME_DIR" --assets-dir "$ASSETS_DIR" \
  --output reports/p1/native-app-round26.json
.venv/bin/python tools/research_checks.py --game-dir "$GAME_DIR" --stage round26 \
  --artifact reports/p1/table-execution-report.json \
  --artifact reports/p1/native-app-round26.json
```

可单独在 `mangekyou-script` 命令中传 `--select-source` 指定版本。核验工具明确运行四种选择，不将较大包号视作已验证的胜出版本。原引擎等价性、区域比较、完整剧本控制流、演出、音视频、分支和存档仍未验证或未实现。

下一步应补证变量默认维度、下标与读写虚方法的关系，再实现有界访问；不能仅为越过停止点添加特例。同时继续修补候选归档后端的内部解压分配边界和输入校验，再讨论接入应用。当前应用直接 PACK 负载访问仍为 `unsupported`，上一轮 Rust 读取研究结果没有自动成为应用功能。
