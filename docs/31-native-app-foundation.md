# 31 — 原生应用阶段：导入与图片基础

用户在本轮明确回复“可以做完整应用”，工作范围由限定 P1 静态研究扩展为完整应用开发。AGENTS.md 已同步；原版只读、禁止运行商业 EXE/DLL、不得上传游戏内容及许可约束仍然有效。下面是**第一项原生应用交付，不是整作可玩版本**。

## 现有可运行产物

`build/Mangekyou.app` 为本机 ARM64 Mach-O 应用，已作本机 ad-hoc 签名并通过 `codesign --verify --deep --strict`。不是已公证的发行版。应用不含游戏资源、上游解析器、Python、REA、Ghidra、JDK 或 Wine。

可以通过原生目录选择器导入游戏目录，查看实际文件签名、尺寸与 FilePack 包尾；也可以导入合法提取的副本，预览普通 PNG/JPEG 和有限 DPNG。目录不记入源码，任何 EXE/DLL 只读其签名，不能从界面执行。

本次已实际打开欢迎窗口，操作目录选择器导入真实游戏目录，看到 56 个文件、4.05 GB、10 个已识别包，并选中 `GameData/data0.pack` 看到声明 9 项、索引未读取的详情。该 GUI 检查只观察了欢迎页和文件元数据，未把商业图像或正文截图传到外部。GUI 会话观察不等于独立自动重放；机器报告 `independent_gui_replay` 保持 `not_tested`。

## 验证范围

| 路径 | 实际结果 | 不能推导出的结论 |
|---|---|---|
| 原生目录扫描 | 56 文件，4,051,757,601 字节；路径/大小与 P0 一致 | 不是每个文件的完整解码与真实性认证 |
| PACK 包尾 | 10 个 FilePackVer3.1，声明计 10,947 项 | 没有在应用中列举索引、解密或读取这些项 |
| 原生图片 | 现有 410 份副本中的 6 DPNG、4 PNG 成功解码，输入 SHA-256 与尺寸均吻合 P0 | 不是全资源覆盖、像素完全等价或原版演出还原 |
| 自建样本 | 13 项 XCTest 通过，无失败 | 不是商业脚本或原引擎对照测试 |
| macOS 窗口 | 欢迎页、目录选择、列表和包详情已实际观察 | 不是游戏启动或分支可玩 |

机器结果：`reports/p1/native-app-foundation.json`。完整本机日志、原生清单和构建报告在 `private/native-foundation/`，不提交；后续整体检查另核对固定 P0 报告与 20 个已有关键原文件摘要，不把关键文件检查扩大描述成全目录逐字节证明。

`DPNGDescriptor` 只接受本轮有依据的有限头/标记和 8 位 RGB/RGBA 内嵌 PNG，最多 32 拼片、16 MiB 源数据、1,600 万画布像素、3,200 万累计拼片像素。未知标记拒绝，异常尺寸/长度、尾随字节和整数溢出输入均拒绝。它不实现 PACK 算法。

ImageIO 负责标准图片解码，Quartz 以 `.copy` 按文件顺序绘制拼片。标记一应用本轮条件填充模型。**预览缓冲使用预乘 alpha，丢失全透明处原始 RGB；这是显示预览，不是无损转换器**。原程序后续转换和并行重叠时序未确认，报告和界面保留原引擎等价未知。不能把本轮预览结果当作未来过渡特效的已验证输入。

目录扫描通过 POSIX 只读描述符逐级 `O_NOFOLLOW`，拒绝路径穿越、父目录/文件符号链接和非普通文件；限制条目、层数与时间。所有未知普通文件留在清单，链接与失败留在 issues。初版四项测试因 Foundation 没有解析 `/var` 别名而失败；只把自建测试目录移到 `.build/`，没有放宽生产限制。最早一次构建早于测试目录创建而失败，也有独立日志记录。

## 代码与选型

- `native/Sources/MangekyouCore/`：有界文件访问、目录和包尾元数据、DPNG 描述；不执行脚本。
- `native/Sources/MangekyouMedia/`：Apple ImageIO/Quartz 预览适配。
- `native/Sources/MangekyouApp/`：macOS SwiftUI 交互。
- `native/Sources/MangekyouInspect/`：使用同一核心的本地命令行核验。
- `native/Tests/MangekyouCoreTests/`：自建文件/像素、坐标、替换、空拼片填充、安全边界测试。

本轮使用 Swift 的理由是已有 ARM64 Swift 工具链与 Apple 原生解码器，可以用少量独立代码验证导入到显示的链路，没有增加第三方运行时依赖。核心与平台媒体/界面分目标，保留日后替换接口的空间。核心虽然为 POSIX 主机保留条件导入，**只在 macOS 实测**。这不是认定 Swift 必然适合完整 QLIE 解释器；若后续需要明确许可的跨平台媒体库或其他语言核心，应按依赖、行为测试和维护成本再选，而不是把本轮界面选型变成全项目语言约束。

原生模块根据本项目已记录的格式事实独立编写，没有复制无许可证的 qlie-unpack，也没有链接 GPL 解包器。Apple 系统框架由系统提供，不随应用打包。PACK 索引/负载在分发应用中的合法实现来源仍是关键未决项，不能将研究进程包装后就称许可问题已解决。

## 复现与打开

本机需 Xcode/命令行开发工具及 Swift 6 工具链；构建无需商业输入，也不联网下载包。

```sh
swift test --package-path native
python3 tools/build_native.py
open build/Mangekyou.app
```

`build_native.py` 只生成/替换自己标识的 `build/Mangekyou.app`；拒绝符号链接和未处理的 staging/backup，不将任意外部目录作为输出。开发版采用本机签名，正式分发的签名、公证和安装体验另行验证。

具备既有 P0 副本时，可重复真实核验：

```sh
python3 tools/verify_native.py --game-dir "$GAME_DIR" --assets-dir private/real-assets
.venv/bin/python tools/research_checks.py --game-dir "$GAME_DIR" --stage round20 \
  --artifact reports/p1/native-app-foundation.json
```

命令行也可独立扫描，结果仅含元数据，完整实际报告重定向到 `private/`：

```sh
swift run --package-path native mangekyou-inspect --game-dir "$GAME_DIR"
swift run --package-path native mangekyou-inspect --assets-dir "$ASSETS_DIR" --verify-images
```

## 接下来的实现顺序

1. 建立带源文件/字节位置、明确失败位置的执行核心；从有证据支持的变量/分支/调用子集开始，先用自建场景验证。未知命令应停止并报告，不得顺播台词代替执行。
2. 接入实际 `.s`/系统文本的启动与绑定，逐项核对宏、前缀、作用域、返回和等待。需要真实版本选择；不能默认任一补丁覆盖规则已经动态验证。
3. 为游戏导入接入许可明确的只读归档访问方案，解决本轮应用仍只能读包尾的问题。
4. 将渲染、声音、动画、选择、历史、存档分别接入执行状态；针对实际路径作对照。Ogg、ABMP 时间线、完整原版画面/存档、M4/M4 Pro 性能均未完成。

开始完整应用开发不意味着这些语义和许可缺口消失。当前界面没有“开始游戏”按钮；完整运行支持尚未实现。
