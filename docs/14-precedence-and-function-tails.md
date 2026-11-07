# 14 — 包查找顺序、条件语料视图与函数尾部缺口

2026-11-07，P1 第三轮。目标仍是第四作完整原生移植；本轮完成的是必要的静态证据补充，没有引擎、播放器或游戏界面，也没有通过台词顺播替代移植。

## 包查找路径的进展

第二轮只确认了主程序的部分命令分派。本轮沿 `.pack` 字符串和包表引用继续追踪，得到以下机器指令证据：

1. `0x4ec798` 的未命中散文件分支从槽位 31 开始倒序查到 0。同一槽位先访问以 `0x715580` 为基址的表，再访问以 `0x715600` 为基址的表；命中后跳到退出路径。证据为 `native-round3-report.json.observations[id=descending_pack_slots]`，其中保留证据 ID 和行号。
2. `0x695104` 的一条脚本读取路径在 `0x69514a` 将 ECX 设为 -1，随后设 DL=1，并在 `0x695152` 调用包读取函数 `0x4ec5ac`。因此“无限定槽位的查找”至少在这一脚本读取点存在，不能外推为所有调用都相同。
3. 文件存在检查的候选帮助函数 `0x415fd8` 调用 `GetFileAttributesW`。包查询前有散文件相关分支，而不是无条件先查最高包号。扩展名例外、实际根目录、缓存和失败回退仍需完整核对。

另外，线性反汇编窗口 `0x4ec10c–0x4ec40c` 显示初始化候选路径构造 `data` + 数字 + `.pack`，在 32 个位置上循环并更新两张表；另一个窗口显示启动候选调用点传入 `GameData` 字符串地址。当前 Ghidra 没有把这两个区域完整识别成函数，因此它们是 **LLVM 的有界线性观察**，不是伪造的 Ghidra 函数证据，也没有据此宣称完整启动语义已恢复。

一个搜索线索最终被排除：`0x5dae04` 附近的 `.pack` 字节其实位于 `.package` 的 MIME 注册内容中，不能作为游戏归档加载的证据。扩展名子串命中仍需跟踪使用位置。

## 条件版本选择视图

`tools/p1_resolution.py` 建立的是明确带条件的静态模型，不是可执行游戏资源加载器。模型按照已经观察到的槽位倒序规则，在现有文本副本中计算候选赢家，同时保留全部来源。

当前 379 份研究文本对应 202 个逻辑路径，其中 177 组存在重复版本。在模型的前提成立时，202 个路径都能得到一个条件赢家；11 组正文或参数有实质变化的文本，其条件赢家均来自 `data8.pack`。这并不将“哪个版本实际生效”提升为 Verified。

模型明确保留以下前提：

- `GameData/dataN.pack` 实际装到主表的槽位 N，且相关包成功装载。
- 引擎最终解析出的路径没有命中优先的散文件。
- 查找使用 -1，或明确给出的限定槽位。
- 其他挂载根目录、第二张表、回调和动态变化没有改变该次查找。

没有证据的前提写为 `not_tested`，槽位映射整体仍是 `inferred`。每条记录的 `effective_runtime_winner` 保持 `not_tested`。如果输入中有同槽位多个候选、无法映射的包，或明确存在散文件，模型拒绝给出包赢家；不会静默挑一个。

公开的 `conditional-overlay-report.json` 包含全部计数及 11 组差异路径的元数据；完整条件视图在忽略的 `private/p1-round3/conditional-corpus.json`。没有删除旧副本，没有覆盖第一轮的 `overlay-report.json`，也没有将条件视图当作确定的实际游戏语料。

## 反编译范围缺口

本轮为第二轮的两个解释补足了证据：

- `0x41493c` 的宽字符分支中，ASCII A-Z 到小写的操作已由汇编核实。这个局部事实可以标为 `verified`；非宽字符分支及其他名称的大小写规则仍未知。
- `0x6c12e0` 的带字符串参数查找候选路径，从容器末尾向前遍历，取嵌套容器第 0 项的 +4 字段进行比较。搜索游标在 EBX；字段业务身份及完整返回展开语义仍未确定。

