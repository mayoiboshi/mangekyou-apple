# 39 — 字符串列表、变量类别和相对资源候选

开发版 0.6.0 的历史回放接入独立的 `list` 文本组件和 `vexs`，当时在 715 条记录处停于未支持的三参数 `for`。该停点已被后续更完整的实验性路线回放推进；以下保留其原始结果，当前进度见下一节。始终未启动原程序 EXE/DLL。


## 后续主线候选路线（历史及当前源码复跑）

较早一批固定 `data8` 研究副本的回放摘要位于 `private/p1-round1000000016` 至 `private/p1-round1000000026`；其中十次路线运行和一次输入预检失败均保存在各自目录。它们只匹配各自生成时的源码版本，不能当成最新工作树的源码哈希复跑。最新源码直接从标题开始的严格复跑见 `private/p1-round1000000052` 和 `private/p1-round1000000054`；两份报告的 55 个编译源码 SHA-256 均匹配当前工作树，配置文件摘要也匹配既有研究输入 `5aa7b865e283b615fea65866381595edbfc28d63eb1b466371e4a1cd1436b0df`。

| 提供的故事选择 | 步数 | 来源检查 | 路线结果 |
|---|---:|---:|---|
| `1,1,1,1,1,1` | 70,000,269 | 109 文件 / 5,893,403 字节 | 六项消费完，回标题 `verified` |
| `1,1,1,1,1,0` | 64,275,171 | 110 文件 / 5,871,020 字节 | 六项消费完，回标题 `verified` |
| `0,1,1,1,1,1` | 69,992,578 | 107 文件 / 5,832,227 字节 | 六项消费完，回标题 `verified` |
| `1,1,0,1,1,1` | 69,954,566 | 107 文件 / 5,832,227 字节 | 六项消费完，回标题 `verified` |
| `1,0,1,1,1,1` | 70,115,425 | 107 文件 / 5,832,227 字节 | 六项消费完，回标题 `verified` |
| `1,1,1,1,0,1` | 63,744,624 | 109 文件 / 5,864,973 字节 | 六项消费完，回标题 `verified` |
| `1,1,1,0,1,1` | 60,530,271 | 109 文件 / 5,864,973 字节 | 四项后回标题，两项未消费，`unsupported` |
| `0,0,0,0,0,0` | 60,592,033 | 108 文件 / 5,863,945 字节 | 四项后回标题，两项未消费，`unsupported` |
| `1,1,1,0` | 60,530,278 | 110 文件 / 5,871,020 字节 | 四项消费完，回标题 `verified` |
| `0,0,0,0` | 60,592,033 | 108 文件 / 5,863,945 字节 | 四项消费完，回标题 `verified` |
| `1,0,1,0` | 61,323,796 | 152 文件 / 7,849,375 字节 | 最新源码直接从标题启动；四项消费完，回标题 `verified` |
| `1,0,1,0,1,1` | 61,323,796 | 152 文件 / 7,849,375 字节 | 最新源码直接从标题启动；四项后回标题，两项未消费，`unsupported` |
| `1,1,1,1,1,1` | 70,791,222 | 156 文件 / 8,061,669 字节 | 最新源码直接从标题启动；六项消费完，回标题 `verified` |

最新入口 `--verify-story-route` 直接从标题开始并要求所有给定选择消费完、再回到标题；它与需要读档菜单捕获的 `--verify-route-return` 分开。`private/p1-round1000000052` 的四项路线记录 90 个未截断来源入口组和 45 个剧情文件；集合与 `1,1,1,0`、`0,0,0,0` 两条短路线相同。`private/p1-round1000000054` 的六项基准记录 96 个未截断来源入口组和 51 个剧情文件。两次新回放的 `route_return_status`、来源字节引用为 `verified`；全部 source-visit 状态为 `inferred`，报告记录的 `labelHistoryReadStatus=inferred`，不能据此证明原版标签读取或分支语义。六项路线 `private/p1-round1000000053` 在 24,000 点击预算下仅消费两项并耗尽点击数；同一路线用 48,000 点击预算后通过。当前显式点击上限为 48,000，总路线步数上限仍由 `--maximum-steps 96000000` 单独控制。

基准向量 `1,1,1,1,1,1` 另以 `--source-visits` 重放，见 `private/p1-round1000000037/cli-progress-data8/attempt-00.json`。source-visits 未截断，共 96 个来源入口组；其中有 51 个不同的 `scenario/` 文件（data6 为 48、data8 为 3），来自语料清单中的 116 个 data6/data7/data8 场景文件，文件入口覆盖约 44%。访问跨步骤 75,044–69,998,827，末段进入 `t21_01omake@.s` 与 `ed_movie.s` 来源；这表示候选解释器走到这些脚本，不证明 Omake/片尾演出正确或屏幕/声音实际等价。所有 source-visit 状态为 `inferred`。

