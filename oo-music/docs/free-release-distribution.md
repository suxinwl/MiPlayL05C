# 免费三端发布流程

本流程面向熟人小范围分发，不购买 Apple Developer、Windows 代码签名证书，
也不上架应用商店。它能把安装流程做到免费方案下尽量顺畅，但不能消除所有系统安全提示。

## 产物

```text
oo-music-<version>-macos-universal.dmg
oo-music-<version>-windows-x64-setup.exe
oo-music-windows-x64.zip
oo-music-<version>-android-universal.apk
*.sha256
README-macOS.txt / README-Windows.txt / README-Android.txt
```

## 一次性配置

### 1. 正式后端

客户端发布包必须连接公网 HTTPS 后端。不要使用 `127.0.0.1` 或
`10.0.2.2` 构建正式产物。

在 GitHub 仓库中创建 Actions Variable：

```text
OO_MUSIC_API_BASE_URL=https://music.example.com
```

也可以在手动运行工作流时通过 `api_base_url` 输入覆盖。

### 2. Android 永久 release key

只能生成一次，之后必须永久备份。更换 key 后，老用户无法覆盖安装新 APK。

```bash
./scripts/create-android-release-key.sh
```

如果本机没有 Java/keytool，但已安装并启动 Docker，脚本会自动使用临时
`eclipse-temurin:17-jdk` 容器执行 keytool。本机不需要额外安装 JDK。

脚本会生成：

```text
~/.oo-music/android/oo-music-release.jks
alias: upload
```

随后在 GitHub 仓库中添加 Actions Secrets：

```text
ANDROID_KEYSTORE_BASE64
ANDROID_KEYSTORE_PASSWORD
ANDROID_KEY_ALIAS
ANDROID_KEY_PASSWORD
```

macOS 生成 Base64：

```bash
base64 -i ~/.oo-music/android/oo-music-release.jks | pbcopy
```

Linux 生成 Base64：

```bash
base64 -w0 ~/.oo-music/android/oo-music-release.jks
```

不要把 JKS、密码或 Base64 内容提交到 Git。

Android 的 APK 构建仍然需要 JVM；GitHub Actions 的 Ubuntu Runner 已提供
Java 17，因此日常发布不需要在本地安装 Android SDK 或 JDK。

### 3. 公共下载仓库

源码仓库保持私有，安装包发布到独立公共仓库：

```text
https://github.com/Rankgice/oo-music-release
```

公共仓库不能是空仓库，否则 GitHub 无法为 Release 创建 tag。首次使用先在
本地创建一个只有说明文件的初始提交：

```bash
git clone git@github.com:Rankgice/oo-music-release.git
cd oo-music-release
git checkout -B main
printf '# oo music downloads\n' > README.md
git add README.md
git commit -m "Initialize download repository"
git push -u origin main
```

仓库中只放 README、Release 和安装包，不放源码或构建凭据。

创建一个 Fine-grained Personal Access Token：

- Resource owner：`Rankgice`
- Repository access：仅选择 `oo-music-release`
- 权限：`Contents: Read and write`

然后在私有仓库 `Rankgice/oo-music` 的
`Settings -> Secrets and variables -> Actions` 中增加 Secret：

```text
RELEASE_MIRROR_TOKEN
```

不要把 Token 创建成 Actions Variable，也不要提交到仓库。

## 运行流水线

工作流文件：

```text
.github/workflows/client-release.yml
```

手动运行：

```text
GitHub -> Actions -> Client Release -> Run workflow
```

或推送版本 Tag：

```bash
git tag v1.2.0
git push origin v1.2.0
```

Tag 构建会先把三端产物附加到私有仓库 Release，再使用
`RELEASE_MIRROR_TOKEN` 将同一批文件同步到公共仓库
`Rankgice/oo-music-release`。同一个 tag 重跑时会覆盖公共 Release 中同名资产。

手动运行不会创建 Release，只保存在 Actions Artifacts 中，便于先内部验收。

发布完成后的公共下载页：

```text
https://github.com/Rankgice/oo-music-release/releases/latest
```

## macOS 安装体验

免费产物使用 ad-hoc 签名，没有 Apple 公证。第一次启动可能提示 Apple
无法验证应用。

用户操作：

1. 将 App 拖入 Applications。
2. 双击后按系统提示打开“系统设置 -> 隐私与安全性”。
3. 点击“仍要打开”并输入本机密码。

不要关闭 Gatekeeper 全局保护。DMG 内已经包含 `README-macOS.txt`。

## Windows 安装体验

安装器使用 Inno Setup，安装在：

```text
%LOCALAPPDATA%\Programs\oo music
```

它不需要管理员权限，也不会弹 UAC。由于没有代码签名证书，浏览器下载后的
第一次运行可能在 SmartScreen 中显示“Windows 已保护你的电脑”。

用户操作：

```text
更多信息 -> 仍要运行
```

也可以右键安装器 -> 属性 -> 勾选“解除锁定”。不要关闭 SmartScreen 全局保护。

便携 ZIP 仍然保留，作为安装器无法使用时的备用包。

## Android 安装体验

APK 必须使用永久 release key 签名。构建脚本会调用 `apksigner` 校验签名，
并拒绝任何 `CN=Android Debug` 证书。

直接下载 APK 时，Android 必然要求用户允许当前来源安装应用。这是系统安全机制，
免费分发无法移除。用户按提示开启当前浏览器/文件管理器权限即可。

如果 Play Protect 提示未知应用，请确认 APK 来源和 SHA256 后选择“仍要安装”。

## 版本规则

三端统一使用 `apps/desktop/pubspec.yaml`：

```yaml
version: 1.2.0+7
```

- `1.2.0` 是展示版本。
- `7` 是内部构建号。
- 每次发布必须递增构建号。
- Android 升级尤其依赖持续递增的 `versionCode` 和不变的签名 key。

## 已知边界

- macOS 免费版无法绕过 Gatekeeper 首次确认。
- Windows 免费版无法保证 SmartScreen 首次不提示。
- Android 官网 APK 无法静默安装。
- 三端都没有付费证书，产物身份可信度依赖可信下载渠道和 SHA256。
- 发布前仍需在干净机器或真机完成安装、升级、播放、MV、下载和后台播放验收。
