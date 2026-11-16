# XiaoAI L05C Docker 统一网关

当前的 Docker 架构、配置、部署顺序、验收矩阵和故障排查见 [docs/L05C_LXSERVER_XIAOZHI_PLAN.md](docs/L05C_LXSERVER_XIAOZHI_PLAN.md)。

目标设备：小爱音箱 Play 增强版（L05C）  
运行环境：Docker/Compose（群晖是可选示例）

## 目录

```text
oo-music/          旧版兼容目录（当前 iKuai 方案不再使用）
xiaomi-gateway/    MiService、AI、lxserver 音乐路由和小爱原生控制透传
deploy/            通用与可选群晖 Container Manager 部署模板
PROJECT_PLAN.md    实施计划和当前进度
docs/              完整 Docker 项目规划
```

## Docker 部署

通用 Compose（从 GHCR 拉取镜像）：

```powershell
docker compose -f E:/AI/XiaoAi_misuc/deploy/docker-compose.yml pull
docker compose -f E:/AI/XiaoAi_misuc/deploy/docker-compose.yml up -d
```

默认服务地址：

```text
lxserver：       http://<docker-host>:9527
xiaomi-gateway： http://<docker-host>:58092
```

首次部署保持 `MI_LISTENER_ENABLED=false`，先验证健康检查、活动音乐源账号、小米设备 token 和模型接口，再打开后台监听。

网关使用 `MUSIC_BACKEND=lxserver`，通过 `LXSERVER_BASE_URL` 调用 LX Music Server；`MUSIC_SOURCE` 使用 lxserver 的平台代码，例如 `kw`、`tx`、`wy`。小爱语音不需要说平台名称。切换活动源后重启网关。

## 群晖可选部署

详细步骤见：

[deploy/synology/README.md](<E:/AI/XiaoAi_misuc/deploy/synology/README.md>)

默认目录：

```text
/volume1/docker/xiaoai-music/
```

示例服务地址：

```text
lxserver：       http://192.168.8.3:9527
xiaomi-gateway： http://192.168.8.3:58092
```

首次部署保持：

```text
MI_LISTENER_ENABLED=false
```

先验证健康检查、lxserver 音源、模型和小米设备 token，再打开后台监听。

## 关键验证接口

```text
GET  /healthz
GET  /v1/status
GET  /v1/mi/devices
GET  /v1/music/search?q=周杰伦晴天
POST /v1/music/resolve
POST /v1/music/play
POST /v1/ai/answer
```

L05C 使用 MP3 播放，设备 TTS 指令为 `[5,3]`，连续对话保持关闭。未匹配到音乐或 AI 前缀的请求会交给小爱原生处理，例如“打开客厅的灯”。

爱快专用 Compose 假定 lxserver 已独立运行在 `http://192.168.8.1:9527`，Compose 只新增 `xiaozhi-esp32-server` 和 `xiaomi-gateway`。自建 `xiaozhi-esp32-server` 负责小智 ESP32 的 WebSocket/MQTT 语音链路；它不是网关可直接调用的 HTTP 聊天接口。网关可复用 xiaozhi-server 中配置的同一个 OpenAI 兼容模型；如需共享小智会话记忆和工具，需要另建文本适配层。

## 本地检查

```powershell
cd E:\AI\XiaoAi_misuc\xiaomi-gateway
python -m pytest -q tests
python -m compileall -q app

cd E:\AI\XiaoAi_misuc\oo-music\backend
go test ./...  # 仅用于旧版兼容目录的回归检查
```
