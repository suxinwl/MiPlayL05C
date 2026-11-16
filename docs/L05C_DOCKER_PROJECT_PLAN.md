# 小爱音箱 Play 增强版 L05C Docker 统一网关规划

> 当前音乐后端和 AI 接入以 [L05C + lxserver + xiaozhi 方案](L05C_LXSERVER_XIAOZHI_PLAN.md) 为准；本文中的 oo-music 仅作为历史兼容设计保留。

## 1. 文档定位

本文是小爱音箱 Play 增强版（硬件型号 `L05C`）统一网关的完整实施规划。方案以通用 Docker/Compose 为运行环境，宿主机可以是 NAS、Linux、Windows 或其他能够运行 Docker Engine 的设备；群晖和 iKuai 只是可选的网络部署示例，不是架构前提。

项目目录：`E:\\AI\\XiaoAi_misuc`。

方案目标：

1. 保留小爱原生的米家控制能力，例如“打开客厅的灯”。
2. 通过本地 `oo-music` 提供 QQ 音乐和网易云音乐播放地址。
3. 通过 `MiService` 将新鲜的 MP3 播放地址下发给 L05C。
4. 让用户可选择 DeepSeek、OpenAI/GPT 或豆包回答明确的 AI 问题，并使用 L05C 原生 TTS 播报。
5. 以 Docker Compose 部署两个服务，配置、账号数据库和 Xiaomi token 均可持久化、备份和回滚。

## 2. 范围与边界

### 2.1 纳入范围

- L05C 的 MiNA 文本轮询、意图分类、QQ 音乐搜索和播放。
- L05C 原生 TTS，当前使用 `miot_action` 的 `ttsCommand=[5,3]`。
- DeepSeek、OpenAI/GPT、豆包的 OpenAI 兼容聊天接口。
- `oo-music` 的 QQ 音乐账号管理、扫码登录和实时播放地址解析。
- Docker 镜像、Compose 编排、健康检查、日志和持久化卷。
- 使用 `oo-music` 已有的 QQ/网易云账号池和统一媒体 API，网关只负责选择活动源并消费统一响应。

### 2.2 明确排除

- 不刷 L05C 固件，不替换小爱系统，不植入第三方语音固件。
- 不把斐讯 R1 XiaoZhi 客户端、固件、ADB 或 Opus/WebSocket 协议直接移植到 L05C。R1 项目可作为架构参考，但两者硬件和协议链路不同。
- 不把 `xiaogpt`、`xiaomusic`、`MiGPT` 与本网关同时作为生产监听器；多个程序轮询 MiNA 会重复消费或互相干扰。
- 最终运行链路不依赖 `yt-dlp`、Songloft 或独立网易云 API；网易云功能由 `oo-music` 内置源适配器提供。
- 不承诺绕过 QQ/网易云的版权、地区、会员或登录限制；服务端没有可播放质量时，网关只能播报失败原因。

## 3. 已知事实与待验证事实

### 3.1 已确认

- L05C 的硬件标识为 `L05C`。
- L05C 适合原生 TTS 路径，配置 `SPEAKER_TTS_COMMAND=5,3`。
- 使用 `STREAM_RESPONSE=false`，不依赖连续流式对话和可靠播放状态查询。
- `MiService 3.0.1` 提供 `MiNAService.play_by_url(deviceId, url, 2)`，可作为播放下发接口。
- `oo-music` 当前提供 `/api/search`、`/api/tracks`、`/api/playback`、`/api/lyrics` 和 `/api/mv`。
- 网关已提供 `/healthz`、`/v1/status`、`/v1/route`、`/v1/music/search`、`/v1/music/resolve`、`/v1/music/play`、`/v1/mi/devices` 和 `/v1/ai/answer`。
- 网关测试当前覆盖路由、监听器去重、双平台 source、播放 URL 下发和错误处理，13 项通过；`oo-music` Go 测试也已通过。

### 3.2 必须在目标环境验证