四选择短路线 `1,1,1,0` 也以 `--source-visits` 重放，记录在 `private/p1-round1000000038/cli-progress-data8/attempt-00.json`。该路线未截断 source-visits，进入 45 个不同的 scenario 文件（data6 为 44、data8 为 1），其中 42 个与六选择基准路线重合；它没有进入 `t21_01omake@.s` 或 `ed_movie.s`。对照基准路线的 51 个 scenario 文件和 Omake/片尾控制脚本入口，这条短路线在候选模型里提前结束；不据此命名原版结局。两份路径访问状态都为 `inferred`。

全零四选择路线 `0,0,0,0` 的 source-visits 记录在 `private/p1-round1000000039/cli-progress-data8/attempt-00.json`，同样未截断并进入 45 个 scenario 文件，文件集合与 `1,1,1,0` 完全相同，也未进入 `t21_01omake@.s` 或 `ed_movie.s`。这是当前候选报告的文件集合比较；不证明路线内部执行、状态或原版结局相同，访问状态为 `inferred`。

两个六项输入在第四项后已到标题等待点；只提供实际消费的四项后，route checker 均能验证回标题。它们是候选模型中的短路线，不证明原版剧情结局或早停语义。首个选择点的 stderr 记录只列 `indices=0,1`；提供值 `2` 的探针在 `cli_progress_program_preparation_failed` 处被拒，未执行路线，记录见 `private/p1-round1000000024/cli-progress-data8/attempt-00-stderr.log`。这只描述当前候选输入模型。

所有成功路线均停在 `data8.pack/script/title/main.s` 第 32 行；该位置源 SHA-256 `affc85eb52bd090afa48af71c74910eb4bf11f13ac8123de3957a5dc2c3e141c`，offset 802、length 6、范围 SHA-256 `b6c08ac2251ff94a05b534d739c982182094fb8259e2c247580e53d0d5001519`。trace 均为末段摘要，不含全部步骤。`route_return_status=verified` 只说明 `advance_cli.py` 在候选回放中消费完已提供选择并到达标题等待点；全路线报告仍为 `inferred`，原版包优先级、故事分支语义、完整存档、原版执行等价和整作兼容仍未验证。

## data7 来源组标题入口与候选主线检查

将 `source_cohort=data7` 并补入已核对的本地图片/音频/影片资源收据后，普通 CLI 回放可从 `data0.pack/startup.s` 进入 `data7.pack/script/title/main.s`，2,998 步、加载 9 个程序、核对 41 个来源和 5,210,033 字节，停在第 32 行 `ret` / `waitingForEvent`。记录为 `private/p1-round1000000035/cli-progress-data7/summary.json`，总状态 `inferred`，来源字节为 `verified`。该位置源 SHA-256 `21c85152fef1ede2ceee41073732cc3de24b30cd047d53b1a7c650b83fb8a597`，offset 400、length 3、范围 SHA-256 `aaef425db14f619ebba77e7c2c120ebf399f2da6bf08ce8564dcd818c2f6c683`。没有证据证明标题后的故事输入已消费。

同一来源组启用读档菜单/回标题验证时，尝试报告 `private/p1-round1000000036/cli-progress-data7/attempt-00.json` 为 `unsupported`，issue `requested_load_task_not_reached`。随后新增的直接标题启动检查确认：data7 纯来源选择可从标题进入剧情，但在第 3 项选择后，于 data6/data8 同名来源 `scenario/本編/t16_03.s` 遇到歧义。data6 原包为 SHA-256 `c8f6e1e1821ecc5bccea2db9737e2915c0bf2f2e185df6f40ad1b5e7fb3c1006`，成员 entry 54、offset 592209、stored size 22165、解码成员 SHA-256 `f46e285e87ce00facedc47885ccbdc94f4a9b4062597525e4f73bc6e587b1446`；data8 原包为 SHA-256 `f796a90c498de7325d8968d8ce99ef17b71753b7ce101521e390167649c83509`，成员 entry 193、offset 1091276、stored size 22182、解码成员 SHA-256 `80d32248c382ddc6e2c799869db394f8b565c730c4ce3b0aca87a0670b69dea3`。报告 `private/p1-round1000000056` 执行 53,552,901 步，消费 3/4 项；该停点不能用自动包优先级推断消解。

