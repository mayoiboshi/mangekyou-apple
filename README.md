# Project Mangekyou — 第四作原生移植

[功能里程碑与验收](docs/40-feature-milestones.md)

**当前状态**：Apple Silicon 发布版已用真实资源完成过一条从开场、正文、六次选择到片尾并返回标题的 GUI 回放；该结果只覆盖对应回放路径，不代表整作兼容。当前优先通过命令行推进脚本、资源和存档能力验证；完整运行能力闭合前，界面开发冻结。其他路线覆盖、持久存档完整恢复及原版演出还原仍待验证。原始目录始终只读。

### 动态 CG 与汉化验证

- `verified` · 较早的发布构建已用本地汉化覆盖完成一条 GUI 路线，记录六次选择、两段影片结束及返回标题。验收依据为同一次私有回放的 `player_choices_resolved`、`player_movie_finished` 与 `player_route_returned_to_title`。
- `verified` · ARM64 发布版以实际选项索引 1、0、0、1、1、1 完成汉化替代路线，记录 81 次动态 CG 首帧，并在片尾后返回标题。首帧次数包含重复进入同一资源。依据为同一次私有回放的 `selected_index`、`player_scene_video_first_frame` 和 `player_route_returned_to_title`。该次长回放使用随后一批边框和立绘绘制改动之前的发布版。
- `verified` · 当前构建的定向 A→B→A 回放输出三次首帧，记录两次视频准备。可分别核对 `player_scene_video_first_frame` 和 `player_scene_video_prepared`。
- `unsupported` · 汉化长程回放仍报告部分 ABMP 复合演出及立绘动作图层问题。可核对 `player_missing_layers` 和 `unsupported_animation_layers`。
- `not_tested` · 汉化全路线、动态 CG 的原版时序和图层合成一致性仍待验收。

### 实验性读档

- `verified` · 在隔离存档中以单精度浮点字段写入 1,001 毫秒，并用真实游戏音频复测原生窗口。预检通过，窗口从存档通道 0 发起 1,001 毫秒定位并起播。同一次采样的原始位置为 1.000997732426304 秒，比请求早约 2.27 微秒，截断后记为 1,000 毫秒。可核对同一次私有回放的 `player_save_stream_started` 和 `player_experimental_save_playback`。
- `verified` · 用合成脚本、本地真实 Ogg 音频和混合构造的私有模板，命令行导出了包含活动流音轨的槽位。独立检查进程读回通道 0，确认 `rawSeekBits` 与 1,001 毫秒的单精度表示一致。
- `verified` · 合成脚本在等待前把局部整数从模板中的 −2 更新为 87。命令行导出的槽位经独立读取确认值为 87，原生窗口读档后通过依赖该值的计算并进入下一次点击等待。依据为 `calValArrays.indexed.groupSpans` 和 `player_experimental_save_playback`。
- `verified` · 合成 `sub` 调用在子程序等待时导出槽位。原生窗口恢复后，分别执行依赖整数和字符串参数的计算，从子程序返回并进入调用方的点击等待。依据为 `player_experimental_save_adopted` 和 `player_experimental_save_playback`。
- `verified` · 合成脚本用真实游戏音频导出待播音轨。独立原生窗口读档时只加载资源，随后执行播放指令，以 1,251 毫秒的请求位置、0.5 的初始增益和 −0.125 的声像起播，再进入点击等待。依据为 `staged_streams`、`scheduled_streams` 和 `player_save_stream_started`。
- `not_tested` · 原引擎的定位舍入规则，以及应用写档后重新加载完整游戏状态，仍待验证。

命令行可在有目录索引的单脚本实验运行中追加 `--save-dir "$DONOR_DIR" --export-timed-wait-slot SaveData0.svd`。二进制槽位写到标准输出，诊断写到标准错误。将输出定向到独立的 `private/` 路径。当前支持符合写档约束的计时等待、点击等待，以及单个字面回调且无计时参数的 `stop`；后者仅在合成槽位和隔离恢复探针中验证，真实剧情仍受活动控制块、对象作用域和音轨模板限制。模板缺少简单 ASCII 名称的一维整数或字符串全局绑定时可实验性生成记录，已支持的内嵌列表和表也可生成记录，缺少其他对象记录时会报告缺失数量并拒绝导出。已有 `ValIdx` 分组且局部绑定与模板一致时，可写入整数和字符串局部变量。模板提供完整参数组时，也可写入 `sub` 调用的整数和字符串参数。局部对象和对象参数仍不支持。带活动流音轨时，可用可重复的 `--save-stream-position 通道=毫秒` 手动提供每个通道的实测位置，且模板和运行状态的活动通道必须匹配。输出沿用模板的元数据和缩略图，使用未变换的状态。导出时关闭模板直播放音轨的重新加载标记，避免读档后播放旧音效。当前运行中的直播放音轨尚未纳入写档。可用 `--save-display-surface 索引=绝对路径` 分别替换索引 0 和 1 的已有内嵌画面（每个索引使用一次参数），图像须可解码且与模板格式一致。其他画面字段仍取自模板。追加 `--save-scene-thumbnail --scene-preview-background 相对路径` 可把当前命令行场景编码为 JPEG 缩略图，尺寸默认由背景画布决定，也可使用下文的画布尺寸选项。预览不完整时拒绝导出。

系统变量研究模式可追加 `--save-dir "$DONOR_DIR" --research-system-file SystemData.dat --game-dir "$GAME_DIR" --research-system-exe "$GAME_EXE_REL"`。如需在单脚本会话结束时写出研究副本，再加 `--research-system-output 既有私有子目录/新文件名`；目标相对于当前工作目录的 `private/`，必须预先创建父目录，不得已存在或位于输入目录内。该功能处理匹配供体的整数、字符串变量以及已核验格式的四字节文件日志和标签日志。自动记录已读进度尚未实现；默认对依赖原版读取器上下文的 `llog ?k2` 明确报告未支持，包括日志为空的情况。仅供命令行研究的 `--research-label-read-status` 可对具有唯一标签和来源的调用帧使用候选比较，或在空日志下返回未读候选；它未证明原版读取器位置及无查询键时的结果等价。原版读取兼容性和完整通关状态恢复尚未验证。

显式 `--research-image-file-log` 可研究已注册路径下图像加载时的文件日志计数；它只覆盖主实例中本地成功解码的图像类加载，使用清单中的候选路径，系统子任务、其他文件访问、原版路径拼写及失败时计数均未验证。报告标记 `inferred`，不能视为完整自动文件日志。

不导入系统数据的只读单脚本会话也可显式指定 `--research-label-read-status`，研究脚本运行时写入标签日志后的候选已读查询；该模式仍要求资源目录表，不允许研究槽位导出。候选读取器上下文与原版等价仍未验证，默认模式遇到非空标签日志时继续明确停止。

显式 `--research-label-progress` 可在系统数据研究会话或不导出研究文件的新会话中尝试记录标签进度：仅处理主实例的非内部、唯一标签下已完整推进的受限行，包括同来源直线行和空白行、本地对白、音声及空行前缀调用正常返回后的行，以及单层无标签子文件展开的候选行；锁定或锁状态未知时不写入。报告分别统计候选写入、跳过原因以及已读查询的候选结果；跳转、等待及复杂包含展开等情况仍有缺口，本地位置与原版读取器的对应尚未验证，不代表完整自动已读追踪或跳过功能验收。

计时事件等待可在单脚本只读回放中组合 `--click-ticks 预算 --research-timed-stop-frame-ticks 帧间隔`，按构造帧间隔推进并在未到期时执行等待回调；预算不足一帧时保留现场。活动影片、计时器或待消费跳过时间会明确停止。跳过研究可在显式启用静音音频观察及零时钟候选、帧间隔一致时，对身份匹配的活动流音轨处理一个零时钟回调帧并立即停止；其他活动音频仍拒绝。帧间隔由调用者指定，输入采样、完整对象更新及原版调度等价仍未验证。

上述零时钟候选可额外指定 `--research-zero-callback-followthrough`，在回调返回后最多继续 512 个脚本步骤；遇到等待、绘制或未知音轨状态变化即停止。零时钟写入可保留到下一个帧边界；待处理期间若音轨改变则停止。对真实流音轨重置，仅在其余活动流和控制状态不变、身份均匹配时，将被重置通道从静音观察器中移除并继续，最多交接 64 次，包括移除最后一条流。该候选默认不推进下一帧或确认未完成的声音控制。

受限跟随可将新增流音轨请求交给有界解码器和静音观察器，最多交接 64 次；仅支持无需定位、无需保留旧播放位置的一次播放或无限循环，且要求原有活动流状态与身份保持匹配。有限循环及其他未覆盖的媒体变化仍会停止；静音观察不能证明可听播放或原版同步。

活动流的重复 `p2` 在来源和播放实例匹配时复用静音播放器、保留位置及未完成控制，并更新可表达的循环设置。受限跟随也可交接播放器明确回调成功的自然完成；无成功回调、身份不一致或其余通道发生未建模变化时停止。

受限跟随也可交接可表达范围内的单通道音量和声像请求，最多 64 次；其他通道及被修改通道的其余状态必须保持匹配。过渡由本地静音播放器按墙钟采样，不能据此确认原版淡入淡出或设备时序等价。

研究中的 `skip` 累加值可在脚本仍处于可执行状态时保留，直至下一个等待或绘制边界；这段时间不会提前消费。待消费时间期间若发生音轨状态变化或需处理零时钟，则停止并报告。

