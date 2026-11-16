# Windows 开发与运行

## 支持范围

Windows 10/11 x64；Flutter 3.47 或更新版本，Dart 3.13.4 或更新版本。
开发需要 Visual Studio 的「使用 C++ 的桌面开发」、Windows SDK 和 CMake。
本次在 Windows 10 22H2、Flutter 3.47.9、Visual Studio 2026 上构建。
仅开发 Windows 时不需要 Android SDK。Windows N/KN 需安装微软 Media Feature Pack。

- 音频：Windows 使用 `media_kit` / libmpv；所有命令串行，切歌取消旧等待，
  加载超时会隔离失去响应的实例，失败后可点击播放重试。Mac 仍使用 `audioplayers`。
- MV：`media_kit` + libmpv，复用中文播放/暂停/进度条。
- 桌面歌词：独立 Win32 分层置顶窗口，不抢焦点。与 Mac 相同的柔和青绿色原文和灰绿色翻译，
  锁定前后都保留深色描边与柔化阴影。Mac 式居中悬停图标栏（切歌/播放/锁/关闭）和圆角背景。
  图标使用原生矢量路径，不依赖字体符号；鼠标悬停提供中文提示。拖动非按钮区域移动；
  拖动右下角调整宽度（460–800 逻辑像素），字体随宽度调整。锁定后只显示解锁按钮。
  背景隐藏时，整块歌词窗口（包括文字）不拦截下方应用的鼠标点击、滚轮和拖动；
  锁定时始终穿透，仅悬停后可见的小解锁图标接收点击。未锁定且背景可见时，
  保留按钮、移动和改宽操作；圆角外的透明区域仍穿透。
- 快捷键：应用获得焦点时 `Ctrl+K` 搜索、`Ctrl+Shift+L` 显示/隐藏歌词。
  桌面歌词需先选择歌曲；这里不是系统全局热键。
- 本地歌单、账号缓存、歌词、下载复用共享层。macOS 的 AppKit / `video_player` 实现保留。

## 启动后端

客户端不内置 Go 服务。先准备管理网页（可选），再启动后端：

```powershell
Set-Location C:\Users\PC\GolandProjects\oo-music\admin-web
npm ci
npm run build
# 仅在受限环境中 esbuild 不能扫描父目录时，可改用：
# npm run build -- --configLoader runner

Set-Location C:\Users\PC\GolandProjects\oo-music\backend
if (-not (Test-Path -LiteralPath '.env')) { Copy-Item '.env.example' '.env' }
# 用编辑器修改 .env，设置自己的初始管理员用户名、强密码。
# 管理网页同端口运行时，取消 OO_MUSIC_WEB_DIST=../admin-web/dist 前的注释。
go run ./cmd/server
# 已构建后端 EXE 时也可在这个目录运行：
# & '..\build\windows-backend\oo-music-server.exe'
```

保持这个终端运行。默认服务为 `http://127.0.0.1:8787`；启用静态目录后可在浏览器打开
同一地址进入管理后台。已有配置或 SQLite 数据不要覆盖。用自己的账号扫码授权，
客户端账号和远程歌单功能需要有效授权；公开音乐 API 是否需要授权由管理后台开关决定。
不要把本地服务直接暴露到公网。不会绕过 VIP、版权、地区或付费限制。

## 运行 / 构建

另开 PowerShell：

```powershell
Set-Location C:\Users\PC\GolandProjects\oo-music\apps\desktop
flutter pub get
flutter run -d windows
```

Release 构建：

```powershell
flutter analyze
flutter test
flutter build windows --release
```

或从仓库根目录使用脚本（默认执行依赖解析、静态检查、全部测试和 Release 构建）：

```powershell
Set-Location C:\Users\PC\GolandProjects\oo-music
.\scripts\build-windows.ps1 -Package
# Flutter 不在 PATH 时：
.\scripts\build-windows.ps1 -Flutter 'D:\Program Files\flutter\bin\flutter.bat' -Package
```

后端不在本机时，构建时指定地址：

```powershell
.\scripts\build-windows.ps1 -ApiBaseUrl 'https://your-backend.example' -Package
```

输出：

- 完整程序目录：`apps/desktop/build/windows/x64/runner/Release/`。
- 主程序：上述目录中的 `oo_music.exe`。
- `-Package` 输出：`apps/desktop/build/windows/distribution/oo-music-windows-x64.zip`，附 SHA256。

