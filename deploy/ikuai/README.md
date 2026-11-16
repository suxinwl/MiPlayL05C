# 爱快 Docker Compose 部署

当前方案使用两个核心服务：

```text
lxserver          9527   LX Music 在线搜索、播放解析和本地音乐管理
xiaomi-gateway    58092  小爱文本路由、MiService、L05C 播放和 TTS
```

`lxserver` 已经部署在爱快时，网关有两种地址写法：

- 如果 lxserver 和网关属于同一个 Compose 项目：`http://lxserver:9527`
- 如果 lxserver 是另一个 Compose 项目：`http://192.168.8.1:9527`

浏览器访问 lxserver 使用 `http://192.168.8.1:9527`；浏览器访问网关使用 `http://192.168.8.1:58092`。容器内部不能使用浏览器地址代替服务名，必须根据是否同一 Compose 项目选择上面的地址。

## 目录

```text
/mnt/sda1/docker/MiPlayL05C/
├── docker-compose.yml
├── lxdata/
├── lxcache/
├── lxmusic/
└── gateway-config/
    └── mi.token
```

爱快文件名不能以 `.`, `_`, `-` 或括号开头，因此本方案不使用 `.env`，MiService token 使用 `gateway-config/mi.token`。

## 音乐配置

网关不再调用 oo-music，改调用 lxserver 原生接口：

```yaml
MUSIC_BACKEND: lxserver
LXSERVER_BASE_URL: http://lxserver:9527
MUSIC_SOURCE: kw
MUSIC_QUALITY: 320mp3
MUSIC_ALLOW_FALLBACK: "true"
```

`MUSIC_SOURCE` 可选：

```text
kw  酷我
kg  酷狗
tx  QQ 音乐
wy  网易云音乐
mg  咪咕
```

lxserver 搜索接口是 `/api/music/search`，播放解析接口是 `/api/music/url`。它们与 oo-music 的 `/api/search`、`/api/playback` 不兼容，所以必须使用包含 lxserver 适配层的新网关镜像。

使用 lxserver 原生网页播放器先确认搜索和播放可用：

```text
http://192.168.8.1:9527/
```

如果 lxserver 的自定义音源没有配置，搜索可能成功，但 `/api/music/url` 会返回“没有可用音源”或 HTTP 500。此时进入 lxserver 管理页面配置并启用音源。

## AI 与小智服务端

自建 `xiaozhi-esp32-server` 是给小智 ESP32 设备使用的 WebSocket/MQTT 语音后端，默认 WebSocket 类似：

```text
ws://192.168.8.1:8000/xiaozhi/v1/
```

它不是可直接给当前小爱网关调用的普通 HTTP `/v1/chat/completions` 服务。正确的接入方式是：

1. 在 xiaozhi-server 的 `data/.config.yaml` 中配置豆包、DeepSeek 或其他 OpenAI 兼容模型。
2. L05C 网关使用同一个 OpenAI 兼容模型配置，保持模型、提示词和 Key 一致。
3. 如果以后需要共享小智的会话记忆、插件和工具调用，再增加一个专门的 HTTP 文本适配层；不能把 `ws://.../xiaozhi/v1/` 直接填入 `MODEL_BASE_URL`。

当前网关的可用配置示例：

```yaml
MODEL_PROVIDER: doubao
MODEL_NAME: "你的方舟接入点 ID 或模型名"
MODEL_BASE_URL: https://ark.cn-beijing.volces.com/api/v3
MODEL_API_KEY: "你的火山方舟 API Key"
```

`MODEL_API_KEY` 有值时优先使用它；如果使用 `ARK_API_KEY`，必须把 `MODEL_API_KEY` 留空。

## 部署步骤

1. 在爱快 Docker 页面新建 Compose 项目。
2. 粘贴本目录的 `docker-compose.yml`。
3. 把 `CHANGE_ME_*` 替换为真实的 lxserver 管理密码、小米账号、设备 DID、MiOT DID 和模型 Key。
4. 确认 `gateway-config/mi.token` 已上传。
5. 首次启动保持：

```yaml
MI_LISTENER_ENABLED: "false"
```

6. 点击拉取镜像并启动。
7. 检查：

```powershell
Invoke-RestMethod 'http://192.168.8.1:9527/api/status'
Invoke-RestMethod 'http://192.168.8.1:58092/healthz'
Invoke-RestMethod 'http://192.168.8.1:58092/v1/status' | ConvertTo-Json -Depth 5
```

8. 搜索音乐：

```powershell
Invoke-RestMethod 'http://192.168.8.1:58092/v1/music/search?q=周杰伦晴天' | ConvertTo-Json -Depth 8
```

9. 验证 AI：

```powershell
Invoke-RestMethod -Uri 'http://192.168.8.1:58092/v1/ai/answer' -Method Post -ContentType 'application/json; charset=utf-8' -Body (@{ text = '请用一句话介绍你自己' } | ConvertTo-Json -Compress)
```

10. 确认 `/v1/mi/devices` 返回设备后，再将 `MI_LISTENER_ENABLED` 改成 `"true"` 并重建网关。

## 如果 lxserver 已经是另一个 Compose 项目

不要在网关 Compose 中重复创建 lxserver 服务，并把网关环境变量改成：

```yaml
LXSERVER_BASE_URL: http://192.168.8.1:9527
```

网关和 lxserver 必须允许爱快 Docker 网络互相访问；9527 端口需要保持发布。

## 重建网关

爱快页面中修改 Compose 后，执行“更新/重建”或删除后重新创建 `miplayl05c-xiaomi-gateway`。数据只保存在以下目录，不要删除：

```text
lxdata/
lxcache/
lxmusic/
gateway-config/
```

切换音乐源只修改 `MUSIC_SOURCE` 后重建网关，例如网易云：

```yaml
MUSIC_SOURCE: wy
```

米家控制仍由小爱原生能力执行。没有命中网关音乐或 AI 规则的命令，例如“打开客厅的灯”，不会被音乐服务拦截。