在上述绘制帧研究中额外指定 `--research-skip-audio-frame`，可在身份匹配的活动流音轨下，将待消费 `skip` 值与构造帧时间相加并更新本地位置时钟，单帧合计上限 60000 tick，并受已有总帧数、步骤和时间预算约束。音频仍使用独立的静音墙钟，完整对象更新、可听效果与原版同步未验证。

绘制帧上限可显式指定 1 至 16384。启用 `--research-zero-audio-draw-frame` 后，可用 `--research-followthrough-max-steps` 指定 1 至 64000000 步，用 `--research-followthrough-max-seconds` 指定 1 至 1200 秒；默认分别为 6000000 步和 120 秒。总脚本、音频观察、身份与内存限制仍独立生效。

只读研究回放可在上述受限跳过模式及 `--require-route-return` 下显式加 `--research-title-start-after-return`，在所有预设选项消费完、标题开始按钮可用且音轨身份匹配时投递一次开始输入，并记录后续停点。该探针不代表原版输入或完整路线验收。

在上述跟随模式及帧预算内，还可显式指定 `--research-zero-audio-draw-frame`，对身份匹配的静音观察流推进构造的正时钟绘制帧，并以相同状态检查继续执行；总共最多 1000000 个后续脚本步骤、30 秒及指定帧数，遇到其他边界即停止。回执记录每帧前后的音轨观察位置。该操作不渲染画面，静音播放器的墙钟与构造帧时钟并未同步，原版等价未验证。

另可显式使用 `--research-audio-file-log` 研究主实例中通过格式检查的 WAV 直接音效和 Vorbis 流音轨加载；它使用同一候选路径匹配，未覆盖系统子任务、其他音频格式、加载失败及原版实际解析路径。报告标记 `inferred`，不代表原版文件日志等价。

研究写档目前无法观察正数有限循环音轨的剩余次数；即使手动提供播放位置，也会拒绝写入该活动通道。单次播放及无限循环仍需通过现有资源、供体与状态检查。

单脚本回放可显式添加 `--start-from-title` 从标题开始新游戏。添加 `--headless-movie-tools "$TOOLS_DIR" --observe-live-audio` 时，命令行实验宿主会以静音 PCM 播放器观察活动流音轨的实时游标，并在播放器达到可表达的音量、声像目标后确认控制完成；可选 `--live-audio-observe-ms 毫秒` 等待 1 至 5000 毫秒并在回执中记录前后游标。该模式不能与手动 `--save-stream-position` 同用；写档时会使用观察到的游标，但仍要求资源、供体和其他状态通过检查。游标与 FFprobe 音轨时长的毫秒值使用单精度秒数和最近偶数取整的候选换算；播放器使用实时墙钟，而脚本等待可能被加速，不能将所得时间或控制过渡视为原版同步或完整存档兼容。音频转换只使用有界、立即解除目录链接的临时文件；有限重复播放支持最多 1024 次，但未观测到剩余次数的活动音轨仍不能写入研究存档。

静音观察器不实现流音轨的非空滤镜；遇到活动通道的非空或未知滤镜，以及播放期间短暂设置后又清除的非空滤镜，会在下一次宿主同步时报告 `live_audio_stream_filter_application_unverified`。这只能标识缺口，不验证滤镜效果或脚本与音频的时序。

命令行研究可在 `--observe-live-audio` 基础上显式加入 `--research-audible-volume-filter`，尝试播放未加滤镜或使用单一 `volume` 滤镜的流音轨。**该开关可能发出声音，包括未加滤镜的音轨。**候选默认将音轨重采样为 22050 Hz 双声道，也可显式指定 `--research-audio-rate 44100`；随后执行整数滤镜并饱和转换为 16 位音频，起播时静音，再按宿主音量和声像控制同步。受限的滤镜启用、更新和清除通过重建播放器交接，可能出现停顿与位置偏差；有限循环、未完成的音量或声像变化、滤镜链、不明状态及超限音轨会停止。此模式不支持研究写档或跳过研究，不能视为原版音质、时序或整作音频兼容。

该实验路径分块处理解码音频，单轨候选 PCM 不超过 53000000 字节、探测时长不超过 600 秒；44100 Hz 使用相同字节上限，因此可容纳时长比 22050 Hz 短。多个活动播放器与交接中的新播放器共享 96 MiB 数据预算，分块处理限时 120 秒。超过预算时明确停止。

如只需验证该候选路径而不外放，可同时传入 `--research-muted-volume-output`；音频仍经候选解码和处理，播放器输出强制为零，回执的时钟类型会注明静音。这个选项只适用于上述实验路径。

独立命令行研究可使用 `mangekyou-inspect --probe-stream-volume-filter --assets-dir "$ASSETS_DIR" --pcm sample.pcm --filter 'volume,vol:150,pan:25,range:100'`，读取目录内不超过 4 MB 的双声道、16 位小端 PCM，报告候选处理结果摘要。这里只接受单个音量滤镜及受限参数，串联效果及未知格式明确拒绝，原版样本表示和效果等价仍未验证。

可在上述探针后追加 `--update-filter 'volume,pan:75'`，将一次同类型更新合并到已有候选参数；再加 `--update-frame 22050` 可从调用方指定的样本帧开始使用更新后的参数。该位置是构造输入，不代表原版帧调度。

也可追加 `--research-wav 现有私有子目录/新文件.wav --sample-rate 44100`，将候选样本饱和转换为 16 位 WAV，输出至当前目录的 `private/` 下。采样率由调用方提供；文件不会覆盖已有条目，输出目录不能位于输入目录内。该副本可供独立试听研究，但转换及声音与原版是否一致未验证，尚未接入游戏播放。

静音观察器默认最多累计启动 512 次，可通过 `--live-audio-max-starts` 指定 1 至 8192 次；同时最多持有 8 条流和 96 MiB 音频数据。观察时限默认 120 秒，可通过 `--live-audio-max-seconds` 指定 1 至 3600 秒。回执记录预算及启动次数；达到限制时保留停止现场和原因。

静音观察模式会在脚本交换流音轨通道时核对并交换对应播放器；来源或播放实例无法匹配时停止。该交接是本地研究候选，不表示已验证原版音频时序。

观察模式仅在收到播放器成功完成回调且播放实例仍匹配时，向核心确认自然结束；没有完成回调的停止状态不会被视为成功。

在观察模式尝试研究写档时，回执会独立记录 `saveAudioPreflightStatus` 和 `saveAudioPreflightIssue`，即使全局对象或线程检查失败也可查看音轨供体是否匹配。独立预检仅在内存中验证，不输出槽位，也不覆盖主写档结果。

### 打开试玩窗口

运行 `python3 tools/build_native.py` 后打开 `build/Mangekyou.app`。从菜单打开「试玩窗口」，在「载入本地回放配置」菜单点「选择回放配置…」，依次选择已准备的本地资源副本目录、本地回放目录、对应的原版游戏目录。已有本地解码的汉化脚本和 PNG 时，可将它们按游戏逻辑路径放在资源目录内的独立子目录，再生成私有回放清单。每个覆盖目录用一次 `--overlay` 指定。工具输出的新清单目录可直接传给播放器的 `--replay-dir`。

```sh
python3 tools/prepare_localization_replay.py \
  --assets-dir "$MANGEKYOU_ASSETS_DIR" --replay-dir "$MANGEKYOU_REPLAY_DIR" \
  --overlay local-cn.pack --overlay local-cn-png.pack
```

也可从本地已验证版本的 `.cn` 生成覆盖目录。先从自己持有的 1.00 补丁取得匹配的 EXE，再运行下列命令。它只读取 EXE 字节，并将脚本、带 BOM 的 UTF-16 配置、PNG、Ogg 视频和 ABMP 容器写入工作区 `private/` 下的资源目录。把输出的 `overlay` 值传给上面的 `--overlay`。

```sh
python3 tools/decode_localization_cn.py --assets-dir "$MANGEKYOU_ASSETS_DIR" \
  --loader "$MANGEKYOU_CN_LOADER" --cn "$MANGEKYOU_CN_FILE"
```

命令按 SHA-256 识别已验证的 1.00 加载器和两份 `.cn`。其他版本尚待接入。已核对的 GBK 音乐鉴赏表会转换为带 BOM 的 UTF-16LE。若覆盖目录含 `.b`，先用固定版本的上游环境运行 `tools/abmp_probe.py --input FILE --private-extended-values`，将各报告写入独立的私有目录，按逻辑路径把 `.b` 后缀换成 `.json`。生成回放清单时用 `--abmp-audit-dir` 指定报告目录。工具按容器和成员摘要核对报告后生成配方。

应用优先复用上次配置中的 `ffmpeg`，其次检查 Apple Silicon Homebrew 的默认位置，两者均不可用时才提示手动选择。回放目录需要包含 `summary.json`、`combined-catalog.json`、`image-recipe.json`。新版摘要包含资源清单时可直接启动，旧版摘要仍需要相应的回放日志。试玩仍依赖这些由本地研究流程生成的资料。也可以选择「选择回放配置及只读存档…」，在最后一步指定存档目录。首次成功加载后，可在同一窗口使用「打开上次试玩配置」。

可用 `python3 tools/merge_replay_receipts.py --base "$BASE_REPLAY" --donor "$OTHER_REPLAY" --output private/merged-replay` 合并本地回放的资源记录。`--donor` 可重复传入，输出目录须为新目录。命令保留基础回放的脚本、选项和已有图像解码配置，并补入资源摘要匹配的新配方。同名资源记录冲突或新增配方冲突会停止。播放器读取资源时仍会核对文件摘要。

