# 跨平台兼容说明

## 设计边界

共享层负责所有与操作系统无关的业务：

- QQ 音乐后端 API、数据模型、歌词解析、播放队列。
- 本地 SQLite、客户端账号缓存、本地与远程歌单。
- 搜索、歌曲列表、歌单、歌词、账号和播放器控件。

平台适配层只负责操作系统能力：

| 能力 | 接口 | macOS | Windows | Android |
| --- | --- | --- | --- | --- |
| 音频播放 | `PlaybackEngine` | `audioplayers` | `media_kit` | `just_audio`/ExoPlayer |
| MV 播放 | `MvPlaybackDriver` | `video_player` | `media_kit` | `video_player` |
| 桌面歌词 | `DesktopLyricsPlatform` | AppKit 方法通道 | Win32 方法通道 | 待接悬浮窗/前台服务 |
| 快捷键 | `AppPlatform` | Command+Shift+L | Ctrl+Shift+L | 无桌面快捷键 |
| 下载目录 | `path_provider` | Downloads | Downloads | 私有缓存 + SAF 系统保存对话框 |

## Windows 实现

1. `windows/` Runner 已加入；标题显示 `oo music`、版本和 Windows 模式，
   初始尺寸 1180×780，最小客户区 980×640。
2. Windows 音频使用串行、可取消、带超时隔离的 `MediaKitPlaybackEngine`；避免
   Media Foundation 插件同步阻塞平台线程。Mac 音频实现不变。
   SQLite 使用包原生构建钩子，DLL 随应用打包。
3. `MediaKitMvPlaybackDriver` 按需创建原生播放器，保留 CDN 请求头。
   共享弹窗提供中文播放控件；支持加载超时、关闭取消、安全错误和一次性资源释放。
4. `desktop_lyrics_platform_factory.dart` 的 Windows 分支复用方法通道，连接
   `windows/runner/desktop_lyrics_window.cpp`。Win32/GDI+ 实现透明置顶、不激活、
   描边歌词、悬停播放控件、锁定、拖动和宽度调整，并处理 DPI/屏幕变更与关闭清理。
5. CMake 将完整便携应用放在构建目录，并附 Release VC 运行库，不尝试安装到 Program Files。
   `scripts/build-windows.ps1 -Package` 可生成完整测试 ZIP；签名安装包和自动更新尚未实现。
6. 用户已接受的 Windows 临时测试版自 `1.0.4+5` 默认绕开 Flutter MSAA/UIA 桥接，
   不影响 Mac。`--windows-accessibility-normal` / `Start-Normal.cmd` 可切回标准模式，
   恢复屏幕阅读器/UI 自动化，但已知 Flutter AX 树崩溃风险仍在。

详细命令和手工验收见 [Windows 说明](windows.md)。桌面快捷键目前只在应用获得焦点时响应。

## Android 实现

1. `android/` Runner 已加入，应用 ID 为 `com.yskj0864.oo_music`；最低 API 24，
   当前使用 API 36 编译，并启用 `INTERNET`、`WAKE_LOCK` 和前台媒体服务权限。
2. Android 音频使用 `just_audio`/ExoPlayer，并由 `audio_service` 承载前台服务。
   应用 UI 与系统媒体控件共享同一播放队列；命令串行化、加载/操作超时和切歌代次
   隔离均在 `AndroidPlaybackEngine` 中完成。
3. 手机端 `HomePage` 使用 Drawer、紧凑底栏和单页完整歌词；键盘弹起时隐藏播放器。
   Android 返回键会先关闭完整播放页、抽屉或弹窗。
4. MV 复用 `video_player`；下载通过 `oo_music/file_export` 方法通道调用系统
   Storage Access Framework，不申请广泛存储权限。
5. 本地歌单仍使用应用私有 SQLite；歌单名称输入控制器由弹窗自身持有，确保输入法
   收起和路由退场完成前不会被提前释放。
6. 开发版默认构建 ARM64 debug APK。构建、USB 转发安装和当前限制见
   [Android 说明](android.md)。

## 当前约束

- 仓库包含 `macos/`、`windows/` 和 `android/` Runner；Windows 当前目标为 x64，
  不提供 ARM64 包。
- Android 悬浮歌词使用系统悬浮窗，需要用户授予“显示在其他应用上层”权限；桌面歌词
  快捷键和 Win32/AppKit 原生窗口仍只适用于桌面。
- Android 自动化与模拟器验证不能替代真机蓝牙、来电打断、锁屏和 OEM 电池策略测试。
- 当前 Android `release` 测试包仍使用本地 debug 密钥签名，不能作为正式发布包。
