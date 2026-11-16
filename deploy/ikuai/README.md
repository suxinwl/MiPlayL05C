# 爱快 Docker Compose 部署

此目录适合爱快 Docker 页面导入，Compose 不包含 `build`，使用 GitHub Actions 发布的 GHCR 镜像。爱快使用固定提交标签，避免旧版 Docker 缓存 `latest` 的 OCI index：

```text
ghcr.io/suxinwl/oo-music:60e144a
ghcr.io/suxinwl/xiaomi-gateway:60e144a
```

地址要区分：`http://oo-music:8787` 只供网关容器在 Docker 网络内部访问；电脑浏览器、手机和小爱设备访问管理页或网关时，使用爱快局域网地址 `http://192.168.8.1:8787` 和 `http://192.168.8.1:58092`。

## 项目目录

例如在爱快持久化目录建立：

```text
/mnt/sda1/docker/MiPlayL05C/
├── docker-compose.yml
├── .env
├── oo-music-data/
└── gateway-config/
    └── .mi.token
```

将 `.env.example` 复制为项目目录中的 `.env`，填写管理员密码、小米账号、设备 DID 和模型配置。Compose 会通过 `env_file: ./.env` 读取它；完成的 `.env` 不要提交到 GitHub。

首次部署保持：

```dotenv
MUSIC_SOURCE=qq
MI_LISTENER_ENABLED=false
```

## 命令行部署

在爱快 Docker 终端或 SSH 中执行；旧版环境可将 `docker compose` 替换为 `docker-compose`：

```sh
cd /mnt/sda1/docker/MiPlayL05C
docker compose pull
docker compose --env-file .env up -d
docker compose ps
```

如果 GHCR 包改为私有，先执行 `docker login ghcr.io -u suxinwl`。

## 页面部署

1. 打开爱快 Docker 管理页面并新建 Compose 项目。
2. 上传或粘贴本目录的 `docker-compose.yml`。
3. 在项目目录放置 `.env` 文件；如果页面提供环境变量编辑器，也要确保管理员用户名和密码已设置。
4. 确认工作目录中存在 `oo-music-data`、`gateway-config` 两个目录。
5. 点击“拉取镜像”，再点击“启动”。

## 首次验收

假设爱快地址为 `192.168.8.1`，从局域网电脑执行：

```sh
curl http://192.168.8.1:8787/healthz
curl http://192.168.8.1:58092/healthz
curl http://192.168.8.1:58092/v1/status
curl 'http://192.168.8.1:58092/v1/music/search?q=周杰伦晴天'
```

接着完成 QQ/网易云扫码登录，放置 `gateway-config/.mi.token`，填写 `MI_DID`，验证 `/v1/mi/devices`、`/v1/music/resolve`、`/v1/music/play` 和 `/v1/ai/answer`，最后才设置 `MI_LISTENER_ENABLED=true`。

切换网易云：

```dotenv
MUSIC_SOURCE=netease
```

保存 `.env` 后执行：

```sh
docker compose up -d --force-recreate xiaomi-gateway
```

## 维护

```sh
docker compose logs -f oo-music
docker compose logs -f xiaomi-gateway
docker compose pull
docker compose up -d
docker compose down
```

不要使用 `docker compose down -v`，避免删除 oo-music 数据和网关配置。
