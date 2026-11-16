# xiaomi-gateway

统一的小爱音箱网关原型：只负责一次监听小爱文本，然后把请求分为音乐、AI 和原生米家控制三类。

当前版本提供健康检查、意图分类、QQ/网易云活动源接口和 MiService 包装层；默认不会自动监听小爱，只有设置 `MI_LISTENER_ENABLED=true` 才启动后台监听。

设置 `MI_LISTENER_ENABLED=true` 并挂载有效 `.mi.token`、`MI_DID` 后，FastAPI 生命周期会启动唯一的 MiNA 轮询任务：原生米家指令直接跳过，音乐请求走 `oo-music`，AI 请求走模型并使用 L05C 原生 TTS。

## 路由约定

- `music`：播放、暂停、下一首等音乐请求，交给 `oo-music`/MiService。
- `ai`：明确的 AI 问题，交给 DeepSeek、GPT 或豆包。
- `native`：其他请求原样交还小爱，例如“打开客厅的灯”。

## 本地运行

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
uvicorn app.main:app --host 0.0.0.0 --port 58092
```

健康检查：`GET http://127.0.0.1:58092/healthz`

意图测试：

```powershell
Invoke-RestMethod http://127.0.0.1:58092/v1/route -Method Post -ContentType 'application/json' -Body '{"text":"打开客厅的灯"}'
```

音乐后端验证（网关通过 `MUSIC_SOURCE` 选择 QQ 或网易云，语音本身不需要指定平台）：

```powershell
Invoke-RestMethod 'http://127.0.0.1:58092/v1/music/search?q=周杰伦晴天'
Invoke-RestMethod 'http://127.0.0.1:58092/v1/music/resolve' -Method Post `
  -ContentType 'application/json' -Body '{"song_id":"97773","quality":"320mp3"}'
Invoke-RestMethod 'http://127.0.0.1:58092/v1/mi/devices'
Invoke-RestMethod 'http://127.0.0.1:58092/v1/music/play' -Method Post `
  -ContentType 'application/json' -Body '{"song_id":"97773","quality":"320mp3"}'
```

`/v1/music/resolve` 只负责实时获取播放地址；`/v1/music/play` 会解析新鲜 MP3 URL 后由 MiService 下发给 L05C。默认先请求 320kbps MP3，不可用时尝试 128kbps MP3。
`/v1/mi/devices` 用于检查 MiService token 和设备 DID；`/v1/music/play` 会在解析到新鲜 URL 后直接尝试让 L05C 播放。

`app/services/mi_service.py` 已准备 MiService 3.0.1 的异步包装，但没有在 HTTP 启动时自动登录；正式接入前需要把本地生成的 `.mi.token` 以受保护卷挂载到 `/config/.mi.token`。

模型测试接口：

```powershell
Invoke-RestMethod 'http://127.0.0.1:58092/v1/ai/answer' -Method Post `
  -ContentType 'application/json' -Body '{"text":"请用两句话解释量子计算"}'
```

模型通过 `MODEL_PROVIDER`、`MODEL_NAME`、`MODEL_BASE_URL` 和对应 API Key 配置；当前支持 DeepSeek、OpenAI/GPT 与豆包的 OpenAI 兼容接口。

## Docker

```powershell
docker build -t xiaomi-gateway:local .
docker run --rm -p 58092:58092 xiaomi-gateway:local
```

真实凭据只应通过 Docker 环境变量或受保护的配置卷注入，不要写入代码、镜像或日志。
