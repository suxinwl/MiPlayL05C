# XiaoAI L05C Docker 统一网关

完整的 Docker 架构、配置、部署顺序、验收矩阵和故障排查见 [docs/L05C_DOCKER_PROJECT_PLAN.md](docs/L05C_DOCKER_PROJECT_PLAN.md)。

目标设备：小爱音箱 Play 增强版（L05C）  
运行环境：Docker/Compose（群晖是可选示例）

## 目录

```text
oo-music/          QQ 音乐 + 网易云音乐 Go 后端
xiaomi-gateway/    MiService、AI、音乐路由和小爱原生控制透传
deploy/            通用与可选群晖 Container Manager 部署模板
PROJECT_PLAN.md    实施计划和当前进度
docs/              完整 Docker 项目规划
```

## Docker 部署

通用 Compose：

```powershell
docker compose -f E:/AI/XiaoAi_misuc/deploy/docker-compose.yml build
docker compose -f E:/AI/XiaoAi_misuc/deploy/docker-compose.yml up -d
```

默认服务地址：

```text
oo-music：       http://<docker-host>:8787
xiaomi-gateway： http://<docker-host>:58092
```

首次部署保持 `MI_LISTENER_ENABLED=false`，先验证健康检查、活动音乐源账号、小米设备 token 和模型接口，再打开后台监听。

网关配置 `MUSIC_SOURCE=qq` 或 `MUSIC_SOURCE=netease` 选择活动源；小爱语音不需要说 QQ 或网易云。切换活动源后重启网关。

## 群晖可选部署

详细步骤见：

[deploy/synology/README.md](<E:/AI/XiaoAi_misuc/deploy/synology/README.md>)

默认目录：

```text
/volume1/docker/xiaoai-music/
```

示例服务地址：

```text
oo-music：       http://192.168.8.3:8787
xiaomi-gateway： http://192.168.8.3:58092
```

首次部署保持：

```text
MI_LISTENER_ENABLED=false
```

先验证健康检查、QQ 音乐账号和小米设备 token，再打开后台监听。

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

## 本地检查

```powershell
cd E:\AI\XiaoAi_misuc\xiaomi-gateway
python -m pytest -q tests
python -m compileall -q app

cd E:\AI\XiaoAi_misuc\oo-music\backend
go test ./...
```