标题菜单默认收在画面右侧。把鼠标移到右侧会展开菜单，移回左侧会收起。菜单位置按脚本给出的时长逐帧更新。

也可以直接启动发布构建。以下环境变量均应指向本机的绝对路径。

```sh
swift run --package-path native -c release Mangekyou \
  --assets-dir "$MANGEKYOU_ASSETS_DIR" --replay-dir "$MANGEKYOU_REPLAY_DIR" \
  --game-dir "$MANGEKYOU_GAME_DIR" --ffmpeg "$MANGEKYOU_FFMPEG"
```

Apple Silicon Homebrew 默认位置已有可执行的 `ffmpeg` 时，命令行也可省略 `--ffmpeg`。

可通过 `--save-dir "$MANGEKYOU_SAVE_DIR"` 只读导入剧情存档。若同时使用探针选项，探针选项放在最后。读档菜单显示可识别的槽位和元数据，并在已支持的图层条件下合成缩略图。遇到暂不支持的合成条件时会显示静态缩略图。导入目录仅供读取，菜单中的删除按钮目前只显示贴图。确认后，应用尝试恢复已支持的脚本与媒体状态，失败时保留读档前的会话并显示原因。变换存档的校验模板来自已核验的第四作原版 EXE，应用只读取该文件。本地提供的 `SaveData` 目录仅有 `SavePath.txt`，附带的 `SystemData.dat` 是系统数据。当前续跑验证使用私有研究槽位，原版生成的剧情槽位兼容性待验证。

在末尾加 `--check-choices=3` 可使用回放清单的选项顺序，验证前三次剧情选择。该模式加速等待并跳过音频播放，到达指定选项后的等待点即停止自动推进。

### 读档入口的任务切换

使用与试玩相同的四个路径参数，并在末尾加 `--open-load-menu`，可复现标题读档入口。真实回放在 `data8.pack/script/title/main.s` 第 86 行发出 `@@!Load` 任务请求，主实例进入等待并保留画面。主程序静态证据显示，`0x6b091f` 识别 `thrd`，`0x6b0ff6` 和 `0x6b1002` 分别为模式 0、1 写入状态 `0x17`、`0x16`，`0x6b1014` 保存第二操作数。调度器在 `0x6d579c` 读状态并通过 `0x6d57be` 跳转表分派。模式 1 经 `0x6d5b74 → 0x6d77e0`，在 `0x6d785b` 用位于 `0x6d7930` 的格式串构造进入 `SysStartUp.s` 的跳转，再对 `[host + 0x50]` 中的脚本实例调用 `0x6bec70` 和 `0x6d16f4`。模式 0 经 `0x6d5b6a → 0x6d7a90`，调用同一实例的清理入口 `0x6aedb4` 并分派停止事件。模式 1 的事件名位于 `0x6d796c` 和 `0x6d79a4`，模式 0 的事件名位于 `0x6d7af4` 和 `0x6d7b28`。

独立脚本 `data0.pack/sysstartup.s` 的读档入口在第 22 行，第 24 行转入 `script/saveload/main_load.s`。该读档脚本在清理界面后于第 158 行执行模式 0。把标题中的同名标签当作普通子程序目标会再次进入同一条任务指令。系统脚本目标已有原版静态证据。宿主在 `0x6d6141` 和 `0x6d61a9` 分别构造脚本实例，并将它们存入 `+0x4c` 和 `+0x50`。第二实例在 `0x6d61d3` 把第一实例作为初始化参数传入，两次初始化也收到同一组宿主服务引用。模式 1 在 `0x6d7836` 把宿主切至状态 6，模式 0 在 `0x6d7abc` 切回状态 5。`0x6d64dc` 在状态 6 选第二实例，其余状态选第一实例。退出时，`0x6d7ae0` 还会向第一实例分派事件。第二实例把第一实例引用存入自身 `+0xc8`（`0x6be972`）。初始化尾部在 `0x6beb9c–0x6bebbb` 从第一实例的 `+0xe8` 读取表引用，经 `0x69f3a0` 取有效表，再由 `0x69f270` 写入第二实例表对象的 `+0xc`。同一访问器也用于 `0x69d101`、`0x69d218` 等操作，优先返回该引用，缺失时使用自身 `+0x8`。名称查找在 `0x69f43a` 用另一访问器 `0x69f278` 查类别 2，命中后在 `0x69f44e` 返回类别 2。下一层在 `0x69f45c` 用共享表访问器 `0x69f3a0` 查找，命中后在 `0x69f470` 返回类别 1。结合已核验的声明分派，`svar` 走共享表，`gvar` 走独立的类别 2 存储路径。共享对象所有权、退出清理范围和跨实例写入仍待验证。

将真实 `sysstartup.s` 的 `@@!Load` 入口最初单独交给命令行解释器时，第 6 步停在第 126 行的 `srct,1`。原版分派 `0x6afe2f → 0x6b0740` 求值后在 `0x6b076a` 写入实例的 `+0x174`。系统指令分派 `0x6b2228–0x6b2238` 在该值为零时使用当前实例，非零时使用 `0x6cb45c` 返回的主实例引用。紧接着的 `sys p,0` 在 `0x6b2388–0x6b238a` 对选中的实例执行模式重置。因此读档入口需要跨实例更新主任务状态。单实例探针现在覆盖已核对的自引用回退。显式选择 data8 脚本变体后，真实读档探针越过系统入口，第 56 步停在 `main_load.s:243` 的主画布快照请求。`imoscripter_base.s:101–105` 将 `%%%capture_` 参数映射到 `$$$GameThreadImageZ` 名称，解释器已将此请求与归档缺件区分。标题播放器已能启动独立读档任务，并让已核对的 `srct` 系统播放模式读写作用于主实例。真实标题回放已将等待中的主画布渲染为 1280×720 的内存快照，并交给读档任务。副任务运行期间与暂停的主任务同步 `svar` 标量表。真实标题回放已越过 `main_load.s:251` 的 `#NewSaveFilename` 读取，并越过第 83 步的 `sys ?in`。原版 `0x6b2d2b`、`0x6b2d5a` 和 `0x6b2d72` 分别重置、写入和读取 `srct` 选中实例的 `+0x164` 字段。原生核心已接通这些状态操作，宿主事件过滤仍待验证。真实标题回放在第 113 步停于 `script/dialog/layout_message.s:16`，本次回放清单缺少它请求的资源。共享对象、任务退出和实际读档仍待实现。

### 命令行路线回放

下例使用本地资源副本、原游戏目录和私有回放清单，验证从标题读档菜单翻页、取消、开始新游戏到再次返回标题的路径。设置 `ASSETS_DIR`、`GAME_DIR`、`REPLAY_DIR`、`CAPTURE_PNG` 和 `MOVIE_TOOLS` 为本机路径。回放目录需有 `combined-catalog.json`、`image-recipe.json` 和 `summary.json`。截图输入使用 1280×720 PNG，可用合成图。

```sh
.venv/bin/python tools/advance_cli.py \
  --assets-dir "$ASSETS_DIR" --game-dir "$GAME_DIR" --source-cohort data8 \
  --stage round9911 --verify-route-return --replay-dir "$REPLAY_DIR" \
  --load-task-capture "$CAPTURE_PNG" --load-task-page 1 \
  --headless-movie-tools "$MOVIE_TOOLS" --pointer 1100,360 --dispatch-stop-callback \
  --maximum-steps 96000000 --click-ticks 3000000 --message-clicks 24000 \
  --story-choice 0 --story-choice 0 --story-choice 0 \
  --story-choice 1 --story-choice 1 --story-choice 1
```

页码和选项从 0 开始。 每次路线验收使用未占用的 `--stage`，以便保留之前的回放证据。退出码为 0 要求消费全部选项，并回到可响应输入的标题菜单。回放停点和剩余选项保存在 `private/`。这项验收覆盖所选路线的脚本执行，原版画面对照、其他路线和实际存档恢复仍需独立验证。私有回执已确认 `0,1,0,1,1,1`（round9912）和 `0,0,1,1,1,1`（round9913）均消费六次选择并返回标题。后者的 `story_choice_available` 日志显示六处均可选索引 0 和 1。该结果按选项组合计，不能据此确定独立结局数。

在无存档供体的私有只读路线研究中，可显式追加 `--research-label-read-status` 使用核心的已读状态候选；报告会标记为 `inferred`，不代表原版已读行为已经验收。

路线回放可追加 `--title-menu-target sound`（也可选 `album`、`memory`），在消费全部选择并返回标题后，按当前按钮的可选状态尝试进入对应鉴赏入口。回执分别记录返回标题、实际点击及入口失败原因；点击成功不等同于鉴赏功能验收。

直接从已恢复的系统数据启动时，也可使用 `--title-menu-target album` 或 `memory`，并通过重复的 `--subsequent-button 数组名:索引` 在进入页面后投递受检查的按钮事件；回想脚本可另设 `--message-clicks` 输入预算，并用 `--story-choice` 指定进入回想后出现的剧情选择。未消费的回想选择会报告 `memory_story_choices_not_consumed`。报告记录已消费事件和剩余预算，这些构造输入不代表真实鼠标命中或原版画面等价。

对恢复状态下的音乐页面，可显式组合 `--title-menu-target sound --inspect-unrendered-bars` 进行无界面诊断；该模式禁止研究写档。配合静音音频观察与构造事件可检查音轨定位，滑条绘制、指针输入和按钮文字布局仍在报告中标为 `unsupported`。