为继续验证，私有续跑 `private/p1-round1000000057` 显式固定 80 个 data7 脚本/表来源，并对 `data8.pack/scenario/本編/t16_03.s` 加一项跨包候选覆盖（SHA-256 `80d32248c382ddc6e2c799869db394f8b565c730c4ce3b0aca87a0670b69dea3`）。该混合候选路线从标题启动，执行 60,777,942 步，消费四项 `0,0,0,0` 并回到 data7 标题等待；来源字节与 `route_return_status` 为 `verified`，核验 145 个来源、7,377,564 字节。source-visits 未截断，共 90 个入口组、45 个剧情文件；末段进入 `t18_01b@.s` 和 `ted99_01.s`。编译源码的 55 个 SHA-256 匹配当前工作树。此结果只验证显式混合候选路径，不证明 data8 在原版运行时胜出；原版包选择、结局语义、画面/声音和完整游戏兼容仍为 `not_tested`。历史静态槽位检查仅支持 data8 为条件赢家，不是运行时证据。

将第四项改为 1 后，五项输入的 `private/p1-round1000000059` 消费前五项并进入下一剧情选择等待，严格状态 `unsupported` / `route_additional_choice_required`；source-visits 未截断，覆盖 44 个剧情文件并进入 `t19b_01.s`、`t19b_02@.s`。补第六项 0 后，`private/p1-round1000000061` 消费六项 `0,0,0,1,0,0`，执行 64,029,732 步并回到 data7 标题等待；来源字节和 `route_return_status` 为 `verified`，核验 147 个来源、7,468,204 字节。91 个未截断入口组覆盖 46 个剧情文件，比四项路线新增 `t18_01.s`、`t19b_01.s`、`t19b_02@.s`、`t19b_03.s` 四个文件。此续跑在前述 `t16_03.s` 外，再对 `data8.pack/scenario/本編/t19b_03.s` 显式覆盖 data8 候选，SHA-256 `c94bbd4bd75365a2837703fb3ca8ece5bedffddcf92154294e8a40bff6ed981a`。data6 原包 SHA-256 `c8f6e1e1821ecc5bccea2db9737e2915c0bf2f2e185df6f40ad1b5e7fb3c1006` 中该成员为 entry 67、offset 815254、stored size 11411、成员 SHA-256 `f1920315e1cb77c7c9f9df95fe1529b83dcc00616608517a836021c99c5673d3`；data8 原包 SHA-256 `f796a90c498de7325d8968d8ce99ef17b71753b7ce101521e390167649c83509` 中为 entry 206、offset 1314350、stored size 11416、成员 SHA-256 `c94bbd4bd75365a2837703fb3ca8ece5bedffddcf92154294e8a40bff6ed981a`。当前编译源码 55 项摘要与工作树匹配。两次跨包选择均是显式 `inferred` 候选，不证明原版包加载顺序；结局语义、音画和 `full_game_compatibility` 仍为 `not_tested`。

将后两项改为 1 的 `private/p1-round1000000065` 同样消费六项 `0,0,0,1,1,1` 并回到 data7 标题等待，执行 70,286,304 步；来源字节和 `route_return_status` 为 `verified`，核验 153 个来源、7,732,364 字节。96 个未截断入口组覆盖 51 个剧情文件，其中进入 `data6.pack/scenario/ed_movie.s` 和 `data6.pack/scenario/本編/t21_01omake@.s`；这只证明候选解释器进入这些脚本，不证明影片实际播放或结局已正确呈现。相较 `[0,0,0,1,0,0]`，文件集合新增 `t18_02@.s`、`t18_03.s`、`t19a_01.s`、`t19a_02@.s`、`t21_01omake@.s`、`ed_movie.s`、data8 的 `t19a_03.s` 和 `t20a_01.s`，并不再访问 `t19b_01.s`、`t19b_02@.s`、`t19b_03.s`。该路线在 `t16_03.s`、`t19b_03.s`、`t19a_03.s`、`t20a_01.s` 显式选用 data8 的同名脚本候选；四项覆盖及摘要见 `private/p1-round1000000065/cli-progress-data7/summary.json`。新增两成员在原包 `GameData/data8.pack`（SHA-256 `f796a90c498de7325d8968d8ce99ef17b71753b7ce101521e390167649c83509`）中分别是 `t19a_03.s` entry 203、offset 1258483、stored size 24674、解码 SHA-256 `1b3eebdb6754cb5e29e0d95d524a30003c33249296d8efb405241c64970d22c7`，以及 `t20a_01.s` entry 208、offset 1335197、stored size 8060、解码 SHA-256 `e38f63bf72e5d4ea0f14f66a4b1105735ecec4c1c241beb49494ba3e1b9f6428`。该路线是多处人工指定覆盖的混合候选；包加载运行时、片尾音画和原版结局仍为 `not_tested`。

