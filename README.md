# Project Mangekyou：第四作 Mac 原生播放器

本项目只针对第四作《美少女万華鏡 -罪と罰の少女-》，目标平台为 Apple Silicon Mac。当前播放器已覆盖常规剧情存档、读档、快速槽、选择前自动档、删除、退出保存，以及 Mac 专用脚本错误恢复存档。逐项证据见[功能里程碑](docs/40-feature-milestones.md)。

Windows 原版剧情存档导入不在当前范围。Mac 错误恢复扩展会将最后一个安全等待点写入 `ExceptionBackup.svd`；该行为不声称与原版调试回调等价。整作兼容、标题按钮动画和部分画布外演出仍未验证。

## 构建与启动

在 macOS 14 或更新版本构建 ARM64 应用：

```sh
python3 tools/build_native.py --configuration release
open build/Mangekyou.app
```

应用不包含商业游戏资源。首次试玩时，从「载入本地回放配置」选择本机资源副本、回放清单和原版游戏目录；可另选独立存档目录。原版目录只读。

也可直接启动应用产品：

```sh
swift run --package-path native -c release Mangekyou \
  --assets-dir "$MANGEKYOU_ASSETS_DIR" \
  --replay-dir "$MANGEKYOU_REPLAY_DIR" \
  --game-dir "$MANGEKYOU_GAME_DIR" \
  --save-dir "$MANGEKYOU_SAVE_DIR" \
  --ffmpeg "$MANGEKYOU_FFMPEG"
```

路径变量由使用者设置为本机绝对路径。若 Homebrew `ffmpeg` 已安装，可省略 `--ffmpeg`。

## 存档与读档

- 播放器的普通槽、快速槽和自动档写入独立的 `--save-dir`。快速读档可用 `--quick-load --load-task-confirm yes`；取消读取可将确认值改为 `no`。
- 自动档可用 `--recover-autosave AutoSaveData1.svd --load-task-confirm yes` 恢复。
- 启动时发现 `ExceptionBackup.svd` 会显示恢复确认。Mac 专用错误扩展仅在已有可写存档配置和安全等待点时创建恢复档。
- 详细限制、错误处理和复现参数见[功能里程碑](docs/40-feature-milestones.md)。

## 开发验证

```sh
python3 -m unittest discover -s tests -v
swift test -c release --package-path native
.venv/bin/python tools/verify_upstream.py
```

上游解析器版本和摘要固定在 [`docs/upstream-lock.json`](docs/upstream-lock.json)。`THIRD_PARTY.md` 记录依赖及许可证边界。

## 证据与数据

- `reports/p0/` 保留已脱敏的 P0 基线。`reports/p1/` 只放可公开的元数据摘要。
- 完整回放、原始字节范围和受限研究副本放在 Git 忽略的 `private/`。
- 不提交商业资源、剧本正文、CG、音频、密钥或完整提取结果。
- 项目范围和证据状态规则见 [`docs/00-project-scope.md`](docs/00-project-scope.md)。