在上述研究范围内，`--subsequent-bar-axis SeekBar:300:nearestEven` 可将明确给定的轴坐标按当前滑条及轨道尺寸换算为构造事件；可选舍入值为 `nearestEven`、`towardZero`、`down`、`up`。这是假定零宽滑块且不做鼠标命中测试的诊断输入，不能与 `--subsequent-bar` 同时使用。

也可用 `--subsequent-bar-point 名称:点X:点Y:X0:Y0:X1:Y1:X2:Y2:X3:Y3:舍入` 提供四边形，先执行本地命中候选再构造事件。顶点顺序影响判断；所给区域是调用者的假设，不是由游戏对象自动生成的真实命中区域。

`--subsequent-bar-resource-point 名称:点X:点Y:舍入` 可对受限资源从多个动作的时间 0 生成一致的区域候选；该路径假定单位父变换和候选轨道处于活动状态，尚不代表原版真实命中区域。

研究槽位导出时可额外指定 `--research-message-template 路径`，对当前消息主缓冲进行独立模板写入与回读检查；消息显式设置 `kwl` 时，还会在正文写入后的副本中检查布局字符串、相关开关以及已知的文本框和边距。检查仅在内存中进行，不生成或替代完整消息对象，也不会解除其他写档限制。

同一研究入口的 `--research-image-template 路径` 可检查受限静态图像位置与缩放的模板写入、回读；不覆盖图片资源、动画或其余对象状态。

构造滑条事件后，可用 `--research-bar-visual-ticks 50` 显式推进本地视觉时钟并采样过渡；允许 0–5000。此数值由调用方提供，不能视为原版帧调度或与音轨同步的证据。

构造滑条事件时，可用 `--research-bar-object-updates 0..4` 指定在回调前对该事件标记执行的模拟对象更新次数；此选项只模拟标记递减，不推进其他控件状态或模拟真实帧调度。

CG 查看器中的独立 Theora 资源可用 `--research-video-image-dimensions` 在只读命令行回放中尝试使用视频头尺寸响应图像尺寸查询。该模式禁止研究写档及场景预览，回执标记 `inferred`；它不证明原版视频表面尺寸、画面或播放等价。默认模式仍在此查询处明确停止。

已核对的同组脚本或文本表候选可重复使用 `--select-source data8.pack/相对路径` 提前固定，避免逐个遇到歧义时反复重跑整条路线。工具核对来源组、清单、文件摘要、数量和重复项；预选仍是实验选择，不能证明原版包优先级。

直接调用 `mangekyou-script` 回放单个脚本时，可在 `--scene-preview-background` 之外加上 `--scene-preview-png`，将合成画面写到标准输出。JSON 报告作为标准错误的最后一行输出。请将两路输出分别重定向到 `private/` 下的新文件。即使预览报告有遗漏，仍可检查已合成的部分，退出码以报告状态为准。

只读场景研究可在启用消息回调派发时追加 `--research-stop-at-ruby`，在可见消息首次出现注音后暂停并生成预览；报告中的 `replayBudget.researchRubyStopReached` 区分是否命中。注音与换行仍是未完成的候选，命中本身不代表原版排版等价。

特定剧情过场的研究预览可同时提供 `--headless-movie-tools` 和 `--scene-preview-cutin-ticks 毫秒`，从已核对的 30 秒内嵌视频取一帧合成；取样范围为 0–29999 毫秒，按 24 fps 向下选择帧。取样时刻是显式研究输入，并非实际播放时钟。该候选不满足严格预览验收，不能用于导出场景缩略图。

命令行场景预览另可显式启用 `--scene-preview-video-frames`，为已识别的独立 Theora 图像按本地动作时钟取帧；需要同时提供 `--headless-movie-tools` 和场景背景。此候选仅支持受限的 30 fps、1–10 秒视频，视频与原版时钟的对应尚未验证；含候选帧的读档场景不被视为完整，也不能用于导出场景缩略图。

可选 `--scene-preview-canvas 1280x720` 指定预览画布尺寸；背景图仅作为变化像素的比较基准，不足的部分填黑，超出的部分裁切，实际合成从黑色画布开始。每边最多 4096 像素、总计最多 4194304 像素；报告包含画布宽高。指定尺寸不代表已验证原版分辨率或画面等价。

旧回放的图像配方可通过 `tools/merge_replay_receipts.py --refresh-recipe SHA256` 从供体回放刷新。 仅更新指定配方并保留基础回放的脚本、资源清单和选项时，同时传入 `--recipe-only`。该选项要求成员范围、摘要、格式及已记录的槽号保持一致，允许补齐旧配方缺失的槽号，并将结果写入新的私有目录。 如果旧回放的读档菜单报告 `unsupported_two_texture_key`，先核对供体的缩略图配方是否包含新版探针生成的双纹理参数。用实际 `thumimage.b` 的 SHA-256 指定刷新目标。已验证刷新后的配方能在原生菜单中合成测试槽缩略图并进入续播。

### 历史开发记录


目标是将《美少女万華鏡 -罪と罰の少女-》移植到 Apple Silicon。P0 与多轮 P1 已建立资源/脚本的可追溯证据；用户随后明确授权完整应用开发。现已构建 ARM64 原生应用，支持只读导入、包尾检查和有限图片预览，**整作可玩性尚未实现**。以下 P1 说明按当时范围保留；支持状态以实际测试为准。

原生开发版：`python3 tools/build_native.py` 后打开 `build/Mangekyou.app`。运行此应用无需 Python、Java 或 Wine，也不包含商业资源。13 项 Swift 自建测试通过；真实目录清单及 10 个图片副本已通过原生核验。[开发版范围与复现](docs/31-native-app-foundation.md) · [机器状态](reports/p1/native-app-foundation.json)。

**开发版 0.2.0** 新增实验性脚本核心和界面检查入口。379 份文本的原生解码、scalar 字节跨度和字段指纹与现有模型一致；真实启动副本可处理一段声明/计算/分支及同文件调用，随后在未支持的双参数调用处停止。38 项 Swift 测试通过；仍不能开始完整游戏。[脚本核心、停止证据与复现](docs/32-native-script-core.md) · [机器报告](reports/p1/native-script-report.json)。

**开发版 0.3.0（历史）** 接通显式脚本目录表、跨文件调用/返回及版本选择。默认保留不同版本的歧义；明确选定副本后，真实启动片段可进入另一文件，再停在未实现的 `table` 声明。48 项原生测试通过；仍不能开始完整游戏。[文件绑定、版本选择与复现](docs/33-module-binding-and-variant-selection.md) · [机器报告](reports/p1/module-execution-report.json)。

**开发版 0.4.0（历史）** 接入有界的字符串变量、表对象、作用域、配置载入和查询。明确选定脚本与配置副本后，真实启动片段从 25 条推进至 49 条记录，载入 68 个条目并执行一次查询；随后在未支持的变量下标表达式处停止。60 项 Swift 自建测试通过；原引擎等价性仍为 `not_tested`，此次独立界面重放因自动化连接超时未完成。[范围、停止证据与复现](docs/37-native-table-core.md) · [执行报告](reports/p1/table-execution-report.json) · [应用核验](reports/p1/native-app-round26.json)。

**开发版 0.5.0（历史）** 接入有界的一维整数/字符串数组、整项读写和尺寸限制。真实启动片段可完成两次表载入、21 次查询并返回调用者；明确选择下一个模块后处理 260 条记录，再停在未支持的 `list` 声明。74 项 Swift 自建测试通过；多维数组、对象列表、完整游戏和原引擎等价性仍未实现或未验证。[证据、限制与复现](docs/38-native-array-core.md) · [执行报告](reports/p1/index-execution-report.json)。

**当前开发版 0.6.0** 接入独立的字符串列表、变量类别检查和有证据支持的当前脚本目录资源候选。明确选择副本后，真实启动片段处理 715 条记录，保留 76 行列表文本、完成 27 次变量检查及共 48 次查询，再停在未支持的三参数 `for`。85 项 Swift 自建测试通过。列表中的非 ASCII 名称保留为未知比较；查询若需要经过它会停止，没有静默跳过。[证据、限制与复现](docs/39-native-list-and-exists-core.md) · [执行报告](reports/p1/list-execution-report.json)。仍不能完整游玩。

**P1 第二十三轮静态研究**补证表对象、文本载入和结果写入：主调查与辅助函数调查合计 41 项独立静态观察、23 项指定指令事实及 7 个有界窗口；5 个默认函数识别缺口仍明确保留。两份配置脚本关联到 4 份文本副本，42 处查询形成 84 条有条件的版本关联，其中 80 条有行位置候选、4 条未能匹配，均未执行原引擎查询。[证据、限制与复现](docs/34-table-text-and-query-evidence.md) · [机器报告](reports/p1/table-analysis-report.json)。

**P1 第二十四轮静态研究**继续核对编码、区域比较和对象初始标志：51 项独立观察、25 项指定指令事实及 3 个有界窗口。379 份文本中，125 份无 BOM 数据在 CP932/CP936 下都能严格解码，其中 54 份得到不同内容；原程序的所选缺省路径传代码页 0，并用用户区域设置比较名称。19 项新增自建测试覆盖歧义、来源字节、构造参数顺序和异常输入；没有增加应用支持范围。[证据、订正与复现](docs/35-encoding-locale-and-initial-flags.md) · [机器报告](reports/p1/encoding-audit-report.json)。