`private/p1-round1000000066` 在相同六项输入和四项显式覆盖上另加 `--source-coverage data6.pack/scenario/ed_movie.s`。路线结果仍为 70,286,304 步、6 项消费完并回标题；目标脚本源 SHA-256 `1135dba5bee31be90c62e93cb71b0c7335bbc03fc11a24e6d04f3317040d1e83`，coverage 未截断，记录一个 label 和三个 command，均各执行一次：相对 `data6.pack/scenario/ed_movie.s` 的 `(offset 36,length 12)`、`(116,20)`、`(190,18)`、`(310,8)`。这确认候选解释器在该脚本执行了四处记录，不证明影片解码、音画呈现、脚本外部效果或原版结局。

同一回放的 stderr 另记录片头 `data7.pack/script/makerlogo/omegastar.ogv`（SHA-256 `625776718ddb6f924876016ca263485f4681036df38703fc5e8120ec2dab17e7`）和影片 `data1.pack/movie/tum_ed.ogv`（SHA-256 `0962e6f34eb9b7c000a5e2a9b50659f1cbbf73e78bd82d94a0d463468a630c90`）的两个 `decoded_movie` 回执，分别报 7,041 与 91,100 ticks；`private/p1-round1000000066/cli-progress-data7/movie-decode-followup.json` 核对两回执均与 pinned resource 对应。这里的 `verified` 仅覆盖 headless 解码回执匹配；显示、音频输出和原版时序为 `not_tested`。`tools/advance_cli.py` 现也会在 `--verify-story-route` 下收集这些回执，修正先前只在读档路线收集的漏项。

同一选择 `0,0,0,1,1,1` 改用固定 `data8` 来源组直接运行，见 `private/p1-round1000000067/cli-progress-data8/summary.json`。该路线不需 `--source-override`，执行 70,853,676 步并消费完六项后回到标题；source bytes 和 `route_return_status` 为 `verified`，核验 156 个来源、8,061,669 字节。source-visits 未截断，96 个入口组的 51 个剧情文件集合与 data7 混合路线 `p1-round1000000065` 完全相同；两次步数相差 567,372，不据此推断内部状态相同。新摘要直接记录两项 pinned 影片解码回执：片头 7,041 ticks、`tum_ed.ogv` 91,100 ticks；`ed_movie.s` coverage 仍是相同四个 record location。编译源码 55 个摘要匹配当前工作树。data8 cohort 只是显式研究来源组，不证明原版实际包优先级；视频帧显示、可听输出和结局行为仍为 `not_tested`。

同一 data8 cohort 路线在 `private/p1-round1000000068/cli-progress-data8` 对 `data6.pack/scenario/本編/t21_01omake@.s` 增加 source-coverage。六项选择仍消费完并回标题，coverage 未截断，记录一个 label 和五个 command 位置，各执行一次。来源 SHA-256 `183b2783c49b6371c624acdbbb1ebab3fd7ca19157c52d421b4f5ffa1c93a89c` 的相对范围为 `(offset 36,length 12)`、`(47030,16)`、`(47048,8)`、`(47060,40)`、`(47242,76)`、`(47322,56)`，对应 `@@MAIN`、`\scp`、`\?sr`、`\if`、`\sub`、`\jmp`；位置证据为 `inferred`，不证明原版脚本语义或结局呈现。

data8 cohort 的 `[0,0,0,1,0,0]` 和 `[0,0,0,1,0,1]` 两条路线分别见 `private/p1-round1000000069`、`private/p1-round1000000070`；都消费六项后回到标题，source-visits 未截断，进入相同的 46 个剧情文件。它们对 `data6.pack/scenario/本編/t19b_02@.s` 的 source-coverage 均未截断并核验同一来源 SHA-256 `5014859ca29a81f955b89b62bf3d221d94da191045b04052640b40f489b64079`。最后一项为 0 时执行记录包括 label `(offset 66654,length 28)` 与 command `(70834,42)`；最后一项为 1 时记录另一 label `(70944,28)`，未记录前一组位置；二者共用的其他覆盖项不表示路径完全相同。逐项来源 byte range 与次数见各自 `attempt-00.json` 的 `sourceCoverage`；状态为 `inferred`，不推出标签名称或选择的完整语义。两次均只记录固定片头影片回执（7,041 ticks），未记录 `tum_ed.ogv` 解码回执；这不证明其未播放，也不证明音画实际输出。

