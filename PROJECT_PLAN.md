# XiaoAI L05C Docker 统一网关实施计划

完整版规划见 [docs/L05C_DOCKER_PROJECT_PLAN.md](docs/L05C_DOCKER_PROJECT_PLAN.md)。本文件保留项目当前状态和实施摘要；主部署目标是通用 Docker，群晖仅作为可选示例。

## 目标

- 适配小爱音箱 Play 增强版（L05C），不刷机。
- 保留小爱原生米家设备控制，例如“打开客厅的灯”。
- 使用 `oo-music` 作为统一音乐源后端：当前已支持 QQ 音乐和网易云音乐。
- 使用 DeepSeek、GPT 或豆包回答普通问题，并通过小爱原生 TTS 播报。
- 在任意 Docker/Compose 主机运行；群晖 NAS `192.168.8.3` 和 iKuai `192.168.8.1` 只是当前可选环境，所有新文件位于 `E:\AI\XiaoAi_misuc`。

## 最终运行结构

```text
小爱 L05C
    |
    v
xiaomi-gateway（唯一 MiNA 监听器）
    |-- AI 意图 -> DeepSeek / GPT / 豆包 -> L05C 原生 TTS
    |-- 音乐意图 -> oo-music 搜索/解析 -> MiService 播放 URL
    `-- 其他意图 -> 不拦截，交给小爱原生米家控制

oo-music（Go，端口 8787）
    |-- QQ 音乐源
    `-- 网易云音乐源
```

不纳入最终运行链路：独立网易云 API、yt-dlp、Songloft、xiaomusic、MiGPT、斐讯 R1 客户端。

## 目录约定

```text
E:\AI\XiaoAi_misuc\
|-- oo-music\              # 现有 QQ 音乐 Go 后端/客户端
|-- xiaomi-gateway\        # 新增统一监听、意图路由、AI 和 MiService 适配
|-- deploy\                 # 通用和群晖 Docker 部署文件、环境变量模板
|-- docs\                   # 接入、测试、故障排查记录
`-- PROJECT_PLAN.md
```

## 阶段

### P0：骨架与健康检查

- 建立 `xiaomi-gateway` Python 服务。
- 增加配置校验、`/healthz`、结构化日志和 Dockerfile。
- 添加模型 provider 配置：DeepSeek、OpenAI/GPT、豆包。
- 添加音乐后端 URL 配置，暂时只调用 `oo-music` 现有 API。

### P1：QQ 音乐到 L05C

- 用 `MiService` 获取小米账号设备信息。
- 监听 MiNA 对话，仅对音乐/AI触发词处理。
- 请求 `oo-music /api/search` 和 `/api/playback`。
- 获取新鲜播放 URL 后调用 L05C 的 `play_by_url`。
- L05C 统一使用 MP3，AI 使用原生 TTS，关闭流式连续对话。

### P2：AI 对话

- 复用 xiaogpt 的 provider 约定，但由网关统一监听，避免两个进程抢消息。
- 普通米家控制请求必须透传，不调用 `mute`，例如打开灯、关闭空调。
- AI/音乐请求确认命中后才打断原始小爱回复。

### P3：网易云源与双平台接口（已完成）

- `oo-music` 已提供 QQ/网易云账号池、扫码登录和统一 `/api/*` 媒体接口。
- 所有媒体请求使用 `source=qq|netease`，网关通过 `MUSIC_SOURCE` 隐藏平台选择。
- 保持统一搜索、歌曲详情、播放地址、歌词和 MV 响应。
- 保留现有 QQ API 兼容性。

### P4：Docker 部署与验收（群晖为可选示例）

- `oo-music` 默认映射为宿主机 `8787:8787`，监听 `0.0.0.0:8787`。
- `xiaomi-gateway` 默认映射为宿主机 `58092:58092`，使用独立配置卷和持久化 `.mi.token`。
- 在任意 Docker 主机验证 AI、QQ/网易云播放、普通米家控制、重启恢复和错误透传。
- `deploy/synology/` 仅保留 `/volume1` 路径和 `192.168.8.3` 的可选示例。

## L05C 约束

- `hardware=L05C`。
- 使用 `use_command`/原生 TTS 路径。
- `stream=false`，不依赖播放状态查询和连续对话。
- 优先播放 MP3，避免 FLAC。
- 音频 URL 每次播放时重新获取，不长期缓存带签名的直链。

## 安全边界

- 小米账号、QQ 音乐凭据、模型 API Key 只放在 `.env` 或 Docker secret，不提交 Git。
- `oo-music` 和网关只暴露在家庭局域网，后台管理端设置强密码。
- 未识别的语音不被网关消费，继续由小爱原生处理。

## 当前进度（2026-11-08）

- 已建立 `xiaomi-gateway` FastAPI 安全骨架：`/healthz`、`/v1/route`、`/v1/music/search`、`/v1/music/resolve`。
- 已实现并验证基础意图分类：米家控制透传、音乐指令、明确 AI 指令。
- 已建立 `deploy/docker-compose.yml`，包含 `oo-music` 和 `xiaomi-gateway` 两个容器。
- 已将 `oo-music` Compose 的默认宿主机端口改为局域网可访问的 `8787:8787`。
- `oo-music` Go 后端现有测试通过。
- 网关已加入 MiService 3.0.1 异步包装、OpenAI 兼容模型服务（DeepSeek/GPT/豆包）和 QQ/网易云播放地址解析接口。
- 网关已通过 FastAPI TestClient 验证健康检查、原生米家透传、音乐和 AI 意图分类。
- 已增加端到端模拟测试：验证 `oo-music` 返回播放 URL 后，网关调用 MiService 播放接口；网关测试当前 13 项通过，覆盖 QQ/网易云 source 校验和 MP3 降级。
- 网关已增加 `/v1/mi/devices`（token/设备检查）和 `/v1/music/play`（实时解析 oo-music URL 后下发 L05C）接口；真实调用仍需挂载 `.mi.token` 和配置 DID。
- 网关已加入可选的单一 MiNA 后台监听器：仅处理音乐/AI 前缀，未命中的米家指令保持原生透传；通过 `MI_LISTENER_ENABLED=true` 启用。
- 已增加通用 Docker Compose 模板、两个持久化卷和 `oo-music` 健康依赖；网关 Dockerfile 已增加 `/healthz` 健康检查。
- `docker compose config --quiet` 已用模板占位环境变量验证通过；真实容器启动仍需要用户创建两个 `.env` 文件和提供凭据。
- 已启动过本地 `oo-music` 临时实例并验证 `GET /healthz` 返回 200、QQ API 请求可达；匿名 QQ 会话搜索结果为空，固定歌曲的播放解析返回 `NO_PLAYABLE_QUALITY`，说明第一阶段要继续用 QQ 扫码/账号登录后再验证真实 MP3 播放地址。
- 尚未挂载真实 Xiaomi token、启动 MiService 后台监听、调用模型 API 或完成 L05C 实际发声；QQ/网易云真实账号链路仍待现场验收。