**P1 第二十五轮资源读取验证**实际构建固定 GPL Rust 归档库和研究适配器：ARM64 上 9 个游戏包的 10,940 个条目名称与 P0 一致，410 个既有受限样本的解码 SHA-256 全部一致，未保存新的商业资源副本。这提供了许可证声明明确的候选后端；内部 BPE 分配上限、完整输入安全与正式分发方案仍未解决，也没有接入应用。[范围、限制与复现](docs/36-gpl-archive-reader-crosscheck.md) · [机器报告](reports/p1/gpl-archive-report.json)。

2026-11-06 已完成真实目录的静态调查：10 个 FilePackVer3.1 索引共 10,947 项（其中游戏 9 包、10,940 项，另有卸载包 7 项）；受限解码 410 个资源，283 份 `.s` 可按原始字节位置分析。P0 静态调查通过；完整游戏兼容性仍为 `not_tested`。用户提供的目录包含汉化 EXE 和补丁，不视作经过认证的纯净发行版。

随后按用户授权完成 **P1 第一轮静态基础**：379 份文本的字节覆盖、行内候选命令、跨包差异、符号与资源候选图，以及 ABMP12 内部验证。P1 整体尚未完成，尚不具备进入完整运行时开发的条件。[本轮说明与复现](docs/07-p1-static-foundation.md) · [下一轮研究入口](docs/11-p1-next-steps.md) · [机器状态](reports/p1/readiness.json)。

2026-11-07 继续完成 **P1 第二轮取证**：2,639 个候选结构块、11 组补丁差异的字节定位、300 个存档边界候选，以及通过 REA/Ghidra 对主程序的 17 项选定静态观察。已验证工具在 Apple Silicon 上可用；全作原生移植仍未完成。[脚本与存档边界](docs/12-p1-semantic-evidence.md) · [原生取证和复现](docs/13-native-static-evidence.md) · [第二轮机器状态](reports/p1/round2-readiness.json)。

**P1 第三轮**进一步找到包槽位倒序查询和一处不限定槽位的脚本读取，形成保留所有版本的 202 个逻辑路径条件视图；还定位了 Ghidra 漏掉的两个清理后函数尾部。实际运行版本和完整执行语义继续保留未知。[证据、缺口与从零复现](docs/14-precedence-and-function-tails.md) · [第三轮机器状态](reports/p1/round3-readiness.json)。

**P1 第四轮**用自建正反例验证了临时数据库中的正常流模型，再对两个真实函数恢复了受约束的值返回视图；模型整体保留 `inferred`。新的只读编号探针覆盖 40,824 条命令记录、245 种命令名，尚不执行命令。[模型边界、失败记录与复现](docs/15-normal-flow-models-and-command-ids.md) · [第四轮检查](reports/p1/round4-readiness.json)。

**P1 第五轮**新增表达式结构解析器：8,130 个候选字段中，8,126 个生成可追溯的候选 AST，4 个未支持项保留位置和原因；没有执行表达式或声称游戏兼容。[处理组、覆盖边界与复现](docs/16-expression-structure.md) · [第五轮检查](reports/p1/round5-readiness.json)。

**P1 第六轮**核对基本值解析的 14 项原生观察和 7 项指令事实，新增有边界限制的整数格式假设模型。补充 `$` 字面量结构识别后，8,128 个字段生成候选 AST；两处空 `cal` 字段仍明确未支持。SDKMAN Java 21 与当前 REA/Ghidra 连接均已实际验证。[证据范围、类型风险与复现](docs/17-scalar-formats-and-empty-fields.md) · [第六轮检查](reports/p1/round6-readiness.json)。

**P1 第七轮**补充赋值、变量查询、权限与下标路径的 31 项原生观察、14 项指定指令事实，并关联 5,088 处赋值和 407 处更新候选。成功赋值返回值、存储优先序和索引处理形成新的有依据假设；没有建立变量执行后端。[证据、Unknown 与复现](docs/18-assignment-storage-and-index-evidence.md) · [第七轮检查](reports/p1/round7-readiness.json)。

**P1 第八轮**补充更新时点与调用返回的 44 项原生观察、17 项指令事实；重新核对 4,261 个转移记录，为 407 处更新候选关联阶段假设。`ret` 的参数进入上下文目标路径，仍未执行验证。[阶段、参数槽与恢复边界](docs/19-update-phase-and-return-context.md) · [第八轮检查](reports/p1/round8-readiness.json)。

**P1 第九轮**从原程序类型元信息定位线程/例程/控制块的两层创建链，以及结果记录的声明布局。新增只读元信息探针，默认函数覆盖缺口、派生视图和逻辑值规则分别报告；没有实例化或执行游戏对象。[类型声明、创建链和逻辑边界](docs/20-rtti-context-layout-and-logical-rules.md) · [第九轮检查](reports/p1/round9-readiness.json)。

**P1 第十轮**读取 12 个控制块和 11 个例程状态的声明，核对选定函数的 21 处状态写入、10 项指令事实，以及 2,639 个候选块的词法关联；7 处 `dbrk` 明确未支持。命令门控和清理后返回形成受限模型，完整执行语义仍未验证。[状态、控制流边界与复现](docs/21-declared-states-and-control-flow.md) · [第十轮检查](reports/p1/round10-readiness.json)。

**P1 第十一轮**核对片段读取、正文前缀路径与 11 项例程状态分派，补充 28 项原生观察和 9 项指令事实。新增字节候选探针揭示默认分析覆盖缺口；`dbrk` 获得局部证据，全局效果继续未知。错误起点和跳表线性解码的历史问题均保留。[读取、等待入口和证据限制](docs/22-reader-state-dispatch-and-coverage.md) · [第十一轮检查](reports/p1/round11-readiness.json)。

**P1 第十二轮**找到读取器的前缀字段和替换记录声明，核对 et/nt 的条件赋值路径、五类替换分支及八处脱敏脚本候选。新增 29 项原生观察、12 项指令事实，纠正“空伪代码即无操作”和“无矛盾即全覆盖”的误判风险；仍未执行替换或正文播放。[前缀、替换顺序与复现](docs/23-prefix-configuration-and-replacement-evidence.md) · [第十二轮检查](reports/p1/round12-readiness.json)。

**P1 第十三轮**补查 subp 的尾部字段打包和内建 rep 的条件绑定，建立前缀到标签的脱敏候选图。词法工具新增显式分组模式；379 份实际副本、40,824 条命令的新旧字段跨度一致，分组差异仅由合成样例覆盖。新增 30 项原生观察、14 项指令事实，完整执行仍未知。[调用变体、字段模式与证据限制](docs/24-subp-field-grouping-and-prefix-bindings.md) · [第十三轮检查](reports/p1/round13-readiness.json)。

**P1 第十四轮**追踪四个对象事件的声明和静态绑定，确认创建、读取两个桥接均调用同一工厂；默认交叉引用漏掉的一处调用由原始指令补证。核对参数转换标签四的回退路径，新增 22 项独立复现观察、11 项指令事实及 9 项合成测试。五处默认函数缺口和未解释的 ABI 继续保留；尚未实现参数执行或游戏运行时。[事件、回退与复现](docs/25-object-events-and-argument-fallback.md) · [第十四轮检查](reports/p1/round14-readiness.json)。

**P1 第十五轮**核对五种正文替换路径、正则相关记录声明、选项位和不同的大小写比较。新增 52 项独立复现观察、12 项指令事实，审计 563 处 `a` 拼写候选；其中仅六处有同行 `rep` 提示，而且均省略模式字段，不能认定默认模式或实际执行。完整正则兼容、异常恢复与对象绑定仍未知。[替换分支、证据边界与复现](docs/26-replacement-routes-and-case-rules.md) · [第十五轮检查](reports/p1/round15-readiness.json)。

**P1 第十六轮**沿字段补齐、取值和登记路径，补证省略模式条件下的整数零结果：通用解析入口要求至少九个字段，缺项以空指针追加，空指针计算结果为 `vtInteger/0`。六处真实词法候选均获得可追溯的条件投影，实际对象绑定和执行仍未验证。新增 26 项独立复现观察、12 项指令事实，并修正反汇编窗口越界识别。[缺项值、返回记录与复现](docs/27-omitted-mode-and-null-value-path.md) · [第十六轮检查](reports/p1/round16-readiness.json)。

**P1 第十七轮**追踪 `scp` 的作用域写入、对象查询与后续分派：处理成功仍继续下一槽，空槽停止，名称比较依赖条件标志。新增 24 项独立复现观察、16 项指令事实；审计 6,014 个选择候选及 5,793 条同行关系，实际绑定仍未验证。[作用域、名称比较与复现](docs/28-object-scope-and-registry-flags.md) · [第十七轮检查](reports/p1/round17-readiness.json)。

**P1 第十八轮**补接新例程构造中的 Scope 清理和返回时的例程选择：在已核对的类型绑定下，新例程初始化清空自身作用域；非局部返回从首个被移除例程取恢复数据，再保留目标例程。新增 33 项独立复现观察、12 项指令事实，为 3,720 个源码调用/返回候选标注条件契约；未执行脚本。[帧初始化、返回与复现](docs/29-frame-scope-initialization-and-return.md) · [第十八轮检查](reports/p1/round18-readiness.json)。

## 阅读结果

**P1 第十九轮**核验六份已有 DPNG、45 个非空拼片，并以 22 项独立原生观察和 11 项指令事实补接透明行填充路径。两份样本存在透明 RGB 差异，实际重叠和显示等价继续未知。[像素、原生写入与复现](docs/30-dpng-pixels-and-fill-evidence.md) · [第十九轮检查](reports/p1/round19-readiness.json)。

