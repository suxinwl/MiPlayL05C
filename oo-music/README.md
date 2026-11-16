# oo-music

`oo-music` 是一个用 Go 实现的 QQ 音乐网页接口工具包。当前内核只移植
[numb747/qq-music-api-Reverse](https://github.com/numb747/qq-music-api-Reverse)
的实现，不包含另外三个项目的接口或处理逻辑。

特点：

- 直连腾讯 QQ 音乐网页接口 `https://u6.y.qq.com/cgi-bin/musics.fcg`，不经过第三方 API 服务。
- 在 Go 进程内运行内嵌的 VMP 签名逻辑，不依赖 Node.js。
- 统一完成 VMP 签名、请求 AES-GCM 加密、响应掩码解包和 JSON 解析。
- 支持匿名模式和用户自有登录态。
- 支持单接口调用、批量接口调用，以及常用的搜索、歌曲、歌词、歌单、用户、播放地址和官方体验卡方法。

## 仓库结构

```text
oo-music/
├── backend/                 # Go SDK、Web API 和后台账号服务
│   ├── cmd/server/          # Web 服务入口
│   ├── internal/            # 账号池、管理 API、扫码登录等内部包
│   ├── examples/            # 搜索和完整播放流程示例
│   ├── Dockerfile
│   └── .env.example
├── admin-web/               # React 管理后台
├── apps/desktop/            # Flutter macOS / Windows / Android 客户端
├── docker-compose.yml
└── .github/workflows/       # GitHub Actions
```

所有 Go 命令默认在 `backend/` 目录执行。

## 环境要求

- Go 1.26.0 或更高版本。
- 可访问 `u6.y.qq.com` 的网络环境。
- 可选：Docker 和 Docker Compose，用于容器化运行后端。

## 接入

模块路径为：

```text
github.com/rankgice/oo-music
```

如果尚未发布到远端仓库，可以在调用方项目的 `go.mod` 中增加本地替换：

```go
require github.com/rankgice/oo-music v0.0.0

replace github.com/rankgice/oo-music => /path/to/oo-music/backend
```

## 创建客户端

匿名模式：

```go
package main

import (
	"context"
	"fmt"
	"log"

	oomusic "github.com/rankgice/oo-music"
)

func main() {
	client, err := oomusic.NewClient()
	if err != nil {
		log.Fatal(err)
	}

	result, err := client.SearchSongs(context.Background(), "周杰伦", 1, 10)
	if err != nil {
		log.Fatal(err)
	}
	if result.Code != 0 {
		log.Fatalf("QQ 音乐业务错误码: %d, data: %s", result.Code, result.Data)
	}

	fmt.Println(string(result.Data))
}
```

登录态模式：

```go
client, err := oomusic.NewClient(
	oomusic.WithCredentials(uin, qmKeyst),
	oomusic.WithRequestTimeout(20*time.Second),
)
if err != nil {
	log.Fatal(err)
}

fmt.Println("已配置登录态:", client.IsLoggedIn())
```

QQ 音乐的 `uin`、`qm_keyst` 和网易云音乐的账号 ID、Cookie 必须来自使用者自己的账号。
后端管理台提供 QQ 扫码授权、网易云扫码授权和手动凭据录入，不接入第三方登录服务，也不会
内置或共享账号凭据。不要把凭据提交到代码仓库。

## 调用任意模块

`CallQQ` 暴露了与上游 `callQQ(module, method, param)` 等价的通用入口：

```go
result, err := client.CallQQ(
	context.Background(),
	"music.search.SearchCgiService",
	"DoSearchForQQMusicDesktop",
	map[string]any{
		"query":        "周杰伦",
		"page_num":     1,
		"num_per_page": 10,
		"search_type":  0,
		"remoteplace":  "yqq.yqq.yqq",
	},
)
```

`CallBatch` 可以在一个加密请求中调用多个模块：

```go
batch, err := client.CallBatch(context.Background(), map[string]oomusic.CallRequest{
	"req_1": {Module: "music.trackInfo.UniformRuleCtrl", Method: "CgiGetTrackInfo", Param: map[string]any{"ids": []int64{102321278}, "types": []int{0}}},
	"req_2": {Module: "music.musichallSong.PlayLyricInfo", Method: "GetPlayLyricInfo", Param: map[string]any{"songMID": "000lXvdX0uOg8F"}},
})
```

`CallResult.Code` 是单个 CGI 的业务状态码。顶层请求成功不代表业务一定成功，调用方应同时检查
`err`、`result.Code` 和实际返回的数据。

## 公开方法

| 分类 | 方法 | 说明 |
| --- | --- | --- |
| 客户端 | `NewClient` | 创建并发安全客户端；默认使用匿名模式。 |
| 配置 | `WithCredentials` | 配置用户自有 `uin`、`qm_keyst`。 |
| 配置 | `WithHTTPClient` | 使用自定义 `http.Client`。 |
| 配置 | `WithEndpoint` | 修改腾讯官方基础地址，主要用于测试或边缘节点。 |
| 配置 | `WithUserAgent` | 修改 HTTP 和签名环境使用的 User-Agent。 |
| 配置 | `WithRequestTimeout` | 设置默认 HTTP 超时。 |
| 状态 | `IsLoggedIn` | 判断是否同时提供了 UIN 和 qm_keyst。 |
| 通用 | `CallQQ` | 调用任意单个 QQ 音乐 CGI 模块方法。 |
| 通用 | `CallBatch` | 批量调用多个 CGI 模块方法。 |
| 搜索 | `Search` | 搜索歌曲、专辑、MV、歌词或用户。 |
| 搜索 | `SearchSongs` | 固定歌曲类型的便捷搜索。 |
| 搜索 | `GetHotKeys` | 获取搜索热词。 |
| 歌曲 | `GetTrackInfo` | 获取歌曲元数据和音质大小信息。 |
| 播放 | `ResolvePlaybackURL` | 请求指定歌曲 MID、文件名和音质的播放路径。 |
| 播放 | `ResolvePlayableBySong` | 查询歌曲元数据并按音质顺序寻找可播放路径。 |
| 播放 | `BuildFilename` | 根据 `song.vs[0]` 和音质构造播放文件名。 |
| 歌词 | `GetLyric` | 获取并解码歌词、翻译和罗马音。 |
| 歌单 | `GetPlaylistDetail` | 获取歌单元数据及歌曲区间。 |
| 歌单 | `IsPlaylistFav` | 查询登录账号是否收藏指定歌单。 |
| 用户 | `GetVipStatus` | 查询账号 VIP 状态。 |
| 体验卡 | `ParseExperienceCardLink` | 从 QQ 音乐官方体验卡链接提取 cardid、ADTAG 和分享文案。 |
| 体验卡 | `CheckExperienceCard` | 查询官方体验卡余量、拥有者和领取名单，不执行领取。 |
| 体验卡 | `GetExperienceCardEligibility` | 只读检查当前账号会员状态、重复领取和余量。 |
| 体验卡 | `ClaimExperienceCard` | 对当前 Client 的单个账号显式领取体验卡。 |
| 体验卡 | `ClaimExperienceCardByLink` | 直接传入官方体验卡链接并执行一次显式领取。 |
| 用户 | `GetUserBaseInfo` | 查询账号基础资料。 |
| 用户 | `GetFavorList` | 查询账号收藏列表。 |
| 用户 | `GetChargeAccount` | 查询官方计费账户状态。 |
| 支付 | `GetOfficialVipEntry` | 返回腾讯官方 VIP 门户入口，不创建订单。 |

## 官方体验卡领取

体验卡领取只调用 QQ 音乐官方的 `music.vip.VipFreeCardSvr`，不会访问或提交登录凭据给
`h.m4a.cn` 等聚合页。`uin` 和 `qm_keyst` 可以由管理台通过腾讯官方扫码授权写入数据库。

```go
client, err := oomusic.NewClient(oomusic.WithCredentials(uin, qmKeyst))
if err != nil {
	log.Fatal(err)
}

// 可直接传 QQ 官方体验卡页面 URL，也可传单独的 cardid。
request, err := oomusic.ParseExperienceCardLink(cardURL)
if err != nil {
	log.Fatal(err)
}

eligibility, err := client.GetExperienceCardEligibility(ctx, request)
if err != nil {
	log.Fatal(err)
}
if !eligibility.Eligible {
	log.Printf("当前账号不可领取: VIP=%v 已领取=%v 已领完=%v",
		eligibility.VIPActive, eligibility.AlreadyClaimed, eligibility.Exhausted)
	return
}

result, err := client.ClaimExperienceCard(ctx, request)
if err != nil {
	log.Fatal(err)
}
fmt.Println("领取成功:", result.Card.CardID)
```

也可以使用便捷方法：

```go
result, err := client.ClaimExperienceCardByLink(ctx, cardURL)
```

`ClaimExperienceCard` 会先检查当前账号是否仍有有效会员、该卡领取名单中是否已有当前 UIN、
卡片是否已经领完，再决定是否调用官方 `GetCard`。它只操作当前 Client 的一个账号，不会遍历
账号池或自动轮换账号。已知的 `1000`、`100205`、`100206`、`100210`、`100211` 业务码分别映射为
稳定的 `errors.Is` 错误，可在 UI 中显示明确原因。实际领取仍受腾讯活动规则约束，只有非会员账号
且当月仍有领取资格时才可能成功。

所有公开类型、函数和方法都有中文 GoDoc 注释，可用下面的命令查看完整 API：

```bash
go doc -all .
```

## 协议实现范围

- 请求体由 `comm` 和 `req_N` 组成，先计算 VMP `sign`，再以 AES-GCM 加密。
- 请求线上格式为 `base64(nonce || ciphertext || tag)`。
- `g_tk` 使用 `qm_keyst` 的 `hash33` 计算；匿名模式下为 `5381`。
- 响应体不是 AES-GCM；当前协议使用固定 21 字节掩码做循环异或，再得到 JSON 明文。
- 实现只使用腾讯官方 `musics.fcg` 接口，不代理或转发第三方服务。

## 权益与安全边界

- 管理台实现 QQ 与网易云的扫码/手动授权链路；不实现 Cookie 窃取、绕过验证或凭据共享。
- 不实现 VIP、版权、地区或付费内容的绕过。
- 播放接口只返回服务端针对当前账号和当前参数给出的结果；无权限时 `PURL` 可能为空。
- SDK 不创建支付订单，也不确认支付结果；充值入口指向腾讯官方米大师页面。
- SDK 的体验卡方法只调用腾讯官方接口，并限制为当前 Client 的单个显式账号；后端账号池会在所有可用账号均非 VIP 时实时获取最新官方体验卡链接，按账号顺序尝试领取，并在首个成功后停止。
- 请遵守 QQ 音乐服务条款、版权要求及当地法律，仅处理你有权访问的内容。

## 示例

- `examples/search`：最小化匿名搜索示例，不读取固定账号环境变量。
- `examples/flow`：完整歌曲流程，依次搜索歌曲、查询详情和音质、获取播放 URL、歌词以及关联 MV，并可生成同时播放音频和 MV 的 HTML 播放器。

完整 Demo 运行方式：

```bash
cd /path/to/oo-music/backend
go run ./examples/flow -player /private/tmp/qqmusic-demo.html -- 周杰伦 晴天
```

示例默认使用匿名模式，搜索和媒体权限可能受到服务端限制。Web 后端和后台管理台使用的 QQ
音乐账号只存储在 SQLite 中；需要登录态时请通过管理台扫码绑定或手动更新账号。详细参数见
`examples/flow/README.md`。

## macOS / Windows / Android 客户端

仓库内包含一个 Flutter macOS / Windows / Android 客户端（`apps/desktop`）和一个本地 Go Web 服务。
客户端只访问 Web API，不保存 QQ 音乐的 `qm_keyst` 或网易云 Cookie。当前基础版支持：

- 左上角切换 QQ 音乐 / 网易云音乐，两个平台分别保存当前账号，无账号时允许匿名切换。
- 按当前平台搜索歌曲并展示封面、歌手、专辑、时长和可播放 MV 标记。
- 搜索、歌曲详情、歌词、MV 和播放使用歌曲/请求平台的服务端账号池；VIP 播放优先使用池内
  可用 VIP 账号。
- 当前账户资料和远程歌单始终使用客户端当前绑定的平台账号，不会切换为共享媒体账号。
- 搜索结果、混合平台本地歌单和当前播放器均可下载歌曲到系统下载目录。
- 点击歌曲旁的 MV 图标可在应用内播放关联 MV。
- 展示歌词、翻译和罗马音，并根据播放进度高亮和滚动。
- 支持 macOS AppKit / Windows Win32 / Android 系统悬浮窗桌面歌词，可显示原文与翻译。
- Android 支持移动端布局、后台播放/系统媒体通知、完整歌词页、MV 和 SAF 文件保存；
  Android 13 及以上首次启动会请求通知权限，悬浮歌词首次使用时需要授予“显示在其他应用上层”权限。
- 播放失败时仍独立展示歌词。音乐业务 API 鉴权受管理后台开关控制；账号资料与远程歌单
  始终需要客户端授权，管理 API 使用管理员 Bearer 鉴权。

### 1. 启动 Web 后端

```bash
cd /path/to/oo-music/backend
cp .env.example .env
# 首次启动前编辑 .env，填写管理员初始账号
go run ./cmd/server
```

服务启动时自动读取当前目录下的 `.env`，只向 Go 进程注入变量，不会修改 shell 环境。已有的
进程环境变量优先于 `.env`；也可以通过 `OO_MUSIC_ENV_FILE` 指定其他配置文件。默认监听
`http://127.0.0.1:8787`。公共媒体接口按请求中的 `source=qq|netease` 从对应平台账号池选择上游账号；
账户资料和远程歌单等有账户归属的接口始终使用客户端绑定的账号；
数据库为空时以匿名模式运行。服务不会从环境变量导入音乐账号登录态。可以通过管理台扫码或手动绑定账号，或通过
`OO_MUSIC_ADDR` 修改监听地址。

#### Docker Compose 启动

仓库根目录提供了 `docker-compose.yml` 和多阶段 `backend/Dockerfile`。镜像会先构建
`admin-web`，再把 React 静态文件与 Go 后端一起放入运行镜像；同一个 `8787` 端口同时提供
管理网页和 API。容器内使用非 root 用户运行，SQLite 数据保存在命名卷 `oo-music-data` 中，
Compose 默认映射到宿主机的 `127.0.0.1:8787`。

```bash
cd /path/to/oo-music
cp backend/.env.example backend/.env
# 编辑 backend/.env，至少设置初始管理员用户名和密码
docker compose up -d --build
docker compose logs -f backend
```

健康检查使用 `GET /healthz`，该接口只检查 HTTP 服务是否存活，不会查询账号状态，也不会触发
体验卡领取。停止服务使用 `docker compose down`；SQLite 数据在命名卷中，普通 `down` 不会删除。
需要同时删除数据时应显式执行 `docker compose down -v`。

无自有域名、仅开放 8787 端口时，使用 Docker + DuckDNS + Caddy 的自动 HTTPS 方案：
[`docs/docker-duckdns-8787.md`](docs/docker-duckdns-8787.md)。Caddy 使用独立 Compose 项目，
可以单独启停，不会定义或重建原 backend 服务。

`.env`、`backend/.env` 等运行时配置文件不会被打包进镜像。镜像只包含程序、React 静态文件和
Dockerfile 中的非敏感默认值；Compose 启动时再通过 `env_file` 注入配置。默认读取
`backend/.env`，也可以指定其他文件：

```bash
OO_MUSIC_ENV_FILE=/path/to/production.env docker compose up -d
```

如需临时覆盖某个配置，可在 Compose override 文件的 `environment` 中设置同名变量，例如：

```yaml
services:
  backend:
    environment:
      OO_MUSIC_ADMIN_USERNAME: ${ADMIN_USERNAME}
      OO_MUSIC_ADMIN_PASSWORD: ${ADMIN_PASSWORD}
```

`environment` 中的值会覆盖 `env_file` 中的同名值。Compose 根目录的 `.env` 主要用于变量插值，
并不等同于容器配置；普通 `docker compose up` 也不会自动把所有 shell 环境变量传入容器。

首次启动时，如果 `admin_users` 表没有任何记录，服务会使用
`OO_MUSIC_ADMIN_USERNAME` 和 `OO_MUSIC_ADMIN_PASSWORD` 创建初始后台管理员。判断条件是
整张表为空，而不是“配置的用户名不存在”；因此一旦有过管理员，修改 `.env` 不会覆盖或补建
账号，后续管理员请在管理台增删。管理员密码只保存带随机盐的 PBKDF2-SHA256 摘要。

后台管理 API 除 `POST /api/admin/login` 外均要求
`Authorization: Bearer <token>`，会话默认有效 12 小时，后端重启后需重新登录。管理员相关配置：

| 环境变量 | 说明 |
| --- | --- |
| `OO_MUSIC_ADMIN_USERNAME` | 管理员表为空时创建的初始管理员用户名 |
| `OO_MUSIC_ADMIN_PASSWORD` | 初始管理员密码，至少 8 个字符 |
| `OO_MUSIC_ADMIN_SESSION_TTL` | 管理登录有效期，默认 `12h` |
| `OO_MUSIC_ADMIN_ALLOWED_ORIGINS` | 允许跨域调用管理 API 的前端来源，逗号分隔 |

账号会保存到 SQLite 数据库，默认路径为 `data/oo-music.db`，可通过 `OO_MUSIC_DB_PATH` 修改。
账号表通过 `account_type` 区分 `qq` 和 `netease`，统一保存平台账号 ID 与 `credential`：
QQ 音乐的 `credential` 是 `qm_keyst`，网易云音乐的 `credential` 是完整 Cookie。
数据库驱动是 `modernc.org/sqlite`，不依赖 cgo。音乐账号只能通过管理台或客户端扫码/手动绑定写入，
不会从环境变量导入；删除账号后重启也不会自动恢复。数据库包含
登录凭据，服务会尝试将文件权限设置为 `0600`，不能提交到代码仓库或分享给他人。

> **升级注意：本版本不迁移旧账号或旧客户端歌单数据。** 当前结构正常时数据会保留；
> 旧版或未知数据库结构会在启动时清空对应音乐业务表并重建。确需旧数据时请先自行备份。

后端会按平台账号缓存并复用客户端，仅在账号凭据变化时重建实例。QQ 音乐与网易云音乐都接入搜索、
歌曲详情、播放、歌词、MV、远程歌单、登录态检测和会员状态；网易云音乐还会按授权到期时间尝试刷新
会话并补充会员权益。当前账号按平台隔离，会员到期后会更新数据库状态，并按以下顺序切换账号：

媒体请求与账户归属请求使用不同的账号作用域：搜索、歌曲详情、播放、歌词和 MV 从服务端平台号池
选择共享账号；账户资料、远程歌单等请求始终使用客户端当前绑定账号。播放请求要求使用可用 VIP 时，
如果号池没有 VIP，会先尝试为号池候选账号领取会员，而不是给客户端当前账号领取。

1. 有效会员等级从高到低；
2. 同一等级下会员到期时间从晚到早；
3. 仍相同时按数据库账号 ID 升序。

等级映射为：超级会员 > 高级会员 > VIP > 普通用户。会员等级只用于账号选择，单曲能否播放仍以
QQ 音乐实际返回的播放地址为准。

如果所有可用账号都不是 VIP，后端会实时请求 `https://h.m4a.cn/` 的 QQ 音乐领取列表，提取其中
最新的官方 `y.qq.com/...cardid=...` 链接，再通过 QQ 音乐官方接口检查资格并领取。该流程不需要
固定配置某一张有时效的体验卡链接；每次领取尝试都会重新获取列表，并按时间倒序去重后依次验证。
后端按数据库账号顺序尝试，任一账号领取成功即停止并切换到该账号；失败后默认冷却 1 小时，避免
频繁请求。`OO_MUSIC_EXPERIENCE_CARD_URLS` 仍可作为额外的静态备用链接，但不是必需的。只对
数据库内已有登录态且 QQ 音乐确认可领取的账号调用官方接口，是否成功仍受活动库存、当月资格和
腾讯规则限制。

网易云音乐使用相同策略：只有数据库内没有任何有效黑胶 VIP 账号时，才会从 `https://h.m4a.cn/`
的网易云列表获取最新邀请，依次经过站点短链、网易云官方邀请详情和
`/api/vipactivity/app/vip/invitation/accept` 领取。领取前会先查询账号 VIP 状态，已有会员时不会
消耗邀请；首个账号领取成功后立即停止，默认冷却 1 小时。风控拒绝（例如业务码 `12208`）时不会
自动切换账号反复尝试。

后端每天默认在 `11:00`（`Asia/Shanghai`）检查数据库内所有账号的登录态。QQ 音乐只做状态检测：
只有明确返回业务码 `1000` 才标记为登录失效并触发邮件；网络错误、超时或未知业务码只记录日志，
不会误报过期。网易云音乐除状态检测外，会在授权到期前 24 小时或到期时间未知时尝试调用
`/api/login/token/refresh` 续期；续期失败后仍会复核登录态，只有明确失效才标记过期。已经标记
过期的网易云音乐账号会在下一次定时任务中直接跳过，避免反复请求。
状态自检完成后会执行一次平台会员补充：确保最多保留一个有效 QQ 音乐会员账号和一个有效网易云
音乐会员账号；已经存在有效会员时不会发起新的领取。
定时任务和 SMTP 均通过 `.env` 配置：

| 环境变量 | 说明 |
| --- | --- |
| `OO_MUSIC_LOGIN_CHECK_TIME` | 每日自检时间，默认 `11:00` |
| `OO_MUSIC_LOGIN_CHECK_TIMEZONE` | 自检时区，默认 `Asia/Shanghai` |
| `OO_MUSIC_EXPERIENCE_CARD_URLS` | 可选的额外官方体验卡备用链接；通常无需配置 |
| `OO_MUSIC_SMTP_HOST` | SMTP 服务器，例如 `smtp.qq.com` |
| `OO_MUSIC_SMTP_PORT` | SMTP 端口；465 配 `implicit`，587 配 `starttls` |
| `OO_MUSIC_SMTP_TLS_MODE` | `auto`、`starttls`、`implicit` 或 `none` |
| `OO_MUSIC_SMTP_USERNAME` | SMTP 登录账号 |
| `OO_MUSIC_SMTP_PASSWORD` | SMTP 密码或授权码，不要提交到仓库 |
| `OO_MUSIC_MAIL_FROM` | 发件人地址 |
| `OO_MUSIC_MAIL_TO` | 收件人地址；示例配置为 `209192670@qq.com` |

收件地址只从配置读取，不存在于 Go 代码中。SMTP 未配置时，每日自检仍会执行，但会在发现登录态
失效时记录“未配置邮件通知”的警告；不会记录 Cookie、`qm_keyst` 或 SMTP 密码。

### 2. 启动 React 管理后台

```bash
cd /path/to/oo-music/admin-web
npm install
npm run dev
```

浏览器打开 `http://127.0.0.1:5173`，使用 `backend/.env` 中配置的初始管理员登录。开发服务器会把
`/api` 代理到 `http://127.0.0.1:8787`。生产构建使用：

```bash
npm run build
```

管理台支持管理员增删、QQ 音乐/网易云音乐账号列表、两类扫码授权、手动添加账号、手动更新
`qm_keyst` 或网易云 Cookie、检测/续期状态和删除绑定账号。列表与 API 响应只会返回脱敏账号 ID，
不会返回完整的 `qm_keyst`、Cookie 或管理员密码摘要。扫码成功后的凭据只写入服务端 SQLite，
不会回传浏览器。

管理 API：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `POST` | `/api/admin/login` | 管理员登录，返回 Bearer token |
| `POST` | `/api/admin/logout` | 注销当前会话 |
| `GET` | `/api/admin/me` | 当前管理员和会话到期时间 |
| `GET` | `/api/admin/users` | 管理员列表 |
| `POST` | `/api/admin/users` | 添加管理员 |
| `DELETE` | `/api/admin/users/{id}` | 删除管理员，不能删除自己或最后一个管理员 |
| `GET` | `/api/admin/accounts` | 绑定音乐账号列表 |
| `POST` | `/api/admin/accounts` | 手动添加 QQ 音乐或网易云音乐账号 |
| `PATCH` | `/api/admin/accounts/{id}/credential` | 按账号类型更新 `qm_keyst` 或网易云 Cookie |
| `POST` | `/api/admin/accounts/{id}/refresh` | 检测登录态；网易云音乐账号按到期时间尝试续期 |
| `DELETE` | `/api/admin/accounts/{id}` | 删除绑定账号 |
| `POST` | `/api/admin/qr-sessions?type=qq\|netease` | 创建 QQ 或网易云扫码授权会话 |
| `GET` | `/api/admin/qr-sessions/{id}` | 轮询扫码状态并保存成功账号 |
| `GET` | `/api/admin/qr-sessions/{id}/image` | 获取二维码 PNG |
| `DELETE` | `/api/admin/qr-sessions/{id}` | 取消扫码会话 |

客户端账号和扫码接口：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `POST` | `/api/client/login/sessions?source=qq\|netease` | 创建扫码会话 |
| `GET` | `/api/client/login/sessions/{id}?source=qq\|netease` | 轮询扫码状态 |
| `GET` | `/api/client/login/sessions/{id}/image?source=qq\|netease` | 获取二维码 PNG |
| `DELETE` | `/api/client/login/sessions/{id}?source=qq\|netease` | 取消扫码会话 |
| `GET` | `/api/client/account?source=qq\|netease` | 查询当前授权账号资料 |
| `GET` | `/api/client/playlists?source=qq\|netease` | 查询当前授权账号的远程歌单 |

所有歌曲业务接口都必须显式提供 `source=qq|netease`，缺失或未知值返回 `400`：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/api/search?source=qq&q=周杰伦&page=1&page_size=20` | 搜索歌曲 |
| `GET` | `/api/tracks?source=netease&ids=186016` | 查询歌曲详情和可用音质 |
| `GET` | `/api/playback?source=netease&song_id=186016&quality=320mp3` | 查询播放地址并按音质回退 |
| `GET` | `/api/lyrics?source=qq&song_id=97773&mid=0039MnYb0qxYhV` | 查询歌词、翻译和罗马音 |
| `GET` | `/api/mv?source=netease&song_id=186016` | 查询歌曲关联 MV 的元数据和播放地址 |

响应中的歌曲、播放、歌词、MV 和歌单都包含 `source` 字段；QQ 的 `mid`、`albumMid` 等字段继续保留，
网易云不适用的字段为空。受保护接口使用 `X-OO-Music-Source`、`X-OO-Music-Account-ID` 和
`X-OO-Music-Access-Key` 三个请求头。

### 3. 运行 macOS 客户端

```bash
cd /path/to/oo-music/apps/desktop
flutter pub get
flutter run -d macos
```

默认连接 `http://127.0.0.1:8787`。如果后端运行在其他地址，可这样覆盖：

```bash
flutter run -d macos \
  --dart-define=API_BASE_URL=http://127.0.0.1:8787
```

构建应用：

```bash
flutter build macos
```

### 4. 运行 / 构建 Windows 客户端

```powershell
Set-Location C:\Users\PC\GolandProjects\oo-music\apps\desktop
flutter pub get
flutter run -d windows
flutter build windows --release
```

运行 `apps/desktop/build/windows/x64/runner/Release/oo_music.exe`。这是便携目录，
需把 DLL 和 `data/` 一起保留，不能只分发 EXE。仓库根目录执行
`.\scripts\build-windows.ps1 -Package` 可检查、构建并生成便携测试 ZIP。
Windows 后端启动、工具链、数据目录和手测说明见
[`apps/desktop/docs/windows.md`](apps/desktop/docs/windows.md)。

### 5. 运行 / 构建 Android 客户端

Android 已启用 Runner，应用 ID 为 `com.yskj0864.oo_music`，当前最低 API 24。
先启动本机后端，再到仓库根目录运行：

```powershell
.\scripts\build-android.ps1 -Flutter 'D:\Program Files\flutter\bin\flutter.bat'
.\scripts\install-android.ps1 -UsbBackend
```

默认生成 ARM64 debug 测试 APK，并通过 USB 把设备回环 `8787` 转发到本机后端。
安装脚本使用 `adb install -r` 保留应用数据，不卸载、不清除数据。构建参数、系统
文件保存、后台播放边界和模拟器/真机验收记录见
[`apps/desktop/docs/android.md`](apps/desktop/docs/android.md)。

当前服务默认仅监听本机。音乐业务 API 可启用客户端鉴权，管理 API 使用管理员 Bearer 会话；
对外部署仍需反向代理 TLS 和访问控制，不要把本地服务直接暴露到公网。应用不会绕过 VIP、版权、
地区或付费限制，能否播放取决于服务端对应平台号池账号和平台服务端返回的结果。

免费 macOS/Windows/Android 发布包、Android 永久签名 key 和 GitHub Actions 发布流程见
[`docs/free-release-distribution.md`](docs/free-release-distribution.md)。

## 容器镜像与 GitHub Actions

`.github/workflows/backend-ci.yml` 会在以下场景运行：

- 任意分支推送：执行后端测试、静态检查，并构建和推送多架构镜像。
- Pull Request：执行相同检查和镜像构建，但只验证，不推送镜像。
- `v*` 标签：额外生成版本标签。
- 手动 `workflow_dispatch`。

镜像地址使用当前仓库的 GHCR 路径，例如
`ghcr.io/rankgice/oo-music`。默认分支同时生成 `latest`，所有构建还会生成分支标签、
Git 标签或 `sha-` 标签。工作流使用 `GITHUB_TOKEN` 推送镜像，因此要求仓库 Actions 配置允许
`packages: write`。首次发布后可在 GitHub Packages 中调整镜像可见性。

本地构建前后端合一的镜像：

```bash
cd /path/to/oo-music
docker build -t oo-music-backend:local -f backend/Dockerfile .
```

如果当前网络无法访问 `proxy.golang.org`，可以改用构建参数指定 Go 模块代理：

```bash
docker build --build-arg GOPROXY=https://goproxy.cn,direct \
  -t oo-music-backend:local -f backend/Dockerfile .
```

构建上下文是仓库根目录，因为 Dockerfile 需要同时复制 `admin-web/` 和 `backend/`。镜像内只运行
一个 Go 进程，由它同时提供 React 管理网页和 HTTP API；不需要再单独部署前端容器或 Node.js 运行时。

## 测试

在 `backend/` 目录运行离线单元测试和静态检查：

```bash
cd /path/to/oo-music/backend
go test ./...
go vet ./...
```

构建管理前端：

```bash
cd /path/to/oo-music/admin-web
npm install
npm run build
```

运行真实匿名接口的协议链路测试：

```bash
cd /path/to/oo-music/backend
OO_MUSIC_LIVE=1 go test -run TestLiveAnonymous -v .
```

线上测试会访问腾讯官方接口。匿名搜索可能因服务端策略返回空内容，但协议层应成功完成签名、
加密、请求和响应解包。

## 来源说明

签名和请求协议基于 `numb747/qq-music-api-Reverse` 的研究成果整理为 Go 实现，签名 VMP
代码以内嵌资源形式运行。仓库中的上游副本未发现独立 LICENSE 文件；若计划再分发，请先确认
上游授权、QQ 音乐服务条款及相关内容的版权要求。本项目与腾讯或 QQ 音乐无隶属关系。