对最后一项选择不同的两条 data8 路线，`data6.pack/scenario/本編/t19b_02@.s` 源 SHA-256 均为 `5014859ca29a81f955b89b62bf3d221d94da191045b04052640b40f489b64079`。`p1-round1000000069` `[0,0,0,1,0,0]` 的 coverage 记录 label `@@t19B_02sel_0`（offset 66654,length 28,SHA-256 `7e60d4d7f62ab20278899406fef58378eb88394b1ff903386b36fcd5b38ac832`）、一条 `jmp` command（offset 70834,length 42,SHA-256 `eb0da92dd7eb91b8c2a67c988e07390c406cae7c044579392792846a8751d253`）及汇合 label `@@t19B_02sel_end`（offset 76338,length 32,SHA-256 `6378e152975e0d919ca4a197a7527433a192774dd752000d3bd68c2d334b49d9`）。`p1-round1000000070` `[0,0,0,1,0,1]` 则记录 `@@t19B_02sel_1`（offset 70944,length 28,SHA-256 `8b618863bc93abae90ddae64ddf3720a0bddaccb39c8b56a8919c92e396d7574`）和同一个汇合 label。两份 coverage 均未截断、每项执行一次，说明候选解释器走过了两个不同的脚本标签位置；选择的剧情结果、变量影响和原版行为仍为 `not_tested`。

在固定 data8 cohort 中，前四项 `0,0,0,1` 后两项的 `00`、`01`、`10`、`11` 四种组合现在都有严格回标题报告：`p1-round1000000069`、`0070`、`0071`、`0067`，各自消费六项，`route_return_status` 和 source-byte-reference 均为 `verified`。其中 `10` 组合 `private/p1-round1000000071` 执行 65,056,337 步、核验 155 个来源和 8,068,259 字节，source-visits 未截断、覆盖 47 个剧情文件；其 `t19b_02@.s` sourceCoverage 为空，显示本次没有执行到目标脚本位置，而访问文件集合新增 `t19a_01.s`、`t19c_01.s` 等相邻分支。`private/p1-round1000000072` 对该路线的 `t19c_01.s` source-coverage 未截断，记录 1 个 label 和 2 个 command 位置各执行一次：相对 source SHA-256 `ac3573322c8ff727827c30724ec260aaa6fd42387d4777f2040738cd266d689d` 的 `(offset 36,length 12,SHA-256 2611eba76821cd690e55574e6dddf07674bf9b5147c480aa720879da03f1ad32)`、`(29794,76,aad03826351dfe1fb53a10678da21e7752528a46ae97bf0a1071dcb648f401f5)`、`(29874,56,b13727ee1aa136882294eed18ed3bdb1af9093547e19e487ffb7777642f34c2d)`。执行位置状态仍为 `inferred`，只证明候选解释器走过这些记录，不推断标签语义或原版结果。四种后两项选择均属 data8 来源组回放，实际包优先级、影片片尾播放及结局仍为 `not_tested`。

同一 data8 cohort 的 `[1,0,1,1,1,1]` 路线 `private/p1-round1000000075` 也严格消费六项并回到标题；对 `data6.pack/scenario/root.s` 的 source-coverage 未截断，共记录 168 个命令/标签位置。它进入 `@@Ending` 标签一次，并各执行一次位于 offset 11582、length 38 的 `ClearFlag` 命令和 offset 11624、length 36 的 `OpenFlag` 命令。根脚本 SHA-256 为 `1896843bba265f5d375f6c9df069d821344b4dadd75cf919e14d4f5a2e6863da`，两个命令范围 SHA-256 分别为 `52ca973883431c6d5978a468b4b8f41c4dc5d3cb1f05c210cf9326d8e9bb6db2`、`3481cb3f383567e0251d180191c065c09990b0b75bb8897e56e8c5984ff1a972`。此回放没有记录指令参数/写入值；这些位置不能证明通关标志持久化、对应结局已正确呈现或原版行为等价。

固定 data8 cohort 的 `[1,1,0,1,1,1]` 复跑见 `private/p1-round1000000076`；同样消费完六项、回标题，执行 70,744,702 步。source-visits 未截断，访问的 51 个剧情文件集合与 `[1,0,1,1,1,1]` 完全相同；root.s coverage 的 168 项也未截断，并执行同一 `@@Ending`、`ClearFlag` 和 `OpenFlag` 来源范围各一次，范围摘要与前一段列出的值相同。片头及 `tum_ed.ogv` 两条 headless 解码回执也与前一条一致。两种输入产生同一文件集合和这些执行位置，不证明内部变量状态、存档结果或原版结局等价。