- [调查范围与证据规则](docs/00-project-scope.md)
- [真实目录与版本线索](docs/01-game-inventory.md)
- [FilePack 调查及工具复用边界](docs/02-filepack-analysis.md)
- [实际资源格式矩阵](docs/03-asset-format-matrix.md)
- [脚本结构、字节位置与工具不足](docs/04-script-analysis.md)
- [主要兼容风险](docs/05-compatibility-risks.md)
- [P1 范围及路线比较](docs/06-p1-recommendation.md)
- [机器报告](reports/p0/acceptance.json)、[第三方说明](THIRD_PARTY.md)
- P1：[跨包差异](docs/08-overlay-analysis.md) · [词法与符号](docs/09-script-structure-p1.md) · [ABMP 内部](docs/10-abmp-analysis-p1.md)

## 重复运行

核心扫描只需 Python 3.9+，不自动查找游戏、不联网、不执行输入文件：

```sh
python3 -m unittest discover -s tests -v
python3 tools/mangekyou_p0.py --game-dir "$GAME_DIR" --output private/real-p0
```

`GAME_DIR` 由使用者设定为自己的合法游戏目录；代码不包含本机游戏绝对路径。不指定输入会生成明确 `not_tested` 的无数据报告。

完整研究验证需要 Python 3.10+ 和 Pillow。本机使用 Python 3.13.15、Pillow 12.0.0：

```sh
uv venv --python python3.13 .venv
uv pip install --python .venv/bin/python -r requirements-research.txt
python3 tools/fetch_sources.py
.venv/bin/python tools/reproduce.py
```

上游源码按 [固定 commit 和 SHA-256 清单](docs/upstream-lock.json) 下载，仅取源码、构建清单和许可证；不整仓下载游戏附件。`reproduce.py` 生成无真实数据基线、源码检查、合成样本和自动化测试报告，会替换 `reports/p0/` 的真实摘要。使用真实数据时接着运行：

```sh
.venv/bin/python tools/mangekyou_p0.py \
  --game-dir "$GAME_DIR" --output private/real-p0 \
  --upstream-source .research/upstream/qlie-unpack
.venv/bin/python tools/sample_resources.py \
  --game-dir "$GAME_DIR" \
  --upstream-source .research/upstream/qlie-unpack \
  --archive-report private/real-p0/archive-report.json \
  --output private/real-assets --report private/real-p0/sample-report.json
.venv/bin/python tools/mangekyou_p0.py \
  --game-dir "$GAME_DIR" --assets-dir private/real-assets \
  --upstream-source .research/upstream/qlie-unpack \
  --probe-media --output private/real-p0
.venv/bin/python tools/summarize_real.py
```

文本提取交叉验证另需 Rust 2024 工具链，按固定源码原样构建，不使用游戏 EXE。构建结果只覆盖 QLIE 文本功能：

```sh
.venv/bin/python tools/build_msg_tool.py
.venv/bin/python tools/crosscheck_msg.py \
  --binary .research/msg-target/release/msg_tool
.venv/bin/python tools/summarize_real.py
```

`--probe-media` 可选，需要本机 `ffprobe`。报告只生成到独立输出树；拒绝输入/输出重叠及符号链接。退出码 2 表示错误或输入被拒绝；未知格式即使没有异常也会在报告中标记 `unsupported`，不能据退出码推断全部兼容。

抽样工具只解码全部 `.s`/`.txt` 和每包每种候选扩展名至多两个样本；单项 16 MiB、每包累计 128 MiB，不导出密钥，不覆盖不同内容的旧副本，不处理安装/卸载程序。样本选择有偏，不能外推至所有 CG、音频或演出。

## 报告与数据隔离

`verified` 必须附证据范围；`inferred` 是推断；`unsupported` 是当前工具不支持或明确失败；`not_tested` 是未验证。源码声称、上游测试、本地合成样本、真实样本分开列示。

`private/` 存放本机副本、完整脱敏 IR 和详细索引，`.research/` 存放源码缓存与构建产物，均被 Git 忽略。`reports/p0/` 只保留相对路径、摘要、统计、指令名称和不含台词的原始字节引用。商业资源、剧本正文、密钥、CG、音频和 EXE/DLL 不随项目分发。

P0 不运行游戏，未测试分支执行、存档、动画时间线或整作可玩性。下一阶段建议先确认包覆盖顺序与脚本语义，再决定原生运行时的语言和架构。

已有 P0 研究副本时，可独立重现 P1；该命令保持 `reports/p0/` 不变：

```sh
.venv/bin/python tools/reproduce_p1.py --game-dir "$GAME_DIR"
```

第二轮使用已有 P1 研究副本；完整步骤和本机原生工具要求见第 13 篇。`GAME_EXE_REL` 为主程序候选的相对路径，只读分析，不执行：

```sh
.venv/bin/python tools/reproduce_p1_round2.py \
  --game-dir "$GAME_DIR" --exe "$GAME_EXE_REL"
```

上游单独复验默认写入 `private/upstream-verification.json`，保留历史 P0 报告：

```sh
.venv/bin/python tools/verify_upstream.py
```

命令行 v7 接入内建 `cfg` 的两条整数配置写入。原程序构造函数 `0x68db84` 写入对象类型 24，分派入口 `0x6ab090` 进入配置处理器。`vtv` 和 `vtm` 的写入位置分别见 `0x6c3864` 与 `0x6c3943`。命令行保留配置状态，原版宿主回调效果仍待验证。两套真实启动路径均处理 939 条记录，在 `comb` 停止。详见 [data7](reports/p1/cli-progress-round30-data7.json) 和 [data8](reports/p1/cli-progress-round30-data8.json)。

命令行 v8 接入 `comb` 的表合并分支。原程序 `0x6cde17` 的累计比较对应该命令，`0x6ce208` 核对源对象类型，`0x56372a` 跳过空值，`0x56374d` 写入目标表。当前模型合并已载入的 ASCII 键表，保留两份加载来源，Windows 区域比较仍待验证。两套启动路径均处理 943 条记录，随后在读取 `ParamInt[0]` 的条件处停止。[data7](reports/p1/cli-progress-round31-data7.json) · [data8](reports/p1/cli-progress-round31-data8.json)

命令行 v9 接入 `sub` 的整数参数。原程序 `0x6b7838` 从参数区读取字段，`0x6b794c` 将槽位限制为 16 个。当前以调用帧保存整数参数，缺省槽位取零，带参数且文件字段为空时选择当前脚本。默认值和空字段映射属于静态推断，字符串参数和原版等价性仍待验证。两套实际启动路径均执行到第 953 条记录，停在 `?fn`。[data7](reports/p1/cli-progress-round32-data7.json) · [data8](reports/p1/cli-progress-round32-data8.json)

命令行 v10 可用 `--game-dir` 只读载入 `GameData/System/config.txt`，为 `cfg` 的字体查询提供初始配置。原程序 `0x6c3af2` 至 `0x6c3b15` 读取八个名称并写入字符串结果槽。字号以外的字体属性查询也已接入，实际启动只走到名称查询，其余查询和 Windows 字体显示效果仍待验证。两套实际启动路径均推进至 955 条记录并停在 `rep`。[data7](reports/p1/cli-progress-round33-data7.json) · [data8](reports/p1/cli-progress-round33-data8.json)

命令行 v11 接入三字符串参数的 `rep`。原程序在 `0x6afa4b` 调用字面替换，在 `0x6afa67` 清理结果绑定，再写 `ResultStr[0]`。当前以 ASCII 大小写匹配为限，依据 `0x4e0900` 至 `0x4e0934` 选择替换首处或全部。两套启动路径均执行替换和后续字体属性查询，推进至 985 条记录，停在 `?v` 的字符串表达式。[data7](reports/p1/cli-progress-round34-data7.json) · [data8](reports/p1/cli-progress-round34-data8.json)

命令行 v12 支持字符串拼接及空串和 ASCII 字符串的相等比较。原程序的同类型非整数加法路径在 `0x69a9ac` 调用字符串助手，比较路径在 `0x69aca6` 至 `0x69acbe` 折叠大小写后比较。循环内的 `cnt` 按候选控制结构关联到最近的循环，实际启动路径尚未执行该跳转。两套真实启动路径均处理 1006 条记录。[data7](reports/p1/cli-progress-round35-data7.json) · [data8](reports/p1/cli-progress-round35-data8.json)

命令行 v13 将 `fn2`、`faa2`、`fst2`、`fsc2` 写入同一字体状态供后续查询使用。原程序对应写入见 `0x6c3ac4`、`0x6c3cbb`、`0x6c3df8`、`0x6c3f3a`，颜色写入保留低 24 位。宿主渲染与回调仍待接入。两套真实启动路径均推进至 1030 条记录，停在表查询的十六进制缺省值。[data7](reports/p1/cli-progress-round36-data7.json) · [data8](reports/p1/cli-progress-round36-data8.json)

命令行 v14 支持 `?v` 的十六进制缺省值。依据 `0x69b04c` 至 `0x69b065` 的字面量描述符路径与 `0x6cdf11` 至 `0x6cdf1d` 的两个字段读取，当前保留十六进制拼写并单独解析整数。字符串比较按 `0x41493c` 的 ASCII 折叠路径处理，保留其他字符。两套实际启动路径均处理 1276 条记录。[data7](reports/p1/cli-progress-round37-data7.json) · [data8](reports/p1/cli-progress-round37-data8.json)

