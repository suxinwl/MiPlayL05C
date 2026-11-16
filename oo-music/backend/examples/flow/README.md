# 完整歌曲流程 Demo

这个示例依次演示：

1. 搜索歌曲并选择结果；
2. 查询歌曲详情、发行日期、时长和可用音质；
3. 按音质优先级查询音频播放 URL；
4. 获取歌词、翻译和罗马音；
5. 查询关联 MV 的信息和播放 URL；
6. 可选生成一个 HTML 播放器，同时播放音频和 MV。

所有请求直接调用 QQ 音乐官方网页接口；播放结果受当前账号权益、版权和地区限制。

## 运行

在 `backend/` 目录执行：

```bash
go run ./examples/flow -- 周杰伦 晴天
```

默认选择第一条搜索结果、优先请求 `320mp3` 音质。母带资源可能只返回试听片段，
因此基础流程默认使用完整度更稳定的 320 kbps MP3。浏览器可能会阻止跨域媒体播放；
如果需要验证播放，建议同时生成播放器：

```bash
go run ./examples/flow -player /private/tmp/qqmusic-demo.html -- 周杰伦 晴天
open /private/tmp/qqmusic-demo.html
```

也可以直接自动打开：

```bash
go run ./examples/flow -open -- 周杰伦 晴天
```

## 登录态

示例默认使用匿名模式，可以直接运行，但部分歌曲可能没有音频或 MV 权限。QQ 音乐账号由
Web 后端从 SQLite 账号池中选择；示例本身不读取 `QQ_MUSIC_UIN`、`QQ_MUSIC_QM_KEY` 或其他
固定账号环境变量。

如果是在自己的 Go 程序中直接使用 SDK，可以显式创建带登录态的客户端：

```go
client, err := oomusic.NewClient(oomusic.WithCredentials(uin, qmKeyst))
```

不要把 UIN、`qm_keyst`、Cookie 或其他登录凭据写入源码、命令行历史或版本库。

## 参数

```text
-page        搜索结果页码，默认 1
-page-size   每页搜索结果数，默认 10
-pick        选择第几条结果，默认 1
-quality     首选音质: 320mp3, flac, master, 128mp3, 96aac
-lyric-lines 终端展示的歌词行数，0 表示全部
-player      播放器 HTML 输出路径
-open        生成播放器并在默认浏览器中打开
```

例如：

```bash
go run ./examples/flow -pick 2 -quality flac -lyric-lines 0 -- 五月天 倔强
```

如果首选音质不可用，示例会继续尝试其他音质；实际音质和失败原因会输出到终端。没有音频权限时，歌词和 MV 仍会继续查询。

## 接口说明

示例通过 SDK 的 `SearchSongs`、`GetTrackInfo`、`ResolvePlayableBySong` 和 `GetLyric` 方法完成主要流程；MV 使用官方 CGI 模块：

- `music.video.VideoData/get_video_info_batch`
- `music.stream.MvUrlProxy/GetMvUrls`

MV 播放地址是带时效的签名 URL，生成的播放器页面不应公开分享。示例不会绕过 VIP、版权、地区或付费限制。