更关键的是，独立 LLVM 窗口找到了 Ghidra 当前函数指令列表未覆盖的两个尾部：

| Ghidra 候选函数 | 未包含的尾部地址 | 观察 |
|---|---|---|
| `0x6aa43c` 命令编号构造 | `0x6aa51d` | `MOV EAX, EBX`，随后恢复寄存器并返回 |
| `0x6c12e0` 字符串查找候选 | `0x6c1372` | `MOV EAX, EBX`，随后恢复寄存器并返回 |

清理区之前存在压入这些后续地址的指令。Ghidra 当前指令视图在更早的清理区 `RET` 结束，因此不能用其 `void` 表示断言函数没有返回值。完整字节范围、原始 EXE 摘要、两个工具各自的证据 ID、尾部指令摘要见 `tail_observations` 和私有窗口记录。

这说明此前不合理的函数签名至少部分来自函数范围缺口，而不能笼统归结为“游戏没有返回值”或完全靠类型猜测。本轮没有修改游戏，也没有修改 Ghidra 数据库来强行制造匹配的函数。后续应恢复清理后续路径、处理 Delphi 调用约定，再校验表达式、变量和控制流契约。

## 覆盖不足也进入报告

计划包含 37 个静态查询，另有 5 个 LLVM 线性窗口。它们是查询和范围数量，不是 37 个独立完整函数。

Ghidra 对两个探索性反编译请求返回 `invalid_request`，原因是相应地址不在已识别函数内；这些失败保存在 `exploration_failures`。另外三项观测明确显示未识别函数或未解码指令，见 `unsupported_observations`。报告中的 `coverage_status=unsupported` 不被研究命令成功或其他 `verified` 观察抹掉。

`rea_static.py` 的白名单增加了只读交叉引用、包含函数定位和单条指令检查。空交叉引用是“当前分析视图未找到”，不是证明没有引用；未解码结果是成功记录了一项支持缺口，不是成功解码。默认分析总预算为 600 秒，每请求最多 240 秒，超时后关闭自有会话，不重复原查询。

## 复现与验证

前提为已经重现 P0/P1 第一轮的报告和合法研究副本，并按 `toolchain-lock.json` 安装本机工具。所有路径均由参数或环境变量提供。

```sh
.venv/bin/python tools/reproduce_p1_round3.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --collect-native --rea-command "$REA_COMMAND" \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
```

已有本轮原生证据时省去 `--collect-native` 及工具路径参数；仍重新生成 LLVM 窗口、条件模型和证据摘要，并运行测试及原始关键文件摘要检查。分步命令：

```sh
.venv/bin/python tools/rea_static.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-evidence-round3-plan.json \
  --output private/p1-round3/native-reproduced \
  --rea-command "$REA_COMMAND" \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
.venv/bin/python tools/native_windows.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL"
.venv/bin/python tools/p1_resolution.py
```

LLVM 工具默认通过 `xcrun --find llvm-objdump` 查找，窗口必须在同一个文件支持的可执行段内。每窗口至多 8 KiB、总计至多 32 KiB、至多 16 个窗口；输入 EXE、原生计划和 P0 摘要必须一致。窗口是显式线性范围，不自动声称是完整函数；输出只在 `private/`。

新增 10 项合成测试覆盖：包槽位的数值排序、限定槽位、散文件冲突、未知挂载、不丢失版本、窗口边界、非代码段拒绝、负面覆盖观测以及函数尾部缺口。完整环境共 95 项；系统 Python 的 3 项可选检查和上游的 8 项商业夹具检查仍分别记录为跳过，不算成功。实际结果以 `round3-tests.json` 为准。

本轮状态与保护检查在 `round3-readiness.json`；P0 报告及原始关键文件摘要需保持一致。仍未实现或验证完整原生运行时、画面演出、音频、分支执行与存档恢复；完整移植目标继续进行。