命令行 v15 接入新会话的 `dat,g` 存档查询。原程序在 `0x68c30f` 设置对象类型 2，`0x6b41ce` 先检查 `SaveData` 内的文件，`0x6b420b` 再确认可读取，最后在 `0x6b423d` 写入整数结果。移植端的新会话存档命名空间为空，原存档导入和恢复仍待实现。两套启动路径均处理 1290 条记录。[data7](reports/p1/cli-progress-round38-data7.json) · [data8](reports/p1/cli-progress-round38-data8.json)

命令行 v16 接入 `skey` 的清空和两参数绑定。原程序 `0x68dd27` 设置对象类型 27，`0x6ab1da` 分派至处理器，`0x6cafee` 清空集合，`0x6cb0d3` 写入绑定。两套启动路径各登记四条绑定并推进至 1302 条记录，随后停在选择 `sys` 的指令。宿主输入和事件触发仍待接入。[data7](reports/p1/cli-progress-round39-data7.json) · [data8](reports/p1/cli-progress-round39-data8.json)

命令行 v17 接入 `sys,lk` 的掩码写入。`0x6bd2ee` 将 `_lkScreen` 初始化为 1，`0x6b256e` 写入显式掩码，`0x6b2539` 处理无参数形式。两套实际路径均执行锁定设置并推进至 1308 条记录，停在 `img` 声明。输入消费、图像资源对象和画面输出仍待接入。[data7](reports/p1/cli-progress-round40-data7.json) · [data8](reports/p1/cli-progress-round40-data8.json)

警告画面的 `caution.b` 已从 `GameData/data7.pack` 单独取样，资源摘要为 `21aecc464c87bd4fd1f4f8cfbe6d0efa3735e58ec447513ca22f5857192bf18e`。容器为 ABMP12，其中一个 PNG 已通过像素解码，另一个成员的内容类型仍未知。复现时用 `tools/sample_resources.py --archive GameData/data7.pack --member script/caution/caution.b`，并传入原目录、锁定上游源码与 private 输出目录，再用 `tools/abmp_probe.py --input` 检查该副本。脚本内的 `img` 对象仍待接入。

命令行 v18 接入 `img` 对象声明和初始化。`0x68be5b` 写入对象类型 6，`0x6aafe0` 分派图像对象，`0x6c6956` 进入初始化虚函数，`0x6c7093` 进入资源加载。data8 启动路径处理 1314 条记录，停在 `l`。脚本目录表尚未登记单独取样的 ABMP，运行时也尚未接入容器解码。[data8](reports/p1/cli-progress-round41-data8.json)

命令行 v19 接通警告画面的图像加载。使用 `tools/advance_cli.py --image-source data7.pack/script/caution/caution.b --image-audit "$AUDIT"`，另传入原目录、资源副本、实验包组和报告轮次。将上一段取样命令的输出指向本次 `--assets-dir`，将 ABMP 探测的 JSON 输出作为 `$AUDIT`。运行时核对容器和成员摘要，使用原生解码器加载已验证的未压缩 PNG，并保存图像尺寸与资源来源。该路径依赖单成员审计结果，容器的未知成员和通用 ABMP 演出仍待支持。两套路径均推进至 1316 条记录，停在图像定位指令 `p`。[data7](reports/p1/cli-progress-round42-data7.json) · [data8](reports/p1/cli-progress-round42-data8.json)

命令行 v20 保留已加载图像的 `p` 定位参数及 `m,0` 成员选择。原程序 `0x6c5a06` 将定位参数转给图像助手，`0x6c7b3d` 将整数索引交给图像选择助手。当前只支持已审计单图像成员，尚待核对定位细节及呈现行为。两套路径均推进至 1320 条记录。[data7](reports/p1/cli-progress-round43-data7.json) · [data8](reports/p1/cli-progress-round43-data8.json)

命令行 v21 接通已选中图像成员的零参数 `e`。原程序 `0x6c7a95` 调用 `TImageLib` 的虚表槽 `+0x24`，实际入口 `0x5aca20` 将两个状态字节置一，另有条件调用图像选择助手。命令行保留启用状态。两套启动路径均处理 1322 条记录，停在 `zero`，其作用仍待确认。[data7](reports/p1/cli-progress-round44-data7.json) · [data8](reports/p1/cli-progress-round44-data8.json)

命令行 v22 接入 `zero` 的直接状态写入。分派链 `0x6af842` 至 `0x6af852` 解析命令，`0x6afbc8` 调用 `0x6bbb08`，将引擎字段 `+0x98` 写为 2。字段的宿主消费和呈现效果仍未知。两套路径均处理 1326 条记录，停在 `clk`。[data7](reports/p1/cli-progress-round45-data7.json) · [data8](reports/p1/cli-progress-round45-data8.json)

命令行 v23 在 `clk` 进入等待。原程序 `0x6b042b` 初始化 `ResultClkInt`，`0x6b043e` 设置等待状态 4，`0x6b04bc` 写入计数，`0x6bb01e` 检查计数是否归零。核心可由宿主传入计数增量来恢复有限等待，命令行此次验证只运行到等待入口，实际时钟和点击尚未接通。[data7](reports/p1/cli-progress-round46-data7.json) · [data8](reports/p1/cli-progress-round46-data8.json)

命令行增加显式 `--click-ticks`，用有限的宿主计数预算推进 `clk`。传入 10000 后，两套真实启动脚本均从等待恢复并推进至 1330 条记录，在选择 `eff` 时停止。此次使用显式计数，原版计数与墙钟的换算及点击事件仍待核对。[data7](reports/p1/cli-progress-round47-data7.json) · [data8](reports/p1/cli-progress-round47-data8.json)

命令行 v24 保留 `eff,c` 的黑色填充请求并支持删除已声明的全局图像。原程序 `0x6b610a` 进入效果助手，`0x693755` 压入黑色值，`0x6b0b7f` 将删除名称交给绑定助手。命令行只验证场景状态，宿主呈现和效果完成时机仍待接入。两套路径均推进至 1340 条记录，停在 `fdi`。[data7](reports/p1/cli-progress-round48-data7.json) · [data8](reports/p1/cli-progress-round48-data8.json)

命令行 v25 保存 `eff,fdi` 的模式零淡入请求。原程序 `0x6b5a2e` 分派到 `0x6b5b94`，`0x6b5bdd` 取得第二参数，`0x6b5c9b` 将其交给效果助手。以 10500 个显式等待计数，两套路径均从警告模块返回，推进至 1369 条记录。当前验证的是请求和脚本控制流，淡入渲染仍待接入。[data7](reports/p1/cli-progress-round49-data7.json) · [data8](reports/p1/cli-progress-round49-data8.json)

命令行 v26 支持声明和初始化 `theora` 对象。原程序 `0x68ea46` 设置类型 34，`0x6ab0fe` 分派至 `0x6b8330`，`0x6b8908` 调用初始化助手。两套真实路径均推进至 1375 条记录，停在视频加载。现有本地 `omegastar.ogv` 副本的 Ogg 容器包含 1280×720、24 fps 的 Theora 视频与 Vorbis 音频，视频约 7.04 秒。FFmpeg 已独立完整解码视频与音频到空输出，运行时媒体加载、时钟及呈现仍待接入。[data7](reports/p1/cli-progress-round50-data7.json) · [data8](reports/p1/cli-progress-round50-data8.json)

命令行 v27 支持 `theora,l` 的资源绑定。`0x6b851f` 是原引擎加载分支，`0x6b85c3` 调用路径助手，`0x6b85d6` 读取第二参数。复现时在既有命令追加 `--movie-source data7.pack/script/makerlogo/omegastar.ogv`。当前读取固定摘要的副本并核对 Ogg Theora 标识。两套路径均推进至 1377 条记录，停在 `pp`，媒体解码尚未接到运行时。[data7](reports/p1/cli-progress-round51-data7.json) · [data8](reports/p1/cli-progress-round51-data8.json)

命令行 v28 接入视频 `pp` 定位参数与 `e` 启用。`0x6b843a` 分派至三参数路径，`0x6b881b` 传给定位助手。`0x6b8767` 调用启用助手，`0x6839a0` 设置状态字节。两套路径均推进至 1381 条记录，在播放指令 `p` 明确等待媒体宿主实现。[data7](reports/p1/cli-progress-round52-data7.json) · [data8](reports/p1/cli-progress-round52-data8.json)

命令行 v29 的视频 `p` 将资源引用与定位交给宿主并进入 `waitingForMedia`。原程序 `0x6b8704` 调用播放状态助手，`0x6b897b` 至 `0x6b8988` 将时长字段写入整数结果。原版 DLL 的总时长导出在 `0x10003900` 读取字段 `+0xd8`，候选写入路径 `0x10001bfb` 乘以 1000 后在 `0x10001c06` 存储。当前宿主接口接受整数计数，尚未实际调用恢复接口或执行 `?tt`。两套路径均在第 1381 条记录进入媒体等待。[data7](reports/p1/cli-progress-round53-data7.json) · [data8](reports/p1/cli-progress-round53-data8.json)

命令行现可通过 `--headless-movie-tools` 指定本地 FFmpeg 工具目录。视频请求触发完整音视频解码到空输出，时长由 FFprobe 提供并转换成整数毫秒。通过已核对摘要的只读文件描述符传递媒体，进程限时且禁用其他输入协议。以 18000 个显式等待计数，两套启动路径均完成视频时长查询、等待和释放，推进至 2271 条记录。实际音画输出和同步仍待接入。[data7](reports/p1/cli-progress-round54-data7.json) · [data8](reports/p1/cli-progress-round54-data8.json)

