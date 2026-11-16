# 群晖 NAS 部署

目标 NAS：`192.168.8.3`。当前 iKuai 方案也可以直接使用同一 Compose 结构。

## 目录

```text
/volume1/docker/xiaoai-music/
├── xiaomi-gateway/
├── deploy/
└── runtime/
    ├── lxdata/
    ├── lxcache/
    ├── lxmusic/
    └── gateway/
```

## 准备配置

复制并填写：

```text
deploy/xiaomi-gateway.env.example -> xiaomi-gateway/.env
```

lxserver 的管理员密码直接填写在 `deploy/synology/docker-compose.yml` 的环境变量中；真实账号、模型 Key 和 token 不要提交到 Git。

## Container Manager

```bash
docker compose -f /volume1/docker/xiaoai-music/deploy/synology/docker-compose.yml pull
docker compose -f /volume1/docker/xiaoai-music/deploy/synology/docker-compose.yml up -d
```

地址：

```text
lxserver 管理页： http://192.168.8.3:9527
网关健康检查：  http://192.168.8.3:58092/healthz
```

`lxserver` 和网关在同一个 Compose 网络中，网关使用 `http://lxserver:9527`。如果把网关单独部署，改为 `http://192.168.8.3:9527`。

MiService token 放在：

```text
/volume1/docker/xiaoai-music/runtime/gateway/mi.token
```

容器内对应 `/config/mi.token`。首次保持 `MI_LISTENER_ENABLED=false`，完成 `/v1/mi/devices`、`/v1/music/search`、`/v1/ai/answer` 验证后再改为 `true`。

## 音乐源

网关 `MUSIC_SOURCE` 使用 lxserver 源代码：`kw`、`kg`、`tx`、`wy`、`mg`。lxserver 在线播放依赖已启用的自定义音源；搜索成功而解析失败时，先检查 lxserver 管理页面中的音源配置。

## 验收

```bash
curl http://192.168.8.3:9527/api/status
curl http://192.168.8.3:58092/healthz
curl http://192.168.8.3:58092/v1/status
curl 'http://192.168.8.3:58092/v1/music/search?q=周杰伦晴天'
```

AI、设备和米家原生控制验证方式与 iKuai 方案相同。
