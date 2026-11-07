# 30 — DPNG 拼片、透明 RGB 与原生写入证据

本轮只分析已有六份 P0 研究副本，没有扩大提取、保存转换图片或执行游戏。六份均可由固定版本解析器解码，共 48 个声明拼片、45 个非空 PNG：29 个 8 位 RGBA、16 个 8 位 RGB。非空矩形两两不重叠，因此**真实重叠合成仍为 `not_tested`**。

来源：`reports/p1/dpng-audit-report.json.items[].tiles`、`rectangle_overlap_pairs`。每个拼片记录相对文件名、输入摘要、原始 header+payload 的 offset/length/SHA-256。空拼片的 PNG 解码状态为 `not_tested`，不冒充解码成功。

## 本地像素比较

`tools/dpng_audit.py` 通过受限独立进程调用 qlie-unpack，验证来源摘要后才加载；没有复制或修改第三方源码。固定 commit `531694715df21a9940578f4319d246ac8aa794de` 的 `qlie_unpacker/dpng.py:decode_dpng` 使用无蒙版 `paste`，即拼片替换；许可证仍为 NOASSERTION，仅作本地研究。mangekyoupack 的 `dpng2png.cpp:dpng_to_png` 使用 Windows GDI+ `Graphics::DrawImage`，未在本机运行，也未验证为相同结果。

报告区分三种操作：固定解析器的实际结果、自建的替换特征核对、两个反事实/条件模型（SourceOver；逐条填充后替换）。模型不导出 PNG，不构成新的分发转换器，也不是原引擎执行结果。

两个人物脸部样本的条件填充模型，分别与固定解析器相差 37,512 和 49,880 个像素；差异均为**两侧 alpha 同为零的 RGB**，alpha 差异为零、任一侧 alpha 非零处的 RGB 差异为零。其他四份结果一致。这不能证明差异永远不可见：后续缩放、滤波、遮罩与通道处理仍未验证。SourceOver 反事实也在这两份样本的透明 RGB 上有差异，不能据此认定实际重叠规则已验证。

## 原程序的静态证据

对象为 P0 固定摘要的主程序候选；不证明它是经认证的纯净发行版。`docs/native-dpng-plan.json` 独立重采 22 项 REA/Ghidra 观察，`docs/native-dpng-facts.json` 核对 11 组指定指令：

| 位置 | 已核对的局部事实 | 解释限制 |
|---|---|---|
| `0x54dfb8` | 读四字节、比较 PNG/DPNG 前缀，识别路径回退四字节 | 其他前缀仍到后续构造，不能写成“拒绝未知格式” |
| `0x535a9c` | 将 `0x532694/0x53269c` 两个回调和位图对象传给解码器 | 两个回调未被默认函数分析识别，负结果保留 |
| `0x530890` | 20 字节头、28 字节拼片头；头 offset 4 与 1 作有符号比较 | 该字段暂不命名为已确认版本；局部检查不等于完整边界验证 |
| `0x530a86` | 拼片 header+20 的低字节等于 1 时，设置画布宽、拼片高 | 高字节未比较，其他标记仍未解释 |
| `0x530854` | 先调用行填充门控，再调用拼片解码 | 多线程任务时序、整条调用链执行未验证 |
| `0x53077c / 0x530388` | 非零宽高时传入并重复写 `0x00888888` | 结合回调推断为透明灰色行填充，整体解释为 `inferred` |
| `0x530418 / 0x53054c` | 指定标量尾部分别写 RGB+独立 alpha、RGB+`0xff` alpha；直接写目的像素 | 局部支持替换候选，不能升级成完整渲染等价 |

LLVM 补证窗口收窄为 `0x532694..0x5326a2`：前者读取对象+0x24 的行指针数组，后者调用尺寸 helper 后返回。窗口读取、指令跨度核对通过，但边界仍为 `inferred`，默认函数覆盖为 `unsupported`。初始窗口末端跨过停止地址的指令仍留在 `exploratory_windows`，没有静默抹掉失败。初版事实超过 32 锚点、随后过早启动依赖报告的失败也留在历史记录；缩小事实选择后通过，没有修改验证器或上游。

**未确认**：原生画布初始值、BGRA/其他布局与后续转换的完整绑定、PNG 库所有色型与位深、并行重叠顺序、原引擎显示结果。本地条件模型显式假定初始画布为零；不能将模型哈希称为原引擎输出。

## 复现

环境路径由本机提供；不要把游戏绝对路径写入代码。原始取证只在 `private/` 保存。

```sh
.venv/bin/python tools/rea_static.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-dpng-plan.json --output private/p1-round19/native-reproduced \
  --java-home "$RESEARCH_JAVA_HOME" --ghidra-dir "$RESEARCH_GHIDRA_DIR"
.venv/bin/python tools/native_windows.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-dpng-windows.json --output private/p1-round19/windows
.venv/bin/python tools/review_native.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-dpng-plan.json --facts docs/native-dpng-facts.json \
  --evidence-dir private/p1-round19/native-reproduced --windows-dir private/p1-round19/windows \
  --output reports/p1/dpng-native-report.json
.venv/bin/python tools/dpng_audit.py --assets-dir private/real-assets
.venv/bin/python tools/research_checks.py --game-dir "$GAME_DIR" --stage round19 \
  --artifact reports/p1/dpng-native-report.json --artifact reports/p1/dpng-audit-report.json
```

历史失败窗口是本轮遗留取证，不是从零复现的必要输入。合成测试 `tests/test_dpng_audit.py` 覆盖半透明重叠、透明 RGB、空拼片填充、行覆盖冲突、未知标记、尺寸/工作量限制以及解析器输出不一致。跳过测试另计，不视为成功。

本轮期间，用户明确授权“可以做完整应用”。已同步 AGENTS.md 的开发范围；该授权允许推进原生实现，不会改变上述证据等级或自动解决无许可证解析器的分发问题。