确认读档槽位并配置本地电影解码工具后，可加 `--click-after-saved-movie` 向隔离回放中电影解码后的首个点击等待发送一次模拟点击。 可用 `--saved-replay-step-limit N` 调整隔离回放的步数预算，默认 512，最大 262144。

长读档回放可加 `--compact-saved-replay`，仅输出末尾 256 步及省略步数，仍保留停点和合成诊断。

命令行标题读档验证可额外加 `--adopt-experimental-save-candidate`。确认槽位后，已构建的恢复候选会替换当前命令行会话，并由正常的脚本和媒体循环继续执行。音频恢复有缺口、缺少所需媒体宿主或首次续跑失败时，命令行回滚并尝试恢复标题，保留原始错误；如恢复标题也失败，则另行报告恢复错误并保留原等待会话。可同时指定 `--start-after-save-recovery`，在成功回退标题后继续开始新游戏。结果见 `loadTask.experimentalAdoption`、`loadTask.experimentalAdoptionIssue` 和 `loadTask.experimentalAdoptionAudioGaps`。使用已有研究样本和 `--maximum-steps 2000000`，实测执行 159529 步后抵达 `waitingForEvent`。该验证覆盖命令行执行交接，原版画面和音轨恢复等价性仍待核对。

同一研究槽位可用播放器启动探针 `--check-experimental-save-adoption=SaveData0.svd` 验证。提供原有 `--assets-dir`、`--replay-dir`、`--game-dir` 和私有 `--save-dir` 参数。样本从标题确认读档后，日志出现 `player_experimental_save_adopted=1`，并在恢复实例执行 261 步时启动片尾影片。片尾播放 91.163 秒后，探针通过常规输入路径送入一次点击。脚本由第 159397 步推进至第 163877 步，再次进入 `waitingForEvent`，当时播放器报告 16 个图层。播放器常规读档确认也使用同一恢复流程。若无法建立恢复候选、音频状态不受支持或待播放音频预检失败，播放器会保留读档前的会话。启动探针用于自动点击和记录结果。 剧情内入口可改用 `--check-dialogue-save-adoption=SaveData0.svd`。私有组合样本从对白界面确认读档后清理了两条旧音轨，从 1.25 秒处启动存档音轨，并进入片尾影片。 越界音轨位置的私有样本可用 `--check-dialogue-save-rejection=SaveData0.svd` 验证。播放器回到同一对白，保留两条循环音轨，下一次点击继续执行。

实验交接会把有精确毫秒位置的流式音轨放入对应声道。原版 `0x5a056f–0x5a057f → 0x5a0db4 → 0x59d014` 在模式值至少为 2 时请求播放，重复次数来自记录偏移 `0x27`。私有组合样本预载并启动了 1 条音轨，播放器报告 `actual_seconds=1.25 playing=true`，随后启动片尾影片。该样本仍报告画面预览不完整，完整的原版混音和淡入参数仍待核对。

初始图层的私有组合验证使用同一存档布局。普通 PNG 能在脚本执行前绘制为半透明图层。改用需要动作状态的 `button_delete.b` 后，预检以 `saved_initial_layer_unavailable` 报出具体资源，标题恢复到 `waitingForEvent`。

直接音效使用独立声道。模式 2 按 `0x59fc60` 检查解码缓冲区是否大于 `0xd7550` 字节。探针以 44.1 kHz、单声道、16 位 PCM 检查前 11 秒。私有组合样本的短音效为 199050 字节，未启动。长音乐样本达到 970200 字节，原生播放器确认启动一次。模式 3 的私有组合样本已验证循环启动。



命令行 v30 接入带显式文件和标签的 `go`。原程序 `0x6b753b` 调用脚本切换助手，成功后 `0x6b754f` 和 `0x6b7564` 清理例程和控制栈。当前保留根帧与全局状态，目标文件仍按摘要和显式选择加载，原引擎的路径寄存器更新尚待接入。两套路径均进入标题模块并推进至 2389 条记录。[data7](reports/p1/cli-progress-round55-data7.json) · [data8](reports/p1/cli-progress-round55-data8.json)

命令行 v31 支持以字符串表达式构造调用标签。原程序 `0x6b76d3` 调用目标处理助手，`0x6c07a6` 区分现成标签与后续处理路径。计算结果仍须解析为当前目标脚本中的唯一标签。两套路径均推进至 2404 条记录。[data7](reports/p1/cli-progress-round56-data7.json) · [data8](reports/p1/cli-progress-round56-data8.json)

标题布局验证可重复传入 `--image-source` 和一一对应的 `--image-audit`，普通 PNG 使用 `--plain-image-source`。本轮加入标题背景、光标和边框三个私有资源副本。命令行核对嵌套容器成员的边界和摘要，逐个解码经审计的未压缩 PNG。返回的尺寸是成员尺寸上限，原版布局、图层组合和动画仍待实现。data8 路径推进至 2420 条记录。[运行报告](reports/p1/cli-progress-round57-data8.json)

命令行 v32 支持已加载图像的零参数 `d`。原程序 `0x6c739c` 调用 `TImageLib` 虚表槽 `+0x28`，对应 `0x5ac9cc` 的禁用路径。两套标题布局均完成三份资源加载，关闭边框状态并返回调用者，在位置查询 `?p` 停止。[data7](reports/p1/cli-progress-round58-data7.json) · [data8](reports/p1/cli-progress-round58-data8.json)

命令行 v33 接入零锚点下的图像位置查询 `?p`。`0x5ac85f` 至 `0x5ac87a` 写入位置字段，`0x5ae371` 和 `0x5ae379` 初始化锚点为零，`0x6c5aa3` 至 `0x6c5ad7` 读取坐标和第三位置字段。两套路径均完成查询并推进至 2432 条记录。[data7](reports/p1/cli-progress-round59-data7.json) · [data8](reports/p1/cli-progress-round59-data8.json)

命令行 v34 绑定 `snd[0]` 并加载标题音频。`0x6bcb25` 注册声音对象，`0x68d03b` 写入类型 4，`0x6ab064` 分派声音命令，`0x6b52d0` 进入初始化助手。通过 `--audio-source` 加入单个只读副本，核心验证 Ogg Vorbis 标识和资源摘要。data8 路径推进至 2438 条记录，尚未进入音频播放。[运行报告](reports/p1/cli-progress-round60-data8.json)

命令行 v35 保存声音通道的 `vtn` 和 `v` 参数。原程序 `0x6b5589` 调用通道字段写入助手，`0x5a155a` 写入字段，`0x6b5353` 调用音量路径。data8 路径执行两次设置后推进至 2442 条记录，在声音 `p` 停止。此处仍落入现有图像分派的错误提示，声音播放后端尚待接入。[运行报告](reports/p1/cli-progress-round61-data8.json)

命令行 v36 将声音 `p,1` 交给本地媒体后端。后端核对资源摘要并完整解码音频至空输出，成功后恢复脚本。data8 路径推进至 2446 条记录，停在标题背景的 `e`，当前图像启用仍要求显式成员选择。音量混合、循环与实际输出仍待接入。[运行报告](reports/p1/cli-progress-round62-data8.json)

命令行 v37 允许启用已加载但未显式选成员的图像。原程序在 `0x5ad278` 保存自动启用目标，由 `0x5aca4e` 读取。当前记录启用请求，尚未解析多成员容器的自动演出目标。同轮接入 `sub` 的 `ParamStr` 和整数缓存，依据 `0x6b78f5` 起的双字段写入。data8 路径推进至 2462 条记录，停在对象数组声明。[运行报告](reports/p1/cli-progress-round63-data8.json)

命令行 v39 加载按钮容器。固定上游读取器对 `button.b` 在 16635 处报截断，研究适配层仅在剩余字节完全匹配连续空声音描述符时接管该分支，随后验证容器完整消费 16660 字节及三份 PNG。data8 启动执行按钮 `l` 后推进至 2472 条记录，停在图像绑定 `li`。[运行报告](reports/p1/cli-progress-round65-data8.json)

命令行 v40 通过 `li` 读取并解码按钮槽位 0 和 1 的外部图像。原程序的 `0x6c7153` 调用资源查找，`0x6c7163` 将图像写入指定槽位。data8 路径推进至 2476 条记录，停在声音绑定 `ls`。[运行报告](reports/p1/cli-progress-round66-data8.json)

命令行 v41 接入按钮 `ls`。原程序 `0x6c7290` 解析资源，`0x6c72a0` 调用绑定助手。相对路径在逻辑目录内消解，不能越过目录表根。data8 验证两个 WAVE 绑定后推进至 2480 条记录，停在按钮定位 `p`。[运行报告](reports/p1/cli-progress-round67-data8.json)

第 81 轮通过显式按钮索引重放标题选择。原程序的 `gbc` 在 `0x6ca40e` 进入结果助手，`0x6c9be5`、`0x6c9c04` 和 `0x6c9c27` 分别写入对象、整数和字符串结果。无界面宿主只接受已启用且未锁定的按钮，标签取自原剧本的 `us`。未设置的附加结果使用零值和空字符串，`play` 通过回调返回恢复等待中的脚本，这些是当前推断模型。data8 在 2900 步进入“开始游戏”分支，停于双参数声音 `v`。原版鼠标命中、附加结果和完整调度行为仍待验证。[运行报告](reports/p1/cli-progress-round81-data8.json)
