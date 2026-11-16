# Android 客户端

## 当前状态

Android Runner 已接入，应用 ID 为 `com.yskj0864.oo_music`，最低版本 Android 7.0
（API 24），当前 Flutter 工程使用 API 36 编译。客户端复用搜索、播放队列、歌词、
本地歌单、远程歌单和 MV 业务层；移动端界面、后台媒体服务和系统文件保存使用
Android 专用适配层。

本版本用于真机预览和测试，不是商店发布版。`debug` 和当前 `release` 构建都由本机
Android Debug 密钥签名；正式发布前必须换成受保护的 release keystore，并重新验证
升级安装路径。

## 已实现能力

- 手机竖屏搜索、播放器、完整歌词页、账号面板和响应式布局。
- ExoPlayer 音频播放、播放队列自动续播、快速切歌隔离、加载/操作超时和安全重试。
- `audio_service` 前台媒体服务、锁屏/通知栏媒体信息、上一首/下一首/暂停/继续。
- Android 系统悬浮窗桌面歌词，支持拖动、上一首、播放/暂停、下一首和关闭。
- 后台播放；暂停时保留前台服务，显式停止后结束媒体会话。
- Android 返回键先关闭完整播放页、歌单抽屉和弹窗，不直接退出正在使用的主页。
- 搜索歌曲与歌单歌曲下载；保存时打开系统文件选择器，由用户选择位置。
- 同步歌词、翻译、罗马音和关联 MV 播放。
- 本地歌单 SQLite 持久化，应用重启后保留歌单及歌曲。

## 暂未实现

- 官方 App 直接打开二维码登录链接。真机验证确认 QQ 不接管该短链并将其交给浏览器，
  网易云虽然接管 `orpheus://`，但进入的是普通网页登录并触发环境风控；扫码动作包含官方
  App 的内部专用处理，不能用普通 Intent 等价替代。当前继续使用二维码或手动凭据。
- 手机端自动迁移 macOS/Windows 的客户端账号、播放记录或歌单；这些数据仍属于各
  平台的应用私有数据。
- 生产签名、Google Play 发布、后台下载任务和跨设备云同步。
- 对各家 OEM 电池策略的自动修改。系统清理后台后，需要用户自行将应用设为“不限制”。

## 开发环境

要求：

- Flutter stable，当前验证版本为 3.47.9。
- Android SDK Platform 36、Build Tools 36.0.0。
- Android NDK `28.2.13676358`。
- Android Studio 自带 JDK，或 JDK 17 以上。当前工程按 Java 17 编译。
- 一个已授权 USB 调试的 Android 设备，或独立 AVD。

检查：

```powershell
flutter doctor -v
flutter devices
```

## 构建

先在仓库根目录启动已有后端，并确认健康检查：

```powershell
cd C:\Users\PC\GolandProjects\oo-music\backend
go run ./cmd/server
```

另开 PowerShell：

```powershell
cd C:\Users\PC\GolandProjects\oo-music
.\scripts\build-android.ps1 -Flutter 'D:\Program Files\flutter\bin\flutter.bat'
```

默认产物：

```text
apps\desktop\build\android\distribution\oo-music-android-arm64-debug.apk
apps\desktop\build\android\distribution\oo-music-android-arm64-debug.apk.sha256
apps\desktop\build\android\distribution\README-Android.txt
```

常用参数：

```powershell
# 跳过 analyze/test，仅重新构建
.\scripts\build-android.ps1 -Flutter 'D:\Program Files\flutter\bin\flutter.bat' -SkipChecks

# 构建 x64 模拟器测试包
.\scripts\build-android.ps1 -TargetPlatform android-x64 -SkipChecks

# 测试 release 模式（仍由 debug key 签名）
.\scripts\build-android.ps1 -Mode release -SkipChecks

# 使用 HTTPS 远程后端
.\scripts\build-android.ps1 -ApiBaseUrl 'https://music.example.com'
```

明文 HTTP 只允许 `127.0.0.1`、`localhost` 和 Android 模拟器宿主机 `10.0.2.2`。
远程后端必须使用 HTTPS。

## USB 真机安装

先保持后端运行，再执行：

```powershell
cd C:\Users\PC\GolandProjects\oo-music
.\scripts\install-android.ps1 -UsbBackend
```

脚本会：

1. 校验 APK 的 SHA256。
2. 确认恰好有一台已授权设备，或使用 `-DeviceId` 明确指定。
3. 执行 `adb install -r`，只替换应用并保留数据。
4. 通过 `adb reverse tcp:8787 tcp:8787` 转发后端 USB 端口。
5. 启动应用。

