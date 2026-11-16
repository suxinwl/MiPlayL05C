# 群晖 NAS 部署

目标 NAS：`192.168.8.3`。iKuai `192.168.8.1` 只负责网络出口和局域网，不运行项目容器。

## 目录

在群晖建立共享目录并复制整个项目：

```text
/volume1/docker/xiaoai-music/
├── oo-music/
├── xiaomi-gateway/
├── deploy/
└── runtime/
    ├── oo-music/
    └── gateway/
```

如果你的共享文件夹不是 `/volume1/docker`，需要同步修改本目录 `docker-compose.yml` 中的绝对路径。

## 准备配置

复制并填写：

```text
deploy/oo-music.env.example       -> oo-music/backend/.env
deploy/xiaomi-gateway.env.example -> xiaomi-gateway/.env
```

先只填写 `oo-music` 管理员密码。小米账号、设备 DID、模型 Key 和 `.mi.token` 在验证阶段再加入。

## Container Manager

在群晖 Container Manager 中选择“项目”，上传或选择：

```text
/volume1/docker/xiaoai-music/deploy/synology/docker-compose.yml
```

拉取并启动后访问：

```bash
docker compose -f /volume1/docker/xiaoai-music/deploy/synology/docker-compose.yml pull
docker compose -f /volume1/docker/xiaoai-music/deploy/synology/docker-compose.yml up -d
```

```text
oo-music 管理页： http://192.168.8.3:8787
网关健康检查：  http://192.168.8.3:58092/healthz
```

小爱音箱和 NAS 在同一局域网时，L05C 可以访问网关下发的播放地址。`oo-music` 管理页同时支持 QQ 音乐和网易云音乐扫码绑定；网关的活动源由 `MUSIC_SOURCE=qq|netease` 配置，语音指令不需要指定平台。

`.mi.token` 应放在：

```text
/volume1/docker/xiaoai-music/runtime/gateway/.mi.token
```

容器内对应 `/config/.mi.token`。不要把账号、密码、Cookie、Token 或模型 Key 提交到 Git。

完成设备 DID 和 token 配置后，再将 `xiaomi-gateway/.env` 中的 `MI_LISTENER_ENABLED` 改为 `true`。首次部署建议先保持 `false`，先用 `MUSIC_SOURCE=qq` 验证 `/v1/mi/devices`、`/v1/music/search` 和 `/v1/music/resolve`，然后切换 `MUSIC_SOURCE=netease` 验证网易云，确认后再启动后台监听。

## 验收顺序

在局域网电脑上执行：

```bash
curl http://192.168.8.3:8787/healthz
curl http://192.168.8.3:58092/healthz
curl http://192.168.8.3:58092/v1/status
curl http://192.168.8.3:58092/v1/mi/devices
curl 'http://192.168.8.3:58092/v1/music/search?q=周杰伦晴天'
```

Windows 电脑也可以运行同目录的 `check.ps1`：

```powershell
.\check.ps1
```

从搜索结果取 `song_id` 后，先只解析播放地址：

```bash
curl -X POST http://192.168.8.3:58092/v1/music/resolve \
  -H 'Content-Type: application/json' \
  -d '{"song_id":"歌曲ID","quality":"320mp3"}'
```

确认返回有效 URL 后，再实际下发到小爱：

```bash
curl -X POST http://192.168.8.3:58092/v1/music/play \
  -H 'Content-Type: application/json' \
  -d '{"song_id":"歌曲ID","quality":"320mp3"}'
```

如果搜索为空或播放地址为空，先检查当前 `MUSIC_SOURCE` 对应账号的登录态、会员、地区和歌曲权限；如果设备检查失败，检查 `.mi.token`、`MI_DID` 和小米账号区域；如果设备检查成功但无声，保持 `quality=320mp3` 并检查 L05C 是否在线。
