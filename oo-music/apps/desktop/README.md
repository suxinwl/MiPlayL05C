# oo music 客户端

Flutter 跨平台客户端，支持 QQ 音乐与网易云音乐双平台搜索、播放、同步歌词、
本地/远程歌单和 MV 播放。已启用 macOS、Windows 和 Android；共享业务通过平台
适配层连接各平台播放、桌面歌词、后台媒体服务和系统文件保存能力。

```bash
flutter pub get
flutter run -d macos
```

Windows：

```powershell
flutter pub get
flutter run -d windows
flutter build windows --release
```

运行 `build/windows/x64/runner/Release/oo_music.exe`；必须保留同目录 DLL 和 `data/`。
详细的 Windows 后端启动、数据目录、打包和验收说明见
[`docs/windows.md`](docs/windows.md)。仓库根目录的 `scripts/build-windows.ps1 -Package`
可执行检查、构建并生成便携测试 ZIP。

当前 Windows 临时测试版默认启用可访问性兼容模式，标题显示版本及模式；鼠标和键盘不变，
但 Flutter 屏幕阅读器/UI 自动化不可用。`Start-Normal.cmd` 可切回标准模式（仍有已知引擎崩溃风险）。

客户端默认请求 `http://127.0.0.1:8787`，可以使用 `--dart-define=API_BASE_URL=...` 指定其他后端。
完整启动说明见仓库根目录的 `README.md`。

免费 macOS/Windows/Android 发布包、Android 签名 key 和 GitHub Actions 流程见
[`../../docs/free-release-distribution.md`](../../docs/free-release-distribution.md)。

> 本版本不迁移旧版客户端数据库。当前 v4 结构正常时保留歌单和账号；旧版本或字段不匹配时，
> 启动会清空本地歌单、歌曲引用、账号和设置后重建。

## 目录分层

- `lib/api`、`lib/models`、`lib/lyrics`、`lib/storage`、`lib/player/play_queue.dart`：
  完全共享的业务、模型、歌词和存储逻辑。
- `lib/screens`、`lib/widgets`：共享 UI，不直接判断操作系统。
- `lib/platform`：平台文案、快捷键、MV 与桌面歌词驱动。
- `lib/player/playback_engine.dart`：音频播放接口；Windows 使用串行 `media_kit`，
  macOS 使用 `audioplayers`，Android 使用 `just_audio`/ExoPlayer 前台媒体服务。
- `lib/services/download_service.dart`：共享网络下载逻辑，路径由
  `path_provider` 按平台解析。
- `lib/platform/download_file_export.dart`：Android 使用 Storage Access Framework
  打开系统保存对话框；桌面平台沿用下载目录。

## 平台状态

| 平台 | 状态 | 后续主要工作 |
| --- | --- | --- |
| macOS | 已启用 | 原生桌面歌词和 `video_player` MV 已接入 |
| Windows | 已启用 | Win32 桌面歌词、`media_kit` MV、SQLite 与 Release 构建已接入；账户与实际播放需手测 |
| Android | 测试版已启用 | 响应式主页、后台播放/媒体通知、悬浮歌词、SAF 下载和本地歌单已接入；真机全面验收待完成 |

更详细的后端地址、SQLite、Runner 和适配器说明见
[`docs/platform-compatibility.md`](docs/platform-compatibility.md)。
Android 构建、USB 安装、已知限制和验证记录见
[`docs/android.md`](docs/android.md)。