固定 data8 cohort 的 `[0,0,0,1,1,0]` 路线 `private/p1-round1000000078` 消费六项并回到标题，执行 65,056,337 步；source-visits 未截断，覆盖 47 个剧情文件。`root.s` source-coverage 未截断，共 159 个位置，直接记录 line 1294 的 `#N_ClearFlag` 命令及 line 1295 的 `#SPOpenFlag` 命令各执行一次。相对 `data6.pack/scenario/root.s`（SHA-256 `1896843bba265f5d375f6c9df069d821344b4dadd75cf919e14d4f5a2e6863da`），范围为 `(offset 12078,length 38,SHA-256 4a2db7b15e75e15f848d54fd69c075bc50feb18c85d1360ebd65aa334a4d93cc)`、`(12120,36,3481cb3f383567e0251d180191c065c09990b0b75bb8897e56e8c5984ff1a972)`。该回放只证明候选解释器到达并执行了这些命令位置；写入值、存档持久化和结局呈现仍为 `not_tested`。

当前源码下四份 data8 cohort 路线的 root.s coverage 分别执行了四个候选通关标志命令位置：`#K_ClearFlag`（`p1-round1000000080`，输入 `0,0,0,0`，offset 8568,length 38,SHA-256 `3b550fdf57f8cb1c7f55ec554435ba010ddd027ccb7c4f8d60c5b78940bd5c`）；`#I_ClearFlag`（`p1-round1000000079`，输入 `0,0,0,1,0,1`，offset 9918,38,`e0bb2d0434ee868d2f43eddf0c8a0b466ec1e2735542fa5ee4ec5969243cb012`）；`#N_ClearFlag`（`p1-round1000000078`，输入 `0,0,0,1,1,0`，offset 12078,38,`4a2db7b15e75e15f848d54fd69c075bc50feb18c85d1360ebd65aa334a4d93cc`）；`#Y_ClearFlag`（`p1-round1000000075`，输入 `1,0,1,1,1,1`，offset 11582,38,`52ca973883431c6d5978a468b4b8f41c4dc5d3cb1f05c210cf9326d8e9bb6db2`）。这些命令各执行一次、覆盖均未截断；根脚本 SHA-256 为 `1896843bba265f5d375f6c9df069d821344b4dadd75cf919e14d4f5a2e6863da`。每条路线还命中各自相邻的 `#SPOpenFlag` 写入位置。coverage 不保存 RHS 值，不证明标志已写入正确值、跨存档持久化或原版结局状态。

## 哪些证据改变了实现

三份原生报告合计 33 个选定查询、17 项指定机器指令事实：`list-native-report.json`（10 / 7）、`list-helper-native-report.json`（17 / 7）、`list-path-native-report.json`（6 / 3）。这些计数包含伪代码、汇编及明确的函数覆盖查询，不能称为 33 个完整恢复的函数。

`list-binding-report.json` 重新核对类字段、类型单元、跳表和 6 处选定字节模式：

| 对象 | 静态绑定 |
|---|---|
| TImoObjectDataStringList | VMT 0x688764，实例 32 字节，obj +24；构造写类型字节 23 |
| TStringList | VMT 0x432d50，FCount +32、FCaseSensitive +42；不是 table 的 TFastStringList |
| 对象分派 | 类型 23 → 0x6cce64；类型 36 的 table 分派保持独立 |
| TImoPath | VMT 0x6a4ed8，实例 44 字节，SelfFilePath 回调 +24；上下文 +0x13c 绑定它 |

列表构造器明确把大小写标志设为零。`l` 分支打开流后调用组件清空和流载入；标准文本分割分支识别 NUL、LF、CR，并消费 CR 后的可选 LF。名称取值通过虚方法查找第一个分隔符和名称，再从匹配行取值；不能照搬 table 的双斜杠过滤或空值标记处理。

`?v` 的两种组件也有区别：list 在找到非空值后调用另一个整数转换帮助函数，传入两个零字，而不是 table 使用的数字默认值。当前核心只实现受限缓存转换，未覆盖的数值范围或拼写明确停止；完整 64 位转换为 `unsupported`。

`vexs` 的指令选择值为 0x73786576。所选分支把原始名称、当前帧上下文交给查询包装函数，随后把返回字节写入 ResultInt。包装函数实际从输出字节取值；伪代码呈现的无条件返回一不可靠。结合此前 `native-variable-report.json.lookup_order_category_3_2_1`，当前模型返回本地/全局/系统类别 3/2/1，未找到为 0，**不是统一的真假值**。

这些机器指令和元信息的局部检查为 `verified`；对象语义组合及移植实现为 **Hypothesis / inferred**。原引擎等价性保持 `not_tested`。

## 资源查找的适用范围

