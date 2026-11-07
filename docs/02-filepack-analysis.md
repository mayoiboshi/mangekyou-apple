# 02 — FilePack 格式与工具验证

固定来源、许可证、依赖与行号在 `docs/upstream-lock.json`、`reports/p0/source-audit.json`。以下源码事实不自动外推为当前游戏完整兼容。

## 文件结构

`qlie-unpack/parser.py:21–35` 和 `msg-tool/.../pack/types.rs:53–75` 一致将归档末尾 28 字节视为小端 footer：16 字节签名、u32 条目数、u64 索引偏移。当前真实 10 包的签名均为 `FilePackVer3.1`，不是根据扩展名判断。

V3.1 索引记录由 u16 文件名 UTF-16 单元数、2N 字节混淆名称、u64 数据偏移和五个 u32 字段组成：存储大小、解码大小、压缩标记、混淆方法、校验值。路径保留反斜杠及大小写。Windows 的解析规则、包叠加与资源查找规则不由索引格式单独决定。

旧 `filepack31.c:14–45` 把高偏移 DWORD 命名为 unknown，Python/Rust 将两 DWORD 合为 u64；本作已调查的包均小于 4 GiB，不能据此证明大文件偏移分歧没有影响。本项目的 footer 探针和合成边界测试使用 u64。

`parser.py:94–119` 从 EOF−0x41c 处取 256 字节派生包内 key；旧 C 同时建模 32 字节混淆签名、hash_size 和 1024 字节 key 区。V3.1 目录可解析不表示 QKEY/HashVer 已经完整验证：选用的 Python 解析器没有验证全部 key 签名与 hash 元数据，报告将这些检查保留为 `not_tested`。

`extractor.py:42–79` 对存储数据进行 hash 检查，再按方法解混淆、按需 BPE 解压、检查解码长度。本机游戏包每包有一个方法 1 的嵌入 `pack_keyfile`，多数资源为方法 2；采样时先在内存解码嵌入 key，再处理依赖项。没有导出、提交或显示 key 内容。BPE 签名为 `31 50 43 ff`；算法复用上游，不在项目重写。

## 四种证据必须分开

| 工具 | 源码声明 / 实际代码 | 上游测试 | 本地实际 |
|---|---|---|---|
| mangekyoupack | 专门的 3.1 及 Windows/GDI+ DPNG | 未找到自动测试 | clang/clang++ 在 io.h 失败；没有运行附带 EXE |
| qlie-unpack | 1.0/2.0/3.0/3.1，key、BPE、DPNG、ABMP 等 | 本机发现 34 项，26 通过、8 缺少商业 fixture 跳过 | 真实 10 包 10,947 索引；游戏包 410 项受限解码，无错误 |
| msg-tool | QLIE 归档、`.s`、图片有独立模块 | `.s` 模块仅看到 test_tag；不证明第四作语义 | 构建/交叉提取结果以 script-report 的 extractor_crosscheck 为准 |
| mangekyou_util | 第一作 FilePackVer3.0、Python2 文本工具 | 无自动测试 | C++ 缺 as-util.h；Python3 无法编译 Python2 print 语法 |

早期合成 3.1 样本仅验证解析器目录和方法 0 的明文 payload，没有构造有效的全部 QKEY/HashVer；报告不会把它写成原引擎可接受的完整归档。真实样本进一步验证了方法 1/2、压缩脚本和特定资源路径，但没有全包解码。

## 边界与 ARM64

旧 C 依赖 Windows CRT、MMX、16 位 wchar_t；DPNG 依赖 GDI+/COM，不可直接在本机 ARM64 构建。另在 C 的压缩 hash 路径发现对内部指针 `hash_data` 调用 free（filepack31.c:933–952）；这是一处源码可见缺陷，没有以真实数据运行该程序。

Python 路径已在 arm64、Python 3.13.15/Pillow 12.0.0 本地运行。其许可不明确，故只隔离调用固定摘要的本地源码，不把实现带入分发物。目录探针限制 100,000 项、32 MiB 索引；采样限制单项 16 MiB、每包累计 128 MiB，危险名称和冲突拒绝输出。

上游对非零压缩标记、较大混淆方法值有宽松处理，不能当成未知字段已解释。本项目不重打包、不提供覆盖开关、不运行解码出的文件。子进程有时间限制；当前 macOS 对 RLIMIT_DATA 的设置返回错误，报告明确记录无硬 RSS 上限，以输入尺寸、画布像素、条目数量和超时限制作为现阶段边界。
