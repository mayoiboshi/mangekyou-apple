# 第三方来源与边界

完整 commit、源码文件摘要见 `docs/upstream-lock.json`；结论和源码行号见 `reports/p0/source-audit.json`。不在本项目内嵌或分发上游实现。

| 项目 | 固定 commit | 许可证证据 | 当前用途 |
|---|---|---|---|
| hiroshil/mangekyoupack | b48525ba5ce841957c7b8d09a7fdd50ab68e93ae | 仓库 GPL v3 LICENSE；未找到更具体项目 SPDX 声明 | C/C++ 源码研究，原生语法检查失败 |
| rafi441/qlie-unpack | 531694715df21a9940578f4319d246ac8aa794de | 未找到 LICENSE 或 pyproject 许可字段 | 固定源码、本地隔离调用；不复制进分发产物 |
| lifegpc/msg-tool | 0356bb93be7c1f5b11ec22864919200cf7455e33 | Cargo.toml：GPL-3.0-or-later | `.s` 解析、导出逻辑研究与构建验证 |
| crystallite/mangekyou_util | 5865d7f0d0ab8871bb3d254d5c89946108c79298 | 未找到许可证；README 表明汇集第三方工具 | 第一作参考，不移植或分发其代码 |

Python/Pillow 和本机 ffprobe 分别是研究依赖与可选外部命令。Rust 工具链仅装在忽略目录中用于验证，不是最终运行时选型。

无许可证不等于允许再分发；GPL 组件的复制、修改、组合和发布须满足相应要求，不能把独立进程调用当成自动豁免。P1 应优先取得明确许可，或选择许可证清楚且通过同一真实样本验证的实现。GARbro 仅作为额外资源解析器线索，未在本次采用其代码。

初次获取 mangekyoupack 时整仓包含了二进制附件。随后已删除这些附件及其克隆 Git 对象，没有运行或作为兼容性证据使用；可重现流程改为源码白名单下载。所有研究副本来自用户后来明确提供的本机目录。

2026-11-07 增加本机静态研究工具：REA `rea-agents@6.8.0`（本地 LICENSE 为 MIT）、Ghidra 12.1.4（主许可证 Apache-2.0，附带组件另有 NOTICE/许可），以及用户通过 SDKMAN 安装的 Microsoft JDK 21.0.13.0.2（本地 `legal/java.base/LICENSE` 和 `ADDITIONAL_LICENSE_INFO` 为 GPLv2 加 Classpath Exception，其他附带组件依各自声明）。版本、发行包摘要、可核对的 Ghidra revision 与 REA 版本策略文件摘要见 `docs/toolchain-lock.json`。

这些工具安装在项目外，只进行本机静态分析。本仓库不内嵌它们的实现，不分发工具或 JDK，不将反编译结果当作可再分发源码。没有因工具采用某种许可证而推断商业游戏程序获得许可；无许可的资源解析器也未被转成待分发运行时依赖。REA npm 发布包对应的 Git commit 仍为 `not_tested`。

原生应用基础使用 Swift 标准库、Foundation、SwiftUI、AppKit、CryptoKit（命令行摘要）、ImageIO 和 CoreGraphics；Apple 框架由本机系统提供，不随应用复制。SPM 清单没有远程包依赖。原生有界包尾/DPNG 描述探针依据本项目记录的格式事实独立编写，不含上游解析器代码；Quartz 图片预览明确不保证保留透明 RGB 或原引擎等价。应用暂未接入 PACK 索引/负载，不能据本轮构建宣称归档解析器的分发许可已经解决。

P1 第二十五轮额外启用固定 msg-tool 的 `qlie-arc` 库特性（仍是 `0356bb93be7c1f5b11ec22864919200cf7455e33`，GPL-3.0-or-later），通过自写、仅在本机研究中运行的 Rust API 适配器验证归档读取。上游源码未内嵌或修改；生成的 rlib、适配器二进制和 Cargo 缓存只在忽略目录。68 个本次编译包的名称、版本和许可证字段记录在 `reports/p1/gpl-archive-build.json`，完整解析元数据留在私有目录。这些字段是包声明，不能代替完整分发许可审查。

9 个游戏包目录及 410 个样本的结果与既有 P0 研究路径一致，说明存在可继续评估的 GPL 候选；不等于已经批准成品分发、采用 GPL 作为整个项目许可证，或允许把它作为无义务的外部进程打包。当前应用没有链接或捆绑这个库，也没有将无许可证 Python 解析器转入应用。研究适配器与许可/安全边界见 `docs/36-gpl-archive-reader-crosscheck.md`。
