# 10 — ABMP12 内部结构验证

对 P0 的 9 个现有 `.b` 研究副本进行本地解析，没有扩大提取游戏范围。继续复用固定 commit `531694715df21a9940578f4319d246ac8aa794de` 的 qlie-unpack，而不是另写 ABMP 格式算法。调用前校验源码摘要。

适配层在独立进程临时接入 reader、资源回调与名称读取，记录标签、来源范围、未知参数范围，并在解压前限制声明输出大小；调用结束恢复模块函数，不修改上游文件。不调用上游文件输出或运行功能。

## 实际结果

- 9 个顶层容器全部完成边界解析，发现 8 个嵌套容器，合计 17 个容器。
- 共 48 个成员；其中 17 个采用 BPE 压缩，已成功有界解压。
- 19 个 PNG 和 3 个 JPEG 实际解码成功，记录尺寸、模式和 RGBA 像素摘要，没有导出或展示图片。
- 8 个成员自身是嵌套 ABMP，已进入上述统计；18 个成员的解码后载体仍为 Unknown。
- 保存 98 段未解释参数范围，共 3,633 字节，只保存长度、offset 和摘要，不解释动画含义。

观察到的标签及次数包括：abdata13（14）、abdata14（3）、abimage10（17）、abimgdat13（2）、abimgdat14（33）、abimgdat15（11）、absound10（17）、absnddat11（14）、absnddat12（3）。标签出现不等于其声明的每个 slot 都有实际 payload，因此不能把标签数直接当图像或声音数。

`abimgdat15` / `absnddat12` 的已读取版本字段在本样本中为 1；适配层保留该值和位置，不为其他值臆造语义。图片模式含 RGB/RGBA，样本尺寸包括 1280×720、1024×576、256×1024 和若干小图。没有在这些样本中观察到 IMOAVI；不能推断其他游戏资源也没有。

## 证据与未知项

[上游 Python abmp.py](https://github.com/rafi441/qlie-unpack/blob/531694715df21a9940578f4319d246ac8aa794de/qlie_unpacker/abmp.py) 的资源回调负责成员解压与格式转换，部分参数只 skip。独立查阅的 [msg-tool abmp10.rs](https://github.com/lifegpc/msg-tool/blob/0356bb93be7c1f5b11ec22864919200cf7455e33/src/scripts/qlie/image/abmp10.rs) 同样把 AbData 的载体和部分 param 保存为字节数组；相关代码不足以证明图层、关键帧、时间、模型或事件语义。

本轮只对 Python 容器路径做了实际调用；没有声称运行了 Rust 的 ABMP 解码器，P0 的 Rust 构建仅开启 qlie 文本功能。两个项目源码相似也不等于两份独立实测 oracle。

`raw_bytes_reference` 的 offset **相对于当前容器**，不是直接相对于 PACK。嵌套或压缩成员通过 parent 原始范围、解压后摘要和容器链定位；不能把这些 offset 直接相加当成原始文件位置。未知段同样能够定位，没有静默丢弃。

容器解析 verified 仅表示受支持的区段边界和选定成员解码成功。Unknown 成员、参数意义、动画执行顺序和原引擎画面/时间一致性仍不支持；没有制作动画播放器。

## 安全限制与重现

单成员最多 16 MiB，每个工作进程累计解码最多 64 MiB、4,096 个成员、嵌套深度小于 4；CPU 20 秒、墙上时间 25 秒。当前最大实测嵌套为一层。内存没有可靠硬 RSS 限制，继续在报告中标为 unsupported。未知标签、截断、超限均生成带位置的错误和已解析部分。

```sh
.venv/bin/python tools/abmp_probe.py
```

结果见 `reports/p1/abmp-report.json`。自动测试使用自主构造容器，覆盖嵌套来源、未知区段、压缩大小炸弹、累计大小、成员数量及深度限制；没有商业测试数据进入仓库。许可证复用边界仍遵循 THIRD_PARTY.md，本轮没有解决 qlie-unpack 缺少明确许可证的问题。
