# Docker 部署模板

此目录以通用 Docker Compose 为主，群晖 NAS 模板只是可选示例。服务不依赖固定宿主机 IP；lxserver 和网关在 Compose 网络中通过服务名通信。

注意：`http://lxserver:9527` 是容器内部地址，只能由 `xiaomi-gateway` 容器访问；浏览器和局域网设备应访问 Docker 主机的 `http://<主机IP>:9527`，爱快示例为 `http://192.168.8.1:9527`。

- 复制 `xiaomi-gateway.env.example` 为 `../xiaomi-gateway/.env`，再填写小米设备、音乐源和模型配置（真实接入阶段使用）。

通用 Docker 环境执行（从 GHCR 拉取镜像）：

```powershell
docker compose -f E:/AI/XiaoAi_misuc/deploy/docker-compose.yml pull
docker compose -f E:/AI/XiaoAi_misuc/deploy/docker-compose.yml up -d
```

群晖模板见 `deploy/synology/docker-compose.yml` 和 `deploy/synology/README.md`；将其中的宿主路径替换为实际共享文件夹即可。

默认端口：

- `lxserver`: `http://<docker-host>:9527`
- `xiaomi-gateway`: `http://<docker-host>:58092/healthz`

lxserver 通过原生接口提供在线搜索、播放解析和本地音乐管理。网关通过 `MUSIC_SOURCE=kw|kg|tx|wy|mg` 选择活动源，语音指令本身不需要说平台名称。切换源后重启网关。

首次验证时先用 `MUSIC_SOURCE=kw` 完成搜索和播放地址链路，再按需切换为 `tx` 或 `wy`。搜索成功而播放地址为空时，检查 lxserver 管理页的自定义音源配置；会员、地区、版权和歌曲权限由上游服务决定。

lxserver 如果要求具名用户鉴权，填写 `LXSERVER_USER_NAME` 和对应的 `LXSERVER_USER_TOKEN`；公开局域网部署可使用 `open`，并确保端口只在可信局域网开放。

网关已经包含 MiService、LLM 和统一监听器代码；首次部署建议保持 `MI_LISTENER_ENABLED=false`，先验证健康检查、设备列表、当前活动源播放地址和模型接口，再开启后台监听。

镜像地址：

```text
ghcr.io/suxinwl/xiaomi-gateway:latest
xcq0607/lxserver:latest
```

推送到 `main` 后，GitHub Actions 会自动构建并发布这两个镜像到 GHCR；也可以在 Actions 页面手动运行 `Build and publish container images`。

完整的当前架构、配置、验收和故障排查见 `docs/L05C_LXSERVER_XIAOZHI_PLAN.md`。
