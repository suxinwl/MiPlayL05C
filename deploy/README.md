# Docker 部署模板

此目录以通用 Docker Compose 为主，群晖 NAS 模板只是可选示例。服务不依赖固定宿主机 IP；两个容器在 Compose 网络中通过服务名通信。

注意：`http://oo-music:8787` 是容器内部地址，只能由 `xiaomi-gateway` 容器访问；浏览器和局域网设备应访问 Docker 主机的 `http://<主机IP>:8787`，爱快示例为 `http://192.168.8.1:8787`。

- 复制 `oo-music.env.example` 为 `../oo-music/backend/.env`，设置管理员账号和强密码。
- 复制 `xiaomi-gateway.env.example` 为 `../xiaomi-gateway/.env`，再填写小米设备、音乐源和模型配置（真实接入阶段使用）。

通用 Docker 环境执行（从 GHCR 拉取镜像）：

```powershell
docker compose -f E:/AI/XiaoAi_misuc/deploy/docker-compose.yml pull
docker compose -f E:/AI/XiaoAi_misuc/deploy/docker-compose.yml up -d
```

群晖模板见 `deploy/synology/docker-compose.yml` 和 `deploy/synology/README.md`；将其中的宿主路径替换为实际共享文件夹即可。

默认端口：

- `oo-music`: `http://<docker-host>:8787`
- `xiaomi-gateway`: `http://<docker-host>:58092/healthz`

oo-music 当前同时支持 QQ 音乐和网易云音乐。分别在管理页完成扫码绑定；网关通过 `MUSIC_SOURCE=qq|netease` 选择活动源，语音指令本身不需要说平台名称。切换源后重启网关。

首次验证时先用 `MUSIC_SOURCE=qq` 完成搜索和播放地址链路，再切换为 `MUSIC_SOURCE=netease` 验证网易云。匿名或未登录模式只能证明接口可达，不保证返回可播放 URL；会员、地区、版权和歌曲权限由上游服务决定。

如果 oo-music 后台开启了公共 API 鉴权，填写网关配置中的 `OO_MUSIC_CLIENT_ACCOUNT_ID` 和 `OO_MUSIC_CLIENT_ACCESS_KEY`；未开启时保持为空，并确保端口只在可信局域网开放。

网关已经包含 MiService、LLM 和统一监听器代码；首次部署建议保持 `MI_LISTENER_ENABLED=false`，先验证健康检查、设备列表、当前活动源播放地址和模型接口，再开启后台监听。

镜像地址：

```text
ghcr.io/suxinwl/oo-music:latest
ghcr.io/suxinwl/xiaomi-gateway:latest
```

推送到 `main` 后，GitHub Actions 会自动构建并发布这两个镜像到 GHCR；也可以在 Actions 页面手动运行 `Build and publish container images`。

完整的架构、配置、验收和故障排查见 `docs/L05C_DOCKER_PROJECT_PLAN.md`。