- Xiaomi token 是否有效、`MI_DID` 是否指向实际 L05C，以及 MiService 是否能列出设备。
- QQ 扫码登录后，指定歌曲是否能返回可播放的 MP3 URL；匿名模式只能证明 API 可达。
- L05C 对实际 URL 的播放、停止和音量行为。
- DeepSeek/GPT/豆包 API key、模型名和区域网络是否可用。
- 网关监听开启后，未命中的米家指令是否持续由小爱原生处理。
- 容器重启后，QQ 登录态、SQLite 数据库和 `.mi.token` 是否能恢复。

## 4. 总体架构

```text
小爱音箱 L05C
      │ 小米云 MiNA 对话记录
      ▼
xiaomi-gateway :58092  （唯一 MiNA 监听器）
      ├─ native ───────────────► 不回答、不 mute，交回小爱原生米家能力
      ├─ music ─► oo-music :8787 ─► 新鲜 MP3 URL ─► MiService.play_by_url ─► L05C
      └─ ai ─► DeepSeek / GPT / 豆包 ─► MiService TTS(5,3) ─► L05C

oo-music :8787
      ├─ QQSource
      └─ NeteaseSource
```

两个容器放在 Compose 私有网络 `xiaomi` 中。宿主机只需按需暴露 `8787` 和 `58092`；网关访问音乐服务使用容器名 `http://oo-music:8787`，不依赖宿主机 IP。

### 4.1 职责划分

| 组件 | 职责 | 不负责 |
|---|---|---|
| `oo-music` | QQ/网易云登录、搜索、歌曲详情、实时播放 URL | 监听小爱、调用 LLM、控制米家 |
| `xiaomi-gateway` | MiNA 唯一监听、意图路由、调用音乐服务、调用 LLM、MiService 播放/TTS | 音乐账号登录、替换小爱固件 |
| L05C | 语音唤醒、原生米家执行、MP3 播放、TTS | 运行 Docker 或第三方 API |
| Docker Compose | 网络、卷、重启、健康检查 | 处理 Xiaomi/QQ 业务逻辑 |

## 5. L05C 约束与交互策略

### 5.1 音频与 TTS

- 音乐优先请求 `320mp3`，失败时允许 `oo-music` 按其质量顺序回退到其他 MP3/AAC；避免把 FLAC 作为默认格式。
- 播放 URL 可能带签名和过期时间，必须每次播放前实时请求 `/api/playback`，不长期缓存。
- AI 使用 MiService 的 TTS 命令 `[5,3]`，回答控制在适合语音播报的短中文文本。
- `STREAM_RESPONSE=false`。L05C 不依赖连续对话或可靠播放状态命令。

### 5.2 意图优先级

网关只消费明确属于自己的请求：

1. 明确的原生控制前缀（例如“请打开”“帮我关闭”）优先判为 `native`。
2. 音乐前缀（例如“播放”“暂停”“下一首”）判为 `music`。
3. 明确问答前缀（例如“请问”“解释”“什么是”“为什么”）判为 `ai`。
4. 其他文本判为 `native`，不主动回答，让小爱原生处理。

当前代码中“帮我打开客厅的灯”会走 `native`；“播放周杰伦晴天”会走 `music`；“请用两句话解释量子计算”会走 `ai`。规则是保守的，后续增加前缀必须先补充路由测试，避免抢占米家控制。

### 5.3 单一监听器

`MI_LISTENER_ENABLED=true` 后，只有 `xiaomi-gateway` 轮询 `MiNAService.get_latest_ask`。监听器启动时丢弃已有历史，之后按 `request_id` 去重，最多保留有限数量的已见 ID。原生分支不调用 `mute`、不发送回答，保持小爱原生流程。

## 6. 服务 API 契约

