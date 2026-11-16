# Docker + DuckDNS + 8787 HTTPS（Caddy 可选）

Caddy 使用独立的 Compose 项目，不定义、不重建、不依赖原来的 backend 服务：

```text
公网 TCP 8787
  -> Caddy（DuckDNS 插件，DNS-01）
  -> 宿主机 127.0.0.1:18787
  -> 现有 backend 容器 8787

原后端宿主机端口：127.0.0.1:18787
```

- 不修改原后端镜像、业务配置和数据卷
- Caddy 可以单独启动、停止和升级
- Caddy 使用 `network_mode: host`，直接访问宿主机本地端口
- 只有 Caddy 占用宿主机 8787
- 原后端只把宿主机端口从 8787 改为 18787
- 不需要开放 80/443，也不需要宝塔参与 TLS

最终客户端地址：

```text
https://oo-music.duckdns.org:8787
```

## 1. 创建 DuckDNS 子域名

打开 <https://www.duckdns.org/>：

1. 创建一个 DuckDNS 子域名
2. 将 IP 更新为服务器公网 IP
3. 保存页面顶部的 token

## 2. 给原后端让出宿主机 8787

如果原后端使用的是仓库中的 `docker-compose.yml`，在原有 `.env` 中增加：

```dotenv
OO_MUSIC_PORT=18787
```

然后只重建 backend：

```bash
docker compose up -d backend
curl -fsS http://127.0.0.1:18787/healthz
```

原来的后端数据卷、环境变量和容器内端口 `8787` 都不变，只是宿主机访问地址从
`127.0.0.1:8787` 变成 `127.0.0.1:18787`。

如果后端由其他 Compose 文件管理，只调整它的 host port 映射即可，例如：

```yaml
ports:
  - "127.0.0.1:18787:8787"
```

确认 8787 已空闲：

```bash
ss -lntp | grep ':8787'
```

如果仍有宝塔站点、Nginx 或旧容器占用 8787，需要先停用对应服务。

## 3. 准备 Caddy 配置

```bash
cd /path/to/oo-music
cp deploy/duckdns.env.example deploy/duckdns.env
chmod 600 deploy/duckdns.env
```

编辑 `deploy/duckdns.env`：

```dotenv
OO_MUSIC_DUCKDNS_DOMAIN=oo-music.duckdns.org
OO_MUSIC_ACME_EMAIL=admin@example.com
DUCKDNS_TOKEN=你的 DuckDNS token

OO_MUSIC_CADDY_IMAGE=local/oo-music-caddy-duckdns:latest
```

Caddyfile 已直接指定 upstream：`127.0.0.1:18787`，不需要配置 Docker 网络或容器名。

## 4. 构建并启动 Caddy

```bash
docker compose \
  --env-file deploy/duckdns.env \
  -f docker-compose.duckdns.yml \
  build caddy

docker compose \
  --env-file deploy/duckdns.env \
  -f docker-compose.duckdns.yml \
  up -d
```

这个 Compose 文件使用独立项目名 `oo-music-caddy`，只管理 Caddy，不会启动或重建原后端。

首次启动会：

1. 以 host network 启动 Caddy，直接连接宿主机 `127.0.0.1:18787`
2. 使用 DuckDNS TXT 记录完成 DNS-01 验证
3. 申请 Let's Encrypt 证书
4. 在宿主机 8787 提供 HTTPS 并反向代理到原后端

Caddy 后续会自动续期证书。

## 5. 防火墙

云厂商安全组和系统防火墙只开放：

```text
TCP 8787
```

不需要开放：

```text
80
443
18787
```

18787 只绑定宿主机回环地址，用于本机排查，不对外暴露。

## 6. 查看证书申请

```bash
docker compose \
  --env-file deploy/duckdns.env \
  -f docker-compose.duckdns.yml \
  logs -f caddy
```

证书保存在独立 volume：

```text
oo-music-duckdns-data
```

不要在容器运行期间删除该 volume，否则会重新申请证书。

## 7. 验证

```bash
curl -fsS https://oo-music.duckdns.org:8787/healthz
```

或者使用服务器公网 IP 绕过本机 DNS：

```bash
curl --resolve oo-music.duckdns.org:8787:服务器公网IP \
  -fsS https://oo-music.duckdns.org:8787/healthz
```

检查证书：

```bash
openssl s_client \
  -connect oo-music.duckdns.org:8787 \
  -servername oo-music.duckdns.org \
  </dev/null 2>/dev/null |
  openssl x509 -noout -issuer -subject -dates
```

证书应由公开受信任 CA 签发，客户端无需额外安装根证书。

## 8. 发布客户端

GitHub Actions Repository Variable：

```text
OO_MUSIC_API_BASE_URL=https://oo-music.duckdns.org:8787
```

然后重新运行 Client Release。

## 9. 单独升级或停止 Caddy

升级 Caddy 不影响原后端：

```bash
docker compose \
  --env-file deploy/duckdns.env \
  -f docker-compose.duckdns.yml \
  build --pull caddy

docker compose \
  --env-file deploy/duckdns.env \
  -f docker-compose.duckdns.yml \
  up -d
```

停止并移除 Caddy，但保留证书 volume：

```bash
docker compose \
  --env-file deploy/duckdns.env \
  -f docker-compose.duckdns.yml \
  down
```

原后端不会被停止或删除。需要让原后端重新占用宿主机 8787 时，把 `.env` 中的
`OO_MUSIC_PORT` 改回 `8787`，再执行：

```bash
docker compose up -d backend
```

## 常见问题

### Caddy 返回 502 或无法连接 upstream

先在宿主机确认后端可访问：

```bash
curl -fsS http://127.0.0.1:18787/healthz
```

如果失败，检查原后端的端口映射是否为 `127.0.0.1:18787:8787`。Caddy 使用
`network_mode: host`，因此它访问的 `127.0.0.1` 就是宿主机回环地址。

### Caddy 无法申请证书

检查：

- `DUCKDNS_TOKEN` 是否正确
- `OO_MUSIC_DUCKDNS_DOMAIN` 是否包含 `.duckdns.org`
- DuckDNS 子域名 IP 是否指向当前服务器
- 服务器是否能访问 DuckDNS API 和 `223.5.5.5` DNS
- 8787 是否被其他进程占用

### 构建时访问 `sum.golang.org` 超时

Caddy 的 Dockerfile 已默认使用：

```text
GOPROXY=https://goproxy.cn,direct
GOSUMDB=sum.golang.google.cn
```

如果服务器网络仍无法构建，可以在能构建的机器上生成镜像后推送到私有镜像仓库，再修改
`OO_MUSIC_CADDY_IMAGE` 使用该镜像。

### DuckDNS 在国内不可达

先从客户端所在网络确认 DuckDNS 域名解析正常；若域名本身不可达，则不能使用本方案。
