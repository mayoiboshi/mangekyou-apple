# 13 — REA / Ghidra 原生静态取证

2026-11-07。重启后的聊天已经通过 REA MCP 实际调用 Ghidra，成功反编译自建 ARM64 Mach-O 小样本。随后仅把第四作主程序作为字节导入临时分析数据库；没有执行游戏或汉化程序，没有使用 Wine。

## 工具与目标身份

- REA npm 包 `rea-agents@6.8.0`，MIT；固定发布包完整性和关键版本策略文件摘要见 `toolchain-lock.json`。npm 包到上游 Git commit 的对应关系未验证，不假称已固定该 commit。
- Ghidra 12.1.4，发行包 SHA-256 `ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db`；发行包内应用属性给出的 Ghidra revision 是 `8b6bbb857accdfa20dc5b2f5dea471178c2e9fbc`。REA 6.8.0 的 `dist/ghidra/GhidraReleasePolicy.js` 仅接受 12.1 系列，不能根据上游 main 文档断言 12.2 可用。
- 官方发行包没有附带 macOS ARM64 反编译器，已由包内源码编译：`make -j4 ghidra_opt ARCH_TYPE="-arch arm64" OSDIR=mac_arm_64`，安装结果的 Mach-O 架构为 ARM64。
- 使用用户通过 SDKMAN 安装的 Microsoft JDK 21.0.13.0.2 ARM64；默认 Java 8 没有改变。JDK、Ghidra 和 REA 均作为本机研究工具，不随项目分发。

目标为提供目录中的 `美少女万華鏡４.exe`：PE32/i386，3,915,264 字节，SHA-256 `ad02b1115887b8e5b453d4b5760077e8b63e153bba1161e1704209cf3db5cda5`。该摘要与 P0 清单相符，取证后再次相符。文件名和摘要一致只能固定这个输入，**不能认证它是未经修改的官方发行文件**。

## 已观察事实与限制

`native-report.json` 保存 17 个选定函数/汇编的证据身份及摘要，不含反编译正文。`native-evidence-plan.json` 固定同一 EXE 上的选择器；换一个 EXE 摘要时工具拒绝套用。每项观察可以追到私有证据 ID、原始文件摘要、机器地址及适用时的源文件字节范围。

| 观察 | 状态和证据范围 | 尚不能据此断言 |
|---|---|---|
| 0x6aa43c 的命令编号构造最多处理回斜线后四个 UTF-16 单元，并按 8 位间隔移位 OR 到 EBX | `verified`，`four_character_command_identifier` 的汇编锚点 | Unicode 异常输入、任意命令碰撞和错误策略 |
| `svar/gvar/var` 分别选择 BL=1/2/3 | `verified`，0x6b1ab8–0x6b1ad9 的比较与赋值 | 类别是否等同“系统/全局/局部”的完整语义，是否进入存档 |
| 变量创建函数有三个不同存储选择路径 | `verified`，0x69d0bf–0x69d17d | 对象所有权、共享、遮蔽和销毁时点 |
| 控制分派的部分路径写上下文对象 +0x34 状态字节 | `verified`，0x6bb02c 函数中的具体写入 | 全部状态编号含义、完整控制流和执行等价 |
| 命令编号调用的 0x41493c 在反编译表示中含 ASCII A-Z 到小写转换 | `inferred`，当前只有该函数的反编译与调用关系 | 非宽字符串分支、其他标识符或资源路径的大小写规则 |
| `ret` 有参数候选路径与无参数候选路径使用不同查找调用 | `inferred`，0x6b70d8 的反编译及两条真实脚本例外 | 参数一定是返回值、目标帧名称或其他某一种语义 |

`if/then/else/end/for/case` 的候选处理集中在 0x6bb02c；`go/jmp/ret/brk` 的候选路径位于另一个函数。0x6aacf8 的调用链还继续按对象类别分派，因而不能把某个函数中的命令子集当作整套 QLIE 指令。

Ghidra 对此程序恢复了明显不可靠的函数签名：命令编号函数被表示为 `void`，汇编却通过 EBX 累加结果；大函数还出现不合理的多级指针和栈临时量。当前没有修改上游、伪造函数类型或把反编译表示当原始源码。涉及调用约定、布尔返回、参数顺序、对象类型和状态名称的解释继续保留 Hypothesis；明确的比较、寄存器赋值、调用地址和字段偏移才作为机器指令事实。

## 从零复现

先按 `toolchain-lock.json` 安装匹配的 REA/Ghidra/JDK；将环境变量指向各自的本机位置。JDK 可以由 SDKMAN 管理，不需要更改默认 Java。

```sh
.venv/bin/python tools/reproduce_p1_round2.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --collect-native --rea-command "$REA_COMMAND" \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
```

也可分步：

```sh
.venv/bin/python tools/rea_static.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --rea-command "$REA_COMMAND" \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
.venv/bin/python tools/native_summary.py
```

`rea_static.py` 通过本机 stdio MCP 仅允许打开目标、读函数反编译/汇编和关闭分析；不提供目标执行、调试注入、元数据改写或任意工具转发。计划最多 64 查询，每响应 16 MiB、累计 128 MiB、每请求 240 秒；输入 EXE 至多 64 MiB。输出必须在 `private/` 且不与游戏目录重叠，输入和输出路径拒绝危险符号链接；目标在导入前后均核对摘要。所有失败均写 collection 报告，超时不盲目重启原查询。

本次独立命令采集的 17 查询全部成功，关闭资源成功，目标摘要保持一致。私有目录为 `private/p1-round2/native-reproduced/`；早先交互探索的完整 bundle/snapshot 留在 `private/p1-round2/native/`，不是发布资源。

## 接下来的证据缺口

下一步应先核对 Delphi 寄存器调用约定，补充变量容器和控制上下文的机器指令证据，恢复表达式与调用/返回的可审查契约，再处理包加载优先级和存档恢复状态。当前没有完成语言选型、解释器、渲染器、音频、动画、存档或 macOS 打包。即使本轮 `status=verified`，`runtime_development_ready` 仍为 false，全作原生移植目标保持未完成。

后续第三轮已为 ASCII 小写转换补足汇编，并定位了两个函数清理尾部缺口；还扩展了只读证据查询和总预算限制。上述第二轮的覆盖及状态保持为当时记录，新增结论与最新复现见第 14 篇。