### 6.1 oo-music

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/healthz` | 存活探针 |
| GET | `/api/search?source=qq|netease&q=...&page=1&page_size=20` | 搜索，返回带 `source` 的歌曲项 |
| GET | `/api/tracks?source=qq|netease&ids=...` | 歌曲详情和可用音质 |
| GET | `/api/playback?source=qq|netease&song_id=...&quality=320mp3` | 返回 `available`、`url`、`quality`、`reason` |
| GET | `/api/lyrics?source=qq|netease&song_id=...` | 歌词 |
| GET | `/api/mv?source=qq|netease&song_id=...` | MV 地址（不作为 L05C 音频主链路） |
| `/api/admin/*` | 管理登录、QQ/网易云扫码会话、账号状态和公开 API 鉴权设置 |

网关只依赖搜索和播放两个接口，使用 `Cache-Control: no-store` 的播放结果，并检查返回的 `url` 非空后才调用 MiService。

### 6.2 xiaomi-gateway

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/healthz` | 网关进程存活 |
| GET | `/v1/status` | 非敏感运行配置和凭据是否已配置 |
| POST | `/v1/route` | 调试意图分类，不触碰音箱 |
| GET | `/v1/music/search` | 代理搜索 |
| POST | `/v1/music/resolve` | 获取新鲜播放 URL，不播放 |
| POST | `/v1/music/play` | 获取 URL 后调用 `play_by_url` |
| GET | `/v1/mi/devices` | 检查 Xiaomi token、账号和设备列表 |
| POST | `/v1/ai/answer` | 直接调用选定的 LLM，不播报 |

## 7. Docker 运行设计

### 7.1 默认端口和卷

| 容器 | 容器端口 | 默认宿主端口 | 持久化内容 |
|---|---:|---:|---|
| `oo-music` | 8787 | 8787 | SQLite：QQ 登录态、账号、后台管理员 |
| `xiaomi-gateway` | 58092 | 58092 | `/config/.mi.token` 和运行配置 |

建议只在家庭局域网或反向代理内开放端口，不直接暴露到公网。网关的 `/config` 卷权限应限制为运行用户可读写；`oo-music` 数据卷同样需要备份。

### 7.2 环境变量

`oo-music`：

```dotenv
OO_MUSIC_ADDR=0.0.0.0:8787
OO_MUSIC_DB_PATH=/data/oo-music.db
OO_MUSIC_ADMIN_USERNAME=admin
OO_MUSIC_ADMIN_PASSWORD=请替换为强密码
```

`xiaomi-gateway`：

```dotenv
GATEWAY_HOST=0.0.0.0
GATEWAY_PORT=58092
OO_MUSIC_BASE_URL=http://oo-music:8787
MUSIC_SOURCE=qq
MUSIC_QUALITY=320mp3
MUSIC_ALLOW_FALLBACK=true
OO_MUSIC_CLIENT_ACCOUNT_ID=
OO_MUSIC_CLIENT_ACCESS_KEY=
MI_USER=小米账号
MI_PASS=小米密码或可用登录凭据
MI_DID=音箱设备DID
MI_TOKEN_PATH=/config/.mi.token
SPEAKER_HARDWARE=L05C
SPEAKER_TTS_COMMAND=5,3
STREAM_RESPONSE=false
MI_LISTENER_ENABLED=false
MI_POLL_INTERVAL=1.0
```

模型三选一：

```dotenv
# DeepSeek
MODEL_PROVIDER=deepseek
MODEL_NAME=deepseek-chat
MODEL_BASE_URL=https://api.deepseek.com
MODEL_API_KEY=

# OpenAI/GPT：切换时改成对应模型和 key
# MODEL_PROVIDER=openai
# MODEL_NAME=gpt-4o-mini
# MODEL_BASE_URL=https://api.openai.com/v1
# OPENAI_API_KEY=

# 豆包：使用火山方舟的 OpenAI 兼容端点和模型 ID
# MODEL_PROVIDER=doubao
# MODEL_NAME=ep-xxxxxxxxxxxx
# MODEL_BASE_URL=https://ark.cn-beijing.volces.com/api/v3
# ARK_API_KEY=
```

网关优先读取 `MODEL_API_KEY`，否则按 provider 读取 `DEEPSEEK_API_KEY`、`OPENAI_API_KEY` 或 `ARK_API_KEY`。密钥只放在 `.env`、Docker secrets 或主机密钥管理器，不写入镜像、代码和日志。

### 7.3 启动顺序

1. 复制两个环境模板并填写强密码；先保持 `MI_LISTENER_ENABLED=false`。
2. 生成或准备 `.mi.token`，以只读方式挂载到网关配置卷；如果环境必须首次登录，可先用一次性工具生成 token，再移入生产卷。
3. `docker compose build` 构建两个镜像。
4. `docker compose up -d` 启动服务；Compose 等待 `oo-music` 健康后再启动网关。
5. 先检查 `/healthz`、`/v1/status`、`/v1/mi/devices`。
6. 打开 `oo-music` 管理页分别完成 QQ 和网易云扫码登录；网关只使用当前 `MUSIC_SOURCE` 指定的平台。
7. 配置并测试一个 LLM provider 的 `/v1/ai/answer`。
8. 手工调用 `/v1/music/play` 验证 L05C 播放。
9. 如需切换平台，修改 `MUSIC_SOURCE=qq|netease` 并重启网关；所有手工检查通过后才设置 `MI_LISTENER_ENABLED=true`。

通用 Compose 文件为 `deploy/docker-compose.yml`。默认相对路径来自 `E:\\AI\\XiaoAi_misuc\\deploy`，也可以将目录复制到 Linux/NAS 后把 `build.context` 和 `env_file` 改为目标路径。

## 8. Xiaomi token 与设备初始化

网关不会在 HTTP 进程导入时自动登录 Xiaomi。首次检查 `/v1/mi/devices` 时，`MiServiceController` 才创建会话并加载 `/config/.mi.token`。生产环境建议：

1. 在受控环境完成一次 Xiaomi 登录并生成 token。
2. 确认 token 文件权限只允许网关容器读取。
3. 调用 `/v1/mi/devices`，从返回列表确定 L05C 的 `did`。
4. 将该值写入 `MI_DID`，重启网关。
5. 再调用 `/v1/music/play` 和 TTS/监听器测试。

如果返回登录失败，优先检查 token 是否过期、账号地区、容器时间、DNS 和 `MI_DID`，不要先修改意图规则。

## 9. QQ 音乐与网易云接口

当前第一阶段只使用 `oo-music` 的 QQ 实现。扫码登录态保存在 oo-music SQLite 数据库，搜索返回歌曲 ID，播放接口按权限和音质解析实时 URL。`NO_PLAYABLE_QUALITY`、空结果或业务码错误都可能是未登录、版权、地区或会员限制，不等同于 Docker 网络故障。

当前 `oo-music/backend` 已按统一平台接口提供以下能力：

```text
type MusicSource interface {
    Search(ctx, query, page, pageSize) ([]Track, error)
    Track(ctx, id) (Track, error)
    Playback(ctx, id, quality) (PlaybackURL, error)
    Lyrics(ctx, id) (Lyrics, error)
}

QQSource      -> QQ 账号池、搜索、播放、歌词和 MV
NeteaseSource -> 网易云 Cookie 账号池、搜索、播放、歌词和 MV
```

对外 API 要求 `source=qq|netease`，响应包含实际 `source`。网关通过 `MUSIC_SOURCE` 自动传参并校验响应，用户语音不需要说平台名称。两个平台的账号凭据只保留在 oo-music SQLite 中。

## 10. 验证矩阵与验收门槛

| 验证项 | 命令/证据 | 通过标准 |
|---|---|---|
| 镜像构建 | `docker compose build` | 两个镜像成功构建 |
| 服务存活 | `GET /healthz` | 两个服务均返回 200 |
| 状态配置 | `GET /v1/status` | `speaker_hardware=L05C`、`stream_response=false` |
| 原生路由 | `/v1/route` + “打开客厅的灯” | `intent=native`、`passthrough=true` |
| 音乐路由 | `/v1/route` + “播放周杰伦晴天” | `intent=music` |
| AI 路由 | `/v1/route` + “请解释量子计算” | `intent=ai` |
| MiService | `/v1/mi/devices` | 返回包含 L05C 的设备列表 |
| QQ 搜索 | `/v1/music/search?q=...` | `items` 有歌曲 ID |
| 播放 URL | `/v1/music/resolve` | `available=true`、URL 为 HTTP(S) |
| 音箱播放 | `/v1/music/play` | L05C 实际发声 |
| LLM | `/v1/ai/answer` | 返回简短中文回答 |
| 监听器 | 启用后说三类指令 | music/AI 被处理，native 仍由小爱执行 |
| 重启恢复 | `docker compose restart` | 数据库、token 和配置保持有效 |
| 失败回退 | 断开 QQ/LLM | 网关记录清晰错误，容器不退出循环 |

自动化测试只能证明代码契约，不能替代最后三项真实验收：QQ 登录、L05C 发声、米家灯控。三项都通过后才可把该版本标记为可长期运行。

## 11. 运维、备份与回滚

- 每次升级前备份 `oo-music` SQLite 文件和网关 `.mi.token`；备份文件放在容器卷之外。
- 固定镜像标签，例如 `oo-music:2026-11-xx`、`xiaomi-gateway:2026-11-xx`，避免只使用 `latest`。
- 升级顺序为构建新镜像、停止旧网关、更新 Compose、启动并检查健康，再开启监听器。
- 出现播放异常时先把 `MI_LISTENER_ENABLED=false`，保留 `/v1/*` 手工调试接口；不要同时运行 xiaogpt/xiaomusic。
- 回滚时恢复上一个 Compose 文件和镜像，再挂载同一份数据库/token；若数据结构发生变化，先使用备份副本验证。
- 日志只记录请求类型、上游状态和错误摘要，不记录 API key、密码、token 或完整签名 URL。

## 12. 故障排查顺序

1. `healthz` 失败：查看容器日志、端口占用、镜像启动命令和 Compose 路径。
2. `oo-music` 搜索为空：检查管理员登录、QQ 扫码状态、账号是否过期和公开 API 鉴权开关。
3. 播放无 URL：检查 `song_id`、`quality=320mp3`、QQ 账号权限和返回的 `reason/attempts`。
4. `/v1/mi/devices` 失败：检查 `.mi.token` 是否真的挂载到 `/config/.mi.token`、容器时间和账号凭据。
5. URL 有效但 L05C 不响：确认 `MI_DID`、网络可达、URL 可从小米云访问，并优先换 128/320 MP3；不要先使用 FLAC。
6. AI 失败：确认 provider、模型名、`MODEL_BASE_URL` 是否与所用 API 兼容，且 key 未被宿主环境覆盖。
7. 米家控制被打断：立即关闭监听器，确认没有其他 xiaogpt/xiaomusic/MiGPT 进程，再检查新增路由前缀。

## 13. 阶段路线图

### P0：Docker 骨架（已完成）

- FastAPI 网关、配置模板、健康检查、Dockerfile、Compose。
- `oo-music` 和网关的内部网络、端口和卷约定。
- 基础路由测试、模拟播放测试。

### P1：QQ 到 L05C（代码已完成，现场验证待完成）

- MiService 适配、设备查询、实时 URL 解析和 `play_by_url`。
- 需要真实 QQ 登录、Xiaomi token、`MI_DID` 和 L05C 发声证据。

### P2：AI 与原生控制（代码已完成，现场验证待完成）

- DeepSeek/GPT/豆包的可选 provider。
- 原生米家分支透传、单 MiNA 监听器和重复请求抑制。
- 需要真实 API key 和“打开客厅的灯”现场验证。

### P3：网易云源与网关适配（已完成代码，待真实账号验收）

- oo-music 已实现 `QQSource`、`NeteaseSource`、扫码登录和统一媒体响应。
- 网关已增加 `MUSIC_SOURCE`、source 校验、MP3 质量策略和可选客户端鉴权头。

### P4：稳定化（进行中）

- 更细的权限控制、指标、告警、备份脚本、升级回滚和长时间运行测试。

## 14. 当前代码与文档入口

- 网关：`xiaomi-gateway/`
- 音乐服务：`oo-music/`
- 通用 Compose：`deploy/docker-compose.yml`
- 环境模板：`deploy/oo-music.env.example`、`deploy/xiaomi-gateway.env.example`
- 网关测试：`xiaomi-gateway/tests/`
- 本规划：`docs/L05C_DOCKER_PROJECT_PLAN.md`

群晖路径、`192.168.8.3` 和 iKuai `192.168.8.1` 的映射只放在 `deploy/synology/` 示例中；换成任意 Docker 主机时，只需调整 Compose 的宿主路径和端口映射。
