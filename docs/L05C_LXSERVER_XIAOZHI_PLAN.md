# L05C + lxserver + xiaozhi 统一网关方案

## 目标

本版本把音乐后端从 oo-music 切换到已经部署在爱快上的 `xcq0607/lxserver:latest`，保留小爱音箱 Play 增强版（L05C）的 MiService 控制、原生米家透传和 MP3 播放。

AI 侧参考自建 `xiaozhi-esp32-server` 的模型配置和对话提示词。小智服务端主要面向 ESP32，通过 WebSocket/MQTT 完成 ASR、LLM、TTS 和工具调用；它没有一个可以直接替代 OpenAI `/v1/chat/completions` 的通用 HTTP 问答入口。因此当前网关复用小智服务端所使用的同一个 OpenAI 兼容模型配置。需要共享小智会话记忆、插件和工具时，再增加单独的文本适配层。

## 运行拓扑

```text
用户语音
   │
   ├─ MiNA 对话记录
   │
   └─ xiaomi-gateway:58092
        ├─ native ──► 小爱原生米家能力
        ├─ music ──► lxserver:9527 ──► /api/music/search + /api/music/url
        │                              └─► MiService.play_by_url() ──► L05C
        └─ ai ─────► 与 xiaozhi-server 相同的 OpenAI 兼容模型 ──► MiService TTS [5,3]

自建 xiaozhi-esp32-server
   └─ WebSocket/MQTT ──► xiaozhi-esp32 设备
```

若 lxserver 与网关在同一个 Compose 项目，网关使用 `http://lxserver:9527`；若 lxserver 已在另一个爱快 Compose 项目中运行，网关使用 `http://192.168.8.1:9527`。

## lxserver 接口适配

lxserver 原生接口与 oo-music 不兼容，网关新增 `LxServerClient`：

```text
GET  /api/music/search?name=周杰伦晴天&source=kw&type=song&limit=10&page=1
POST /api/music/url
{
  "songInfo": { ...搜索返回的完整歌曲对象... },
  "quality": "320k",
  "enableAutoSwitchApiSource": true
}
```

网关内部质量映射：

```text
320mp3 -> 320k
128mp3 -> 128k
```

lxserver 搜索源代码：

```text
kw  酷我
kg  酷狗
tx  QQ 音乐
wy  网易云音乐
mg  咪咕
```

当前语音无需说平台名称，网关由 `MUSIC_SOURCE` 选择活动源。搜索结果中的完整 `songInfo` 会随歌曲 ID 保留，播放时原样提交给 lxserver；只传一个 ID 无法可靠调用 lxserver 的 `/api/music/url`。

lxserver 的在线播放依赖已启用的自定义音源。搜索能成功而播放返回 500，通常表示该源没有配置、被禁用或没有返回 URL。只有挂载到 `/server/data`、`/server/cache` 或 `/server/music` 的文件才是服务端本地库；在线搜索仍会访问在线平台或自定义源。

## xiaozhi 模型接入

在小智服务端的 `data/.config.yaml` 中，可以使用其 `DoubaoLLM`、`DeepSeekLLM` 或其他 OpenAI 兼容 LLM。豆包示例：

```yaml
selected_module:
  LLM: DoubaoLLM

LLM:
  DoubaoLLM:
    type: openai
    base_url: https://ark.cn-beijing.volces.com/api/v3
    model_name: 你的方舟模型名或接入点 ID
    api_key: 你的火山方舟 API Key
```

L05C 网关保持相同的模型参数：

```yaml
MODEL_PROVIDER: doubao
MODEL_NAME: 你的方舟模型名或接入点 ID
MODEL_BASE_URL: https://ark.cn-beijing.volces.com/api/v3
MODEL_API_KEY: 你的火山方舟 API Key
```

`MODEL_API_KEY` 有值时优先级高于 `ARK_API_KEY`。`MODEL_BASE_URL` 必须是 OpenAI 兼容的 HTTP 地址；不能填 `ws://192.168.8.1:8000/xiaozhi/v1/`，也不能把 WebSocket 地址当成 HTTP 聊天 API。

## Compose 服务

统一 Compose 包含：

```text
lxserver       :9527
xiaomi-gateway :58092
```

已部署 lxserver 的爱快项目可以只追加网关服务；同一项目内使用 `http://lxserver:9527`。如果网关单独建项目，使用 `http://192.168.8.1:9527`。

首次启动保持 `MI_LISTENER_ENABLED=false`，先完成：

1. lxserver 管理页面登录和音源配置。
2. 小米 token、`MI_DID` 和 `MI_MIOT_DID` 检查。
3. `/v1/music/search` 搜索验证。
4. `/v1/music/resolve` 传入完整 `song_info` 验证。
5. `/v1/ai/answer` 验证模型。
6. 最后启用 `MI_LISTENER_ENABLED=true`。

## 现场验收

```text
GET  http://192.168.8.1:9527/api/status
GET  http://192.168.8.1:58092/healthz
GET  http://192.168.8.1:58092/v1/status
GET  http://192.168.8.1:58092/v1/music/search?q=周杰伦晴天
POST http://192.168.8.1:58092/v1/ai/answer
GET  http://192.168.8.1:58092/v1/mi/devices
```

通过标准：

- lxserver 搜索返回 `items`，且歌曲含 `source`、`id` 和 `_lx_song_info`。
- 网关使用 lxserver 解析到 HTTP(S) MP3 URL。
- L05C 能实际播放 MP3。
- AI 回复通过 MiService `[5,3]` 播报。
- “打开客厅的灯”保持 `native`，由小爱原生米家能力执行。
- 关闭或重启网关后，lxserver 数据目录、MiService token 和配置卷仍保留。

## 相关官方资料

- [LX Music Server GitHub](https://github.com/XCQ0607/lxserver)
- [LX Server API 路由](https://xcq0607.github.io/lxserver/api/routes.html)
- [LX Server 部署文档](https://xcq0607.github.io/lxserver/guide/deployment.html)
- [xiaozhi-esp32-server GitHub](https://github.com/xinnan-tech/xiaozhi-esp32-server)
- [小智自建服务端说明](https://xiaozhi.dev/docs/usage/self-hosted-server/)
