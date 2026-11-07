# 15 — 清理后正常流模型与命令编号探针

2026-11-07，P1 第四轮。本轮解决的是部分反编译信息丢失的研究问题，并补充命令编号的只读探针。没有开发游戏引擎、播放器或界面，完整原生移植仍未完成。

## 对比实验的边界

第三轮发现两个函数的真实指令在 Ghidra 当前函数范围之后还有清理后的尾部。为核对其影响，本轮新增自行编写的 `tools/ghidra/BoundTailProbe.java`，在临时分析数据库里比较两个模型：

1. 按当前 Ghidra 识别的函数范围反编译，记录原始分析视图。
2. 在数据库中扩大显式函数范围，将指定清理区 `RET` 设为分支，并明确给出正常流后续目标，再记录派生视图。

修改仅涉及临时数据库的控制流和函数元数据，没有修改导入程序的字节，更没有写回 EXE。所有派生结果的 `authority` 为 `analyst-inference`，不能与未经改动的 REA 机器指令证据混为一谈。

这里使用的 [Ghidra `PcodeEmit.dumpBranchOverride`](https://github.com/NationalSecurityAgency/ghidra/blob/8b6bbb857accdfa20dc5b2f5dea471178c2e9fbc/Ghidra/Framework/SoftwareModeling/src/main/java/ghidra/app/plugin/processors/sleigh/PcodeEmit.java) 会把 `RETURN` 改成间接分支；它本身不会证明分支目标。源码按固定 commit 核对，与 12.1.4 tag 对应文件字节一致，摘要见 `toolchain-lock.json.local_flow_probe_api_reference`。单目标限制使用 Ghidra 的 JumpTable 元数据 API，不修改 Ghidra 上游实现。

## 合成验证与反例

使用自行构造的 16 字节 x86 样本，模拟“将后续地址压栈、清理区返回、在尾部把 EBX 移到 EAX 后返回”的正常流。没有执行这个二进制。

基线模型显示无返回值；加入模型约束后，反编译显示样本规定的 `0x1234` 返回值。所选内存的前后 SHA-256 完全一致。这个成功只证明工具可以表达并分析该合成控制流，不证明任意 Delphi 程序都等价。

同时故意把后续地址改为未被实际 `PUSH` 的地址。工具按预期拒绝，保留 `unsupported` 结果和 `no decoded PUSH of continuation before cleanup RET` 原因；反例测试通过不意味着这个错误模型被标为支持。正例和反例都通过，且所用 Java 脚本摘要与当前文件相同之后，才允许真实数据实验。

## 真实实验与局部失败

第一次只设分支、不限定单个目标时，两个真实函数仍产生未恢复的间接跳转，并且没有恢复值返回。这次结果保留在 `private/p1-round4/branch-only/`，没有拿工具进程成功退出当作语义恢复成功。

增加明确目标约束后，结果如下：

| 候选函数 | 清理区 RET | 正常流后续地址 | 派生视图的变化 |
|---|---|---|---|
| 命令编号 `0x6aa43c` | `0x6aa515` | `0x6aa51d` | 出现值返回，能看到编号累积结果 |
| 嵌套字符串查找 `0x6c12e0` | `0x6c136a` | `0x6c1372` | 出现值返回，能看到搜索游标返回 |

两项均记录了原/派生函数范围、伪代码摘要、元数据改动、实际 `PUSH` 位置，以及内存前后摘要。原始程序摘要仍与 P0 相符。公开的 `tail-probe-report.json` 不含伪代码正文，完整对比保存在忽略的 `private/p1-round4/real-comparison/`。

派生结果明确含有“手动覆盖跳转表”等 Ghidra 提示。这些提示没有被删掉，也不能据值返回的恢复宣布异常路径、栈清理、所有调用约定或完整函数语义正确。`experiment_status=verified` 表示实验执行及字节保护检查通过，`decompiler_model_recovery=verified` 只表示选定模型出现值返回且不再含未恢复跳转标记；真实报告整体仍为 **`inferred`**，执行等价性为 **`not_tested`**。

本轮包装器最初还遇到 Ghidra 不接受项目路径中以点开头的目录元素的问题，已改用普通临时目录前缀；没有因此改动目标文件或 Ghidra 上游。

## 可复用的只读命令编号探针

新增 `tools/command_ids.py`，将已观察到的 ASCII 正常流计算规则作为候选模型：A-Z 转为小写，取最多四个字符，按 8 位间隔打包。这个工具不执行任何 QLIE 命令，不猜测未知编号含义。

- 对超过四字符的输入，明确记录截断与碰撞候选，不静默丢弃区别。
- 对非 ASCII 输入标为 `unsupported`，不把 Python 的 Unicode 大小写规则当作原引擎规则。
- 保留问号前缀的原始编号，不擅自将它与没有前缀的命令合并。
- 真实输入重新按文件摘要核对并词法分析；每种名称保留最多三条原始字节位置证据，公开报告不含正文或参数。

379 份文本共有 40,824 条回斜线命令记录，245 种命令名。在这个 ASCII 编号候选模型下，没有非 ASCII 命令名、截断或编号碰撞。它只证明当前词法命令集合可建立无碰撞的编号候选表，不证明对象分派、命令语义、条件前缀处理或完整执行兼容。见 `command-id-report.json`。

## 从零复现

需要前面 P0/P1 的合法研究副本、固定摘要报告及匹配的 Ghidra/JDK。输入路径仍由参数提供。

```sh
.venv/bin/python tools/ghidra_tail_probe.py --synthetic \
  --ghidra-dir "$GHIDRA_INSTALL_DIR" --java-home "$JAVA_HOME"
.venv/bin/python tools/ghidra_tail_probe.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --ghidra-dir "$GHIDRA_INSTALL_DIR" --java-home "$JAVA_HOME"
.venv/bin/python tools/command_ids.py --assets-dir private/real-assets
.venv/bin/python tools/research_checks.py --stage round4 \
  --game-dir "$GAME_DIR" \
  --artifact reports/p1/tail-probe-report.json \
  --artifact reports/p1/command-id-report.json
```

真实计划固定在 `native-tail-probe-plan.json`，要求与 P0 的 EXE 摘要一致。分析只使用内存中读取后写入私有临时目录的有界副本，临时项目以 `-readOnly -deleteProject` 运行并删除。所选函数必须位于文件支持的可执行段，范围和总量沿用第三轮限制；每函数反编译至多 30 秒，每个 Ghidra 进程组至多 300 秒，超时会停止自有进程组，不自动重试原分析。

本轮合成测试共 103 项：完整环境 103 通过；系统 Python 100 通过、3 项可选检查跳过。上游仍为 26 通过、8 项商业夹具检查跳过。新增检查覆盖完整代码脱敏、未恢复跳转不能算恢复、无值返回不能算恢复、输入身份/内存变化拒绝，以及 ASCII 截断和 Unicode 处理边界。正反例 Ghidra 实验另由上述独立命令验证，不伪装成普通 unittest 的一部分。

`round4-readiness.json` 只汇总本轮报告、测试和原始摘要保护，继续保持 `runtime_development_ready=false`。下一步应利用这些局部模型核对表达式 token 翻译、运算次序、变量类型和调用上下文，保留异常路径及未经验证的分派规则；还没有到完整游戏运行时的验收。