安装确认、USB 调试授权和账号授权需要用户在设备上手动完成。脚本不会卸载应用、
清除数据、授予危险权限或绕过系统弹窗。保持 USB 连接和后端进程运行，否则
`127.0.0.1:8787` 无法访问。

模拟器访问宿主机后端时，也可以直接使用
`-ApiBaseUrl http://10.0.2.2:8787`，无需 `adb reverse`。

## 下载与保存

下载先进入应用私有缓存，再通过 Android Storage Access Framework 打开系统保存
对话框。用户取消时私有缓存仍保留；只有用户选择位置后才复制到该位置。应用不申请
广泛存储权限，也不会把账号数据库作为可导出文件。

## 后台播放

首次播放后会出现媒体通知。切到后台后，通知栏可暂停、继续、上一首和下一首。
系统音频焦点、来电/其他媒体打断和耳机拔出由 `audio_session` 与 `just_audio`
处理。部分 Android 12 及 OEM 系统会限制后台启动前台服务；若通知消失，请先检查
系统的电池优化和后台限制，再重新从应用内播放。

Android 13 及以上必须在系统弹窗中允许通知；如果曾拒绝，可到应用系统设置中重新开启。
Android 桌面歌词还需要“显示在其他应用上层”权限，首次打开时会跳转系统授权页，授权后
返回应用再次点击桌面歌词按钮即可。

## 数据与隐私

- 本地歌单和最近播放保存在应用私有 SQLite 中，卸载应用会删除。
- 客户端不直接保存或使用 QQ 音乐 Cookie；账号授权仍通过后端管理链路完成。
- 不包含远程崩溃上报或第三方统计 SDK。
- `android:allowBackup` 已关闭，避免把凭据和私有数据库自动备份到云端。

## 验证记录

2026-11-06 在独立 API 37 x86_64 AVD（通过 `libndk_translation` 运行 ARM64
测试 APK）完成实际 UI 验证：

- 搜索、在线歌曲播放、整首结束自动下一首。
- 后台播放、媒体通知、通知栏上一首/下一首和媒体键继续播放。
- 18 次快速切歌后保持同一进程，未出现 Flutter/AndroidRuntime 异常。
- 歌词、MV 播放与进度拖动、关联 MV 关闭。
- 系统文件选择器保存 MP3，导出文件可读。
- 新建歌单、输入法收起/弹窗退场、添加歌曲、应用重启后数据和歌曲保留。
- 移除 `adb reverse` 后客户端提示无法连接 `127.0.0.1:8787`，恢复转发后搜索成功，
  确认测试包按 USB 真机方案连接后端。

这些结果验证了 Android 代码路径，但不能替代 Android 12 真机的扬声器/蓝牙、来电
打断、耳机拔出、锁屏策略、各家 OEM 电池管理和系统文件选择器测试。真机结果仍需
单独记录。

2026-11-12 新增的 Android 13+ 通知权限请求和系统悬浮窗歌词尚未在当前机器完成
Android 构建或真机验证。本轮只通过 Dart 静态分析和 Flutter 单元测试；原生 Kotlin
部分需要在具备 Android SDK 的环境重新构建，并重点检查通知授权、悬浮窗授权、拖动、
媒体按钮和后台切换。官方 App 链接直接打开方案已在真机否决，不再作为可用入口。

## 测试

```powershell
cd C:\Users\PC\GolandProjects\oo-music\apps\desktop
flutter analyze
flutter test
```

Android 播放引擎、文件导出通道、响应式布局和歌单弹窗生命周期都有自动化测试。
测试通过只说明 Dart/Flutter 逻辑符合预期，不证明所有设备上的音频焦点、蓝牙和
系统通知行为。

## 故障排查

- `cmdline-tools component is missing`：在 Android Studio SDK Manager 安装
  Android SDK Command-line Tools，然后重新运行 `flutter doctor -v`。
- `adb: no devices found`：解锁手机，确认 USB 调试授权，并运行 `flutter devices`。
- 播放地址为空：这是后端对应平台号池账号/音质/版权返回的结果，不是客户端网络错误。
- USB 后端连接失败：确认宿主机 `http://127.0.0.1:8787/healthz` 返回 200，并确认
  `adb reverse --list` 中有 `tcp:8787`。
- 后台播放被系统终止：在系统应用设置中允许后台运行并取消电池限制；不要通过关闭
  安全校验来规避系统行为。
- 更新安装签名不一致：不要卸载或清空数据；使用同一调试密钥重新构建，或先备份
  数据并明确迁移方案。
