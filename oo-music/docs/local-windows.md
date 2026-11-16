# Windows 本地运行 oo-music（不使用 Docker）

本文适用于 `E:\\AI\\XiaoAi_misuc\\oo-music`。

## 1. 构建管理台

在 PowerShell 执行：

```powershell
cd E:\\AI\\XiaoAi_misuc\\oo-music\admin-web
npm ci
npm run build
```

构建结果为：

```text
E:\\AI\\XiaoAi_misuc\\oo-music\admin-web\dist
```

## 2. 准备后端配置

```powershell
cd E:\\AI\\XiaoAi_misuc\\oo-music\backend
Copy-Item .env.example .env
```

编辑 `backend/.env`，至少填写：

```dotenv
OO_MUSIC_ADDR=0.0.0.0:8787
OO_MUSIC_DB_PATH=./data/oo-music.db
OO_MUSIC_WEB_DIST=../admin-web/dist
OO_MUSIC_ADMIN_USERNAME=admin
OO_MUSIC_ADMIN_PASSWORD=替换为强密码
```

`backend/.env` 和 `backend/data/` 已被 Git 忽略，不要提交账号凭据或 SQLite 数据库。

## 3. 启动 Go 后端

```powershell
cd E:\\AI\\XiaoAi_misuc\\oo-music\backend
go test ./...
go run .\cmd\server
```

成功后：

```text
管理台：http://127.0.0.1:8787
健康检查：http://127.0.0.1:8787/healthz
```

首次打开管理台完成 QQ 音乐和网易云音乐扫码登录。账号登录态会写入 `backend/data/oo-music.db`。

## 4. 网关地址怎么填写

### 网关也在 Windows 本地运行

```dotenv
OO_MUSIC_BASE_URL=http://127.0.0.1:8787
```

### 网关运行在 Docker Desktop，oo-music 在 Windows 宿主机

```dotenv
OO_MUSIC_BASE_URL=http://host.docker.internal:8787
```

### 网关运行在爱快或其他设备

将 `OO_MUSIC_ADDR` 设为 `0.0.0.0:8787`，然后网关使用运行 Windows 主机的局域网 IP：

```dotenv
OO_MUSIC_BASE_URL=http://<Windows主机IP>:8787
```

同时在 Windows 防火墙放行 TCP 8787。`http://oo-music:8787` 只适用于同一个 Docker Compose 网络内部，不能在本地浏览器或跨设备访问。

## 5. 常用验证命令

```powershell
Invoke-RestMethod http://127.0.0.1:8787/healthz
Invoke-RestMethod 'http://127.0.0.1:8787/api/search?source=qq&q=周杰伦晴天'
Invoke-RestMethod 'http://127.0.0.1:8787/api/search?source=netease&q=周杰伦晴天'
```

播放地址接口必须带平台来源：

```powershell
Invoke-RestMethod 'http://127.0.0.1:8787/api/playback?source=qq&song_id=歌曲ID&quality=320mp3'
Invoke-RestMethod 'http://127.0.0.1:8787/api/playback?source=netease&song_id=歌曲ID&quality=320mp3'
```

停止本地服务：在运行 `go run` 的窗口按 `Ctrl+C`。