`l` 所用路径解析器会先调用 SelfFilePath 回调，尝试拼接当前路径与输入，再尝试输入本身，之后还有配置路径列表。上下文的回调绑定至 0x6d1534；有界窗口可追至读取器当前键、记录 +12 和目录提取帮助函数。目录分隔常量包含反斜线和冒号。

当前实现只把前两个候选映射到固定来源目录表：当前脚本的逻辑目录，然后原始逻辑名。存在不同字节副本时仍须显式选择，不能因后面的根目录副本唯一而绕过前面的歧义。配置搜索目录、Windows 绝对路径与文件系统扩展、完整预处理后的来源恢复尚不支持。此限定见 `ScriptModuleCatalog.resourcePath` 和 v5 契约；没有把它称为完整 Windows 路径兼容。

真实片段因此能以 `ValueDefault.txt` 关联到 `script/config/valuedefault.txt` 的两份副本；最终仍分别选择 data7 或 data8，未自动决定包优先级。

## 非 ASCII 名称如何处理

`ScriptStringList` 保留全部行及来源摘要，不在载入时删除注释形状的行，不转换 `%%none%%`。公开行摘要只含字节位置、正文/名称/值的 SHA-256 和比较状态。

现有实现只覆盖 ASCII 名称比较。非 ASCII 名称正常保存，`comparisonStatus=unsupported`；查询按来源顺序进行，在匹配前遇到这样的名称就停止，报告该资源行位置。已在更早的受支持名称处命中的查询可以返回，不会越过未知比较继续查找。`nameCount` 仅统计本模型的不同 ASCII 名称，`unresolvedNameCount` 统计未解释比较的名称行数，不是原生等价键数量。

两份真实列表均有 76 行、48 个 ASCII 名称和 1 行未知比较。此次执行所需查询在到达未知行前已命中；这不能证明未来查询或其他文本没有区域比较问题。Windows 用户区域设置和缺省代码页仍未复现。

## 本地实现和真实结果

`ScriptStringList.swift`、`ScriptStorage.swift` 和 `ScriptMachine.swift` 新增：空列表句柄、混合对象作用域、固定摘要的列表载入、有限取值、变量类别检查及整条失败指令不提交。每个文本限 1 MiB / 10,000 行 / 每行 8,192 UTF-8 字节，列表累计来源 8 MiB / 50,000 行；table 与 list 句柄合计最多 512。其他数组、字符串、快照和执行时间限制继续生效。

`list-execution-report.json` 固定本次源码、ARM64 执行文件及十份依据报告的摘要。全部 379 份文本、291,273 条词法记录再次与 Python 字节模型比较，零差异；列表行摘要另由独立 Python 模型重建。它们不是原引擎变量值或演出等价测试。

| 显式选择范围 | 处理记录 | 观察到的停止 |
|---|---:|---|
| 不选版本 | 20 | 模块歧义 |
| 只选初始化模块 | 29 | 配置歧义 |
| 初始化模块及两份配置 | 257 | 下一模块歧义 |
| 再选配置脚本 | 266 | 当前目录列表副本歧义 |
| 再选对应列表副本 | 715 | 未支持的 for，三参数 |

最后三行的明确选择分别对 data7、data8 保留独立场景；总共 8 个场景。715 条路径均完成 27 次变量类别检查、48 次查询及 3 次文本载入，逐个核对 839 个来源字节引用。为保持既有轨迹字段稳定，公共处理器的一些动作名仍含 `table`，这里的查询/载入总数包含 table 与 list，不能当成表专属统计。

终点引用均为 `script/config/value.s` 第 207 行：data7 offset 4384、length 16；data8 offset 8770、length 32。完整源摘要及范围摘要见各场景的 `machine.currentLocation`；下一条没有执行，也没有跳过未知循环。处理记录包含空行与元记录，不能换算为整作进度。

## 测试、失败与边界

新增 11 项 Swift 自建测试覆盖重复名称、标记/斜杠保持、空值、非数字零缓存、范围拒绝、CR/LF/UTF-16 字节位置、混合作用域、类别 0/1/2/3、结果字符串保持、相对路径优先、版本歧义、失败原子性及未知名称顺序。原生测试合计 85 项通过。新增 4 项 Python 测试核对独立行模型、限制和伪造报告拒绝。

首次回归有一项测试仍断言当前 profile 必须为 v4；调整到 v5 后通过，旧日志保留。早期列表模型在载入时拒绝非 ASCII 名称；真实样本暴露该限制后改为保留并在实际比较处停止，未用跳过未知行来推进。

Ghidra 默认分析缺少 7 个选定函数，最初共 14 次代码查询失败；后续显式覆盖查询和 9 个有界 LLVM 窗口保留这些缺口。没有修改 Ghidra 元数据，`default_function_coverage_status` 仍为 `unsupported`。窗口的选定范围解码检查通过，不代表完整函数边界或完整控制流已恢复。