当前本机 `1.0.4+5` 测试版输出为
`C:\Users\PC\GolandProjects\oo-music\apps\desktop\build\windows\x64\compatibility-1.0.4\Release\`，
避免覆盖运行中的旧程序。脚本会读取 CMake cache 并打印实际目录，不打包旧 runner 输出。

**不能只复制 EXE**：DLL、`sqlite3.dll`、`data/` 必须一起保留。Release 已带可再分发的
Visual C++ 运行库，不需在目标机安装 Visual Studio。此版本是未签名的便携测试版，
不是安装包；对外分发前还需处理签名、安装/更新和 libmpv/FFmpeg 等第三方许可要求。

## 数据目录

- 本地歌单/账号缓存：`%APPDATA%\oo music\oo music\oo_music\library.sqlite3`。
- 下载：系统 Downloads 下的 `oo music` 子目录（通常为 `%USERPROFILE%\Downloads\oo music`）。
- QQ 音乐 Cookie 由后端 SQLite 管理；客户端存本地授权会话，不要共享或提交这些数据库。
- 后端 Windows 数据库文件使用 NTFS DACL 限制到运行用户、SYSTEM 和本机管理员；
  新建的数据目录提供可继承的私有 ACL，保护 SQLite WAL/SHM。不修改已有项目父目录 ACL。
- 删除 build 目录不会删除歌单，但也不应该用清理应用数据来解决构建错误。

## 构建排查

### Flutter 原生可访问性崩溃的临时兼容模式

本机转储曾出现 `ui::AXNodeData::GetBoolAttribute / MSAAState` 和
`FlutterPlatformNodeDelegate::ChildAtIndex` 访问异常。换音频引擎不会修复这条
Flutter 引擎路径；正常启动仍可能触发。关联上游问题：
[Flutter #195399](https://github.com/flutter/flutter/issues/195399)。

用户已接受可切回的临时兼容版。从 `1.0.4+5` 起，此 Windows 测试版
**默认启用兼容模式**，双击 `oo_music.exe` 无需额外参数，标题显示版本和
`[Windows 兼容模式]`。`Start-Compatibility.cmd` 显式选择同一模式；也可执行：

```powershell
.\oo_music.exe --windows-accessibility-compat
```

**该模式只针对本次进程临时绕开 Flutter 的 MSAA/UIA 桥接**，因此 Windows
屏幕阅读器和 UI 自动化无法读取 Flutter 控件；鼠标、键盘、歌曲、MV、歌词不变。
Mac 无任何变化，不修改 Windows 设置或 SDK。切回时，先关闭旧窗口，再运行
`Start-Normal.cmd`（会提示已知风险并确认），或显式执行：

```powershell
.\oo_music.exe --windows-accessibility-normal
```

此时标题为 `[Windows 标准模式]`，恢复屏幕阅读器/UI 自动化，**仍可能触发已知崩溃**。
同时传两个模式参数时优先兼容。切换只影响新进程，不保存系统或全局偏好。
原生 guard 会在 Flutter 子窗口挂接/显示和插件注册前安装，并核验成功；父窗口也只过滤
相同的 MSAA/UIA 请求。普通输入、系统标题栏对象等保持正常，安装失败不偷偷回退到标准模式。

`1.0.3` 默认仍为标准模式；2026-11-02 15:49/15:50 两次用户崩溃的本地转储确认
没有兼容参数。不要把这些旧进程与新版混合测试。这只是兼容缓解措施，不等于修复上游引擎，
真实歌曲连续切换仍需确认。记录见 `outputs/windows-playback-crash-2026-11-02.md`。

### 依赖 / 文件问题

第一次构建会从官方源获取 NuGet/WIL、libmpv、ANGLE 与 SQLite。
若下载失败，先检查网络/代理和具体目录的写入权限，再重试；不要禁用 TLS 验证。
本机已校验的下载可在 `build/windows-tools` 和 `build/windows/x64` 中复用；构建脚本
会校验缓存 NuGet 的 SHA256，不修改第三方包源码或系统设置。

若提示目标文件被占用，先正常关闭正在运行的 oo music，再构建。
第三方 media_kit 的 CMake 开发警告不等于编译失败。

## 验收清单

自动测试覆盖共享业务、Windows 工厂、MV 初始化/错误/超时/取消/释放和方法通道协议。
原生窗口已编译进 Release；实际桌面交互和账户相关内容还需手测：

1. 搜索并播放有权限的歌曲；测试暂停、拖动进度、音量、音质、切歌。
2. 新建歌单、关闭再打开确认持久化；下载一首有权访问的歌曲。
3. QQ 扫码登录、账号切换、远程歌单刷新/本地导入。
4. 播放 MV、暂停/拖动进度、关闭再打开；模拟网络失败再重试。
5. `Ctrl+Shift+L` 打开歌词；检查原文/翻译同步、悬停、移动、改宽、锁定/解锁/关闭。
   将歌词放在桌面文件或资源管理器上：锁定后从文字和透明背景处点击，应直接选中下方文件；
   悬停出现的解锁图标仍可点击。未锁定时，隐藏背景应穿透，可见背景才用于移动/调整。
6. 高 DPI 和多屏移动、主窗口最小化、退出后歌词不残留。
