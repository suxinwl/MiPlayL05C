# 爱快 Docker Compose 部署

当前爱快上已经独立部署 lxserver，因此本 Compose 不再创建 lxserver 容器。它只负责：

```text
xiaozhi-esp32-server    8000/8003  自建小智 ESP32 WebSocket、OTA 和语音后端
xiaomi-gateway          58092     L05C 的 MiService、音乐路由、AI 和米家原生透传
```

已经存在的 lxserver：

```text
http://192.168.8.1:9527
```

网关通过这个局域网地址访问 lxserver，不能写 `http://lxserver:9527`，因为 lxserver 不在本 Compose 项目中。

## 目录

```text
/mnt/sda1/docker/MiPlayL05C/
├── docker-compose.yml
├── xiaozhi-config.yaml
├── xiaozhi-data/
├── xiaozhi-models/
│   └── SenseVoiceSmall/
│       └── model.pt
└── gateway-config/
    └── mi.token
```

爱快文件名不能以 `.`, `_`, `-` 或括号开头，因此使用 `xiaozhi-config.yaml` 和 `gateway-config/mi.token`。Compose 会把宿主机的 `xiaozhi-config.yaml` 映射为容器内的 `/opt/xiaozhi-esp32-server/data/.config.yaml`，保留镜像内默认 `config.yaml` 并只覆盖需要修改的配置。

## 小智配置

复制：

```text
deploy/ikuai/xiaozhi-config.example.yaml -> xiaozhi-config.yaml
```

至少修改：

```yaml
server:
  websocket: ws://192.168.8.1:8000/xiaozhi/v1/

LLM:
  DoubaoLLM:
    model_name: 你的方舟模型名或接入点 ID
    api_key: 你的火山方舟 API Key
```

`server.websocket` 必须使用爱快局域网地址，因为 ESP32 设备需要从局域网连接它；不能填写容器名。

准备小智语音识别模型：

```text
xiaozhi-models/SenseVoiceSmall/model.pt
```

该文件需要按小智项目文档下载，缺失时服务可能无法正常启动。若只需要小智模型配置而暂不连接 ESP32，也可以先启动网关，后续补齐模型文件再启动小智容器。

## 网关环境变量

```yaml
MUSIC_BACKEND: lxserver
LXSERVER_BASE_URL: http://192.168.8.1:9527
MUSIC_SOURCE: kw
MUSIC_QUALITY: 320mp3
MUSIC_ALLOW_FALLBACK: "true"

MODEL_PROVIDER: doubao
MODEL_NAME: 与 xiaozhi-config.yaml 相同
MODEL_BASE_URL: https://ark.cn-beijing.volces.com/api/v3
MODEL_API_KEY: 与 xiaozhi-config.yaml 相同
```

当前网关和小智服务端使用同一个豆包模型配置，但两者是两条协议链路：

```text
L05C -> MiNA -> xiaomi-gateway -> 豆包 OpenAI 兼容 API -> MiService TTS -> L05C
ESP32 -> xiaozhi-esp32-server WebSocket -> 豆包 OpenAI 兼容 API -> 小智 TTS -> ESP32
```

小智服务端的 `ws://192.168.8.1:8000/xiaozhi/v1/` 不能直接填入网关的 `MODEL_BASE_URL`。如果以后要让 L05C 共享小智的会话记忆、插件和工具，需要另行开发 HTTP 文本适配层。

## 部署步骤

1. 在爱快 Docker 页面创建 Compose 项目。
2. 粘贴 `deploy/ikuai/docker-compose.yml`。
3. 上传 `xiaozhi-config.yaml`、`model.pt` 和 `gateway-config/mi.token`。
4. 替换 Compose 中的 `CHANGE_ME_*`。
5. 确认 lxserver 已能访问：

```powershell
Invoke-RestMethod 'http://192.168.8.1:9527/api/status'
```

6. 首次保持：

```yaml
MI_LISTENER_ENABLED: "false"
```

7. 点击拉取镜像并启动。
8. 验证：

```powershell
Invoke-RestMethod 'http://192.168.8.1:8003/xiaozhi/ota/'
Invoke-RestMethod 'http://192.168.8.1:58092/healthz'
Invoke-RestMethod 'http://192.168.8.1:58092/v1/status' | ConvertTo-Json -Depth 5
Invoke-RestMethod 'http://192.168.8.1:58092/v1/music/search?q=周杰伦晴天' | ConvertTo-Json -Depth 8
```

9. 验证 AI：

```powershell
Invoke-RestMethod -Uri 'http://192.168.8.1:58092/v1/ai/answer' -Method Post -ContentType 'application/json; charset=utf-8' -Body (@{ text = '请用一句话介绍你自己' } | ConvertTo-Json -Compress)
```

10. `/v1/mi/devices` 正常后，再把 `MI_LISTENER_ENABLED` 改成 `"true"` 并重建网关。

## 切换音乐源

lxserver 源代码：

```text
kw  酷我
kg  酷狗
tx  QQ 音乐
wy  网易云音乐
mg  咪咕
```

例如网易云：

```yaml
MUSIC_SOURCE: wy
```

修改后只需重建 `xiaomi-gateway`，不用重启 lxserver。

## 重建容器

爱快页面中修改 Compose 后执行“更新/重建”。如果使用终端：

```sh
docker compose pull xiaozhi-esp32-server xiaomi-gateway
docker compose up -d --force-recreate xiaozhi-esp32-server xiaomi-gateway
```

不要删除：

```text
xiaozhi-data/
xiaozhi-models/
gateway-config/
```

这些目录分别保存小智配置、语音模型和 Xiaomi token。