探索时曾从一处指令中间开始窗口解码，随后改用已经核对的起点；该初始窗口没有用于事实。另一次类绑定把偏移 +20 交给仅遍历到 +12 的最小槽位探针，触发拒绝；后改为对较大偏移独立读取并核对目标。原始查询/窗口/回归日志保留在 private，未修改上游或覆盖 P0 来制造通过。

完整检查见 `round28-tests.json` / `round28-readiness.json`：研究 Python 350 项通过、零跳过；系统 Python 347 项通过、3 项跳过；上游合成检查 26 项通过、8 项商业 fixture 缺失而跳过。跳过不计作通过。20 个关键原文件摘要及 12 份冻结 P0 报告保持一致。

ARM64 0.6.0 构建及 10 个既有图片样本核验见 `native-app-round28.json`。本轮还实际通过 CUA 界面完成导入、五次 data8 版本选择，并观察到 20 → 29 → 145 → 257 → 266 → 715 条记录的状态变化；最终列表 76 行、for 第 207 行 offset 8770，与命令行相符。`gui-replay-round28.json` 保存这一次观察的脱敏元数据；生成命令只核对已保留的观察和 CLI/应用摘要，不伪称自己执行了 UI 自动化。`verify_native.py` 自身不操作界面，其 GUI 字段仅表示该命令未执行回放。其他界面路径为 `not_tested`。

## 复现

使用用户合法持有且摘要匹配的原目录与研究副本。JAVA_HOME、GHIDRA_INSTALL_DIR 和所有输入路径由使用者提供：

```sh
.venv/bin/python tools/rea_static.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-list-plan.json --output private/p1-round28/native-reproduced \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
.venv/bin/python tools/rea_static.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-list-helper-plan.json --output private/p1-round28/helper-confirmed \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
.venv/bin/python tools/rea_static.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-list-path-plan.json --output private/p1-round28/path-native \
  --java-home "$JAVA_HOME" --ghidra-dir "$GHIDRA_INSTALL_DIR"
.venv/bin/python tools/native_windows.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-list-windows.json --output private/p1-round28/windows
.venv/bin/python tools/review_native.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-list-plan.json --facts docs/native-list-facts.json \
  --evidence-dir private/p1-round28/native-reproduced --output reports/p1/list-native-report.json
.venv/bin/python tools/review_native.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-list-helper-plan.json --facts docs/native-list-helper-facts.json \
  --evidence-dir private/p1-round28/helper-confirmed --windows-dir private/p1-round28/windows \
  --output reports/p1/list-helper-native-report.json
.venv/bin/python tools/review_native.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL" \
  --plan docs/native-list-path-plan.json --facts docs/native-list-path-facts.json \
  --evidence-dir private/p1-round28/path-native --output reports/p1/list-path-native-report.json
.venv/bin/python tools/list_bindings.py --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL"
.venv/bin/python tools/verify_list_execution.py \
  --assets-dir "$ASSETS_DIR" --script-file data0.pack/startup.s
python3 tools/build_native.py
.venv/bin/python tools/verify_native.py --game-dir "$GAME_DIR" --assets-dir "$ASSETS_DIR" \
  --output reports/p1/native-app-round28.json
.venv/bin/python tools/verify_gui_observation.py \
  --observations private/p1-round28/gui-observations.json
.venv/bin/python tools/research_checks.py --game-dir "$GAME_DIR" --stage round28 \
  --artifact reports/p1/list-native-report.json --artifact reports/p1/list-helper-native-report.json \
  --artifact reports/p1/list-path-native-report.json --artifact reports/p1/list-binding-report.json \
  --artifact reports/p1/list-execution-report.json --artifact reports/p1/native-app-round28.json \
  --artifact reports/p1/gui-replay-round28.json
```

保留历史查询失败时可给第二次 review 加 `--attempts-file private/p1-round28/helper-attempts.json`。当前阶段下一步是核对三参数 `for` 的初始化、条件、更新与退出时点，再接入循环；仍需继续完成列表操作、区域比较、资源后端加固、画面演出、音频、分支和存档。

用户随后要求加速，优先命令行，直至完整运行后再继续 UI。因此 0.6.0 界面保持冻结，以上界面构建与回放只作为已完成的历史验证；后续按核心功能批次推进，复用已核对证据，不再逐个增量重复界面工作。GUI 观察若要再次执行，可导入自有研究副本、选择 startup.s，再按 GUI 报告 selected_sources 的顺序选择版本；这属于手动复现，不是上述摘要命令的功能。
