# 多平台音乐客户端与账号存储设计（第一阶段）

- 状态：实施中；后端 `accounts` v1 与客户端本地库 v4 已完成
- 日期：2026-11-10
- 范围：已确认的客户端交互设计、后端账号表目标结构、客户端本地表目标结构
- 目标平台：QQ 音乐、网易云音乐
- 本文重点记录存储与交互约束；公开接口当前只记录基础路由、`source` 约定和统一 DTO 方向，完整字段目录后续补充

## 实施进度

- [x] 后端 `accounts` 统一账号表；旧结构直接重建，不迁移数据
- [x] 客户端 SQLite v4 统一歌单、歌曲和双平台账号表；旧结构直接重建
- [x] 客户端平台模型、Repository/Gateway 与页面切换（Windows/macOS/Android 共享实现）
- [x] 后端分平台业务路由、鉴权和公开 DTO（基础版）
- [ ] Windows/Android 实机或模拟器运行验证

后端基础版统一约定：

- 业务接口必须显式使用 `source=qq|netease`，缺失或未知值返回 `400`。
- 固定受保护接口额外使用 `X-OO-Music-Source`，账号 ID 使用
  `X-OO-Music-Account-ID`。
- 歌曲、搜索、播放、歌词、MV 和远程歌单响应均带 `source`。
- QQ 与网易云统一使用 `/api/client/login/sessions?source=qq|netease` 扫码链路。

客户端基础版已完成：

- 左上角平台切换，QQ 和网易云分别保存当前账号，无账号时保持匿名模式。
- 搜索状态按平台保存，搜索与远程歌单跟随当前平台。
- 歌曲以 `mediaKey = source:id` 区分；本地歌单和最近播放支持混合平台歌曲。
- 播放、歌词、MV、音质和下载按歌曲自身平台选择账号与接口。
- 歌单、搜索结果、播放栏、迷你播放器和正在播放页展示平台标识。

## 1. 设计目标

客户端支持两个音乐平台，但不做一次性“大而全”的聚合平台重构。

第一阶段采用简单的平台切换模型：

- 用户分别拥有一个当前 QQ 音乐账号和一个当前网易云音乐账号。
- 左上角提供平台切换入口。
- 切换平台决定搜索、当前账号和远程歌单使用哪个平台。
- 没有某个平台账号时仍可切换到该平台，按匿名方式访问。
- 后端是否允许匿名由接口结果决定。
- 所有歌曲数据必须携带平台标识。
- 本地歌单保持全局，可混合两个平台的歌曲。
- 当前播放不随页面平台切换而停止或重建。

## 2. 三个核心状态

必须区分以下三个概念：

```text
selectedSource      当前界面选中的平台
song.source         歌曲自身所属平台
activeAccount[source] 每个平台各自的当前账号
```

### 平台枚举

```dart
enum MusicSource { qq, netease }
```

### 账号状态

```text
qqAccount      当前 QQ 音乐账号，可为空
neteaseAccount 当前网易云音乐账号，可为空
```

不能继续使用单一的全局 `clientAccount` 同时代表两个平台。

## 3. 左上角平台切换

推荐展示两个平台入口：

```text
[QQ 音乐] [网易云音乐]
```

并在旁边展示当前平台的账号状态：

```text
QQ 音乐 · Rankgice
网易云音乐 · 未登录（匿名访问）
```

平台切换控件负责：

- 切换搜索上下文
- 切换当前账号展示
- 切换远程歌单上下文
- 保存上次选中的平台

平台切换不是账号切换。即使没有账号，也必须允许切换。

账号相关操作在选中平台内部完成：

- 查看当前账号
- 切换本机已保存账号
- 扫码登录
- 删除本机账号

二维码中的 URL 不能让普通 Intent 等价替代扫码：QQ 会把短链交给浏览器，网易云会把链接
当作普通网页登录并触发环境风控。官方 App 扫码包含独立的内部处理上下文，因此客户端继续以
二维码授权或手动填写凭据为准。

## 4. 切换平台后的页面行为

| 区域 | 切换平台后的行为 |
| --- | --- |
| 搜索框 | 搜索目标切换为新平台 |
| 搜索结果 | 展示新平台结果；可恢复该平台上次搜索 |
| 当前账号 | 展示新平台自己的当前账号 |
| 远程歌单 | 切换为新平台、新账号对应的远程歌单 |
| 本地歌单 | 不变，继续全局展示 |
| 最近播放 | 不变，可以混合平台歌曲 |
| 当前播放队列 | 不停止、不重建 |
| 当前播放歌曲 | 继续播放，使用歌曲自身的平台账号 |
| 正在播放页 | 显示当前歌曲的真实平台标识 |
| 音质偏好 | 最终按平台分别保存，第一阶段可暂后实现 |

## 5. 匿名访问规则

切换到没有账号的平台时：

```text
selectedSource = netease
activeAccount[netease] = null
```

客户端行为：

1. 不携带该平台的客户端授权头。
2. 继续请求搜索和其他允许匿名的接口。
3. 如果后端允许匿名，正常使用。
4. 如果后端拒绝匿名，返回 401/403 后显示平台相关的登录提示。
5. 远程歌单区域直接显示“登录后可同步远程歌单”，不发起无意义请求。

示例提示：

```text
网易云音乐匿名访问不可用，请先登录
```

不能因为未登录而禁止切换平台。

## 6. 搜索

搜索使用 `selectedSource`：

```text
selectedSource = qq      -> 搜索 QQ 音乐
selectedSource = netease -> 搜索网易云音乐
```

第一阶段不做“全部平台”聚合搜索。

搜索结果状态建议按平台分别保存：

```text
searchState[qq]
searchState[netease]
```

切换平台时：

- 可以恢复该平台上次搜索结果
- 不能让旧平台请求结果覆盖新平台页面
- 每个搜索请求必须带平台和请求序号，防止竞态

## 7. 当前账号

客户端本地维护：

```text
activeAccount[qq]
activeAccount[netease]
```

账号模型统一为：

```dart
class ClientAccountSession {
  final MusicSource source;
  final String accountId;
  final String? accessKey;
  final String nickname;
  final String avatarUrl;
  final DateTime? updatedAt;
}
```

约束：

- `accessKey` 为空时不可切换为该账号。
- 客户端永远不保存 QQ 的 `qm_keyst` 或网易云的 `MUSIC_U`/Cookie。
- 切换 QQ 账号不影响网易云账号。
- 切换网易云账号不影响 QQ 账号。

## 8. 远程歌单

远程歌单严格归属于：

```text
selectedSource + activeAccount[selectedSource]
```

无账号时：

- 不展示远程歌单内容
- 显示登录引导
- 不读取旧平台或其他账号的缓存

远程歌单唯一标识必须包含平台和账号：

```text
remote:<source>:<accountId>:<remotePlaylistId>
```

## 9. 本地歌单与最近播放

本地歌单和最近播放保持全局，不按平台拆分。

允许出现混合歌单：

```text
我的本地歌单
  ├── QQ：晴天
  ├── 网易云：晴天
  └── QQ：七里香
```

因此每首歌曲必须保存：

```text
source
id
```

推荐唯一标识：

```text
mediaKey = "<source>:<id>"
```

本地歌单和最近播放的数据模型不得只保存整数歌曲 ID。

## 10. 歌曲相关操作

所有歌曲相关操作都以 `song.source` 为准，而不是 `selectedSource`：

| 操作 | 使用的平台 |
| --- | --- |
| 播放 | `song.source` |
| 播放 URL 刷新 | `song.source` |
| 歌词 | `song.source` |
| MV | `song.source` |
| 下载 | `song.source` |
| 收藏 | `song.source` |
| 最近播放 | `song.source` |
| 缓存 | `song.source` |
| 队列恢复 | `song.source` |

搜索和远程歌单使用 `selectedSource`。

## 11. 统一歌曲模型

```dart
class Song {
  final MusicSource source;
  final String id;
  final String name;
  final List<String> artists;
  final String album;
  final String coverUrl;
  final Duration duration;
  final bool hasMv;
  final String mvId;
  final List<AudioQuality> availableQualities;

  String get mediaKey => '${source.name}:$id';
}
```

QQ 的 `mid`、`albumMid` 等平台专有字段作为可选扩展字段保留，不作为所有平台都必须存在的字段。

## 12. 播放行为

当前播放歌曲与页面选中平台可以不同。

示例：

```text
当前页面：QQ 音乐
正在播放：网易云音乐歌曲
```

这是允许的。播放器必须使用服务端网易云号池解析播放 URL；客户端当前绑定的网易云账号只用于
账户资料、远程歌单等有账户归属的请求，不作为共享媒体请求的上游账号。

禁止静默跨平台切换音源：

- 网易云歌曲不可用时，不能自动播放 QQ 音乐同名歌曲
- 如果以后支持跨平台兜底，必须由用户明确开启
- UI 必须显示实际播放来源

## 13. 播放队列

队列允许混合两个平台歌曲。

当前歌曲的查找、替换和恢复必须使用：

```dart
song.mediaKey
```

不能继续使用：

```dart
song.id
```

系统媒体信息中的 ID 也应使用 `mediaKey`。

每次切歌时：

```text
读取 Song.source
-> 从服务端该平台号池选择共享媒体账号
   VIP 播放优先要求号池中存在可用 VIP，没有时可触发放到号池账号的领取流程
-> 请求该平台播放 URL
-> 交给统一音频引擎播放
```

必须区分两类账号作用域：

- 账户作用域：账户资料、远程歌单、收藏、历史等必须使用客户端当前绑定账号。
- 媒体作用域：搜索、歌曲详情、播放、歌词、MV 使用服务端号池，多个客户端共用该平台账号。

客户端 accessKey 只用于确认请求方身份，不决定媒体请求使用哪个上游账号。

音频引擎本身不需要知道平台。

## 14. 音质

第一阶段可以先保留现有音质字符串，但后续必须按平台保存偏好：

```text
preferredQuality[qq]
preferredQuality[netease]
```

音质菜单只展示当前歌曲平台支持的音质。

不在第一阶段强行把 QQ 和网易云的音质枚举合并成一个值。

## 15. 客户端 API 方向

客户端页面不直接判断平台接口细节，通过 Repository 或统一 Gateway 调用：

```dart
Future<List<Song>> search(MusicSource source, String query);

Future<PlaybackInfo> playback(Song song, String quality);

Future<Lyrics> lyrics(Song song);

Future<MvInfo?> mv(Song song);

Future<List<RemotePlaylist>> remotePlaylists(MusicSource source);

Future<LoginSession> login(MusicSource source);
```

内部选择规则：

```text
search(source)         -> 使用 selectedSource
remotePlaylists(source)-> 使用 selectedSource + 对应账号
playback(song)         -> 使用 song.source
lyrics(song)           -> 使用 song.source
mv(song)               -> 使用 song.source
```

具体后端路由和鉴权头在后续后端设计中确定。

## 16. 后端 accounts 表目标结构

第一阶段后端数据库只重构 `accounts`，不新增播放列表、歌曲缓存或会员领取记录表。

### 16.1 目标字段

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | INTEGER PRIMARY KEY | 内部主键 |
| `account_type` | TEXT NOT NULL CHECK | `qq` / `netease` |
| `account_id` | TEXT NOT NULL | QQ 号或网易云 UID，不再添加平台前缀 |
| `credential` | TEXT NOT NULL | QQ 的 `qm_keyst` 或网易云完整 Cookie |
| `access_key` | TEXT | 客户端使用的后端授权密钥 |
| `nickname` | TEXT NOT NULL DEFAULT '' | 昵称 |
| `avatar_url` | TEXT NOT NULL DEFAULT '' | 头像 |
| `vip_level` | INTEGER NOT NULL DEFAULT 0 | 统一会员等级，0–3 |
| `vip_expires_at` | INTEGER | 会员到期时间，Unix 秒 |
| `vip_checked_at` | INTEGER | 最近会员状态检测时间，Unix 秒 |
| `login_valid` | INTEGER NOT NULL DEFAULT 1 | 登录态是否有效 |
| `login_checked_at` | INTEGER | 最近登录态检测时间，Unix 秒 |
| `login_expires_at` | INTEGER | 网易云授权到期时间；QQ 可为空 |
| `credential_updated_at` | INTEGER | 凭据最近更新时间 |
| `created_at` | INTEGER NOT NULL | 创建时间，Unix 秒 |
| `updated_at` | INTEGER NOT NULL | 更新时间，Unix 秒 |

### 16.2 约束和索引

```sql
CHECK(account_type IN ('qq', 'netease'));

UNIQUE(account_type, account_id);
```

```sql
CREATE UNIQUE INDEX idx_accounts_identity
ON accounts(account_type, account_id);

CREATE INDEX idx_accounts_selection
ON accounts(
  account_type,
  login_valid,
  vip_level DESC,
  vip_expires_at DESC,
  id ASC
);
```

### 16.3 旧数据策略

本版本不迁移旧账号数据。启动时先校验 `PRAGMA user_version = 1` 和 `accounts` 完整字段集合：

- 当前结构完全匹配：保留现有账号数据；
- 旧结构、残缺结构、未知结构：在事务内删除 `accounts`，按当前 schema 重建；
- `admin_users` 和 `system_settings` 不受影响。

不执行补列、复制、字段改名或 accessKey 回填。

## 17. 客户端本地表目标结构

客户端本地数据库当前 schema 为 `user_version = 4`。

### 17.1 playlists

目标字段：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | TEXT PRIMARY KEY | 歌单 ID |
| `name` | TEXT NOT NULL | 歌单名称 |
| `built_in` | INTEGER NOT NULL DEFAULT 0 | 是否内置 |
| `sort_order` | INTEGER NOT NULL | 排序 |
| `playlist_type` | TEXT NOT NULL | `local` / `remote` |
| `source` | TEXT NOT NULL | `qq` / `netease` / `mixed` |
| `account_id` | TEXT NOT NULL DEFAULT '' | 远程歌单所属账号 |
| `remote_id` | TEXT NOT NULL DEFAULT '' | 远程歌单 ID |
| `cover_url` | TEXT NOT NULL DEFAULT '' | 封面 |
| `updated_at` | INTEGER NOT NULL DEFAULT 0 | 更新时间 |

约束：

- 本地歌单使用 `source = 'mixed'`。
- 远程歌单使用 `source = 'qq'` 或 `source = 'netease'`。

### 17.2 playlist_songs

目标字段：

```text
playlist_id TEXT NOT NULL
source      TEXT NOT NULL
song_id     TEXT NOT NULL
sort_order  INTEGER NOT NULL
```

主键：

```sql
PRIMARY KEY(playlist_id, source, song_id)
```

索引：

```sql
CREATE INDEX idx_playlist_songs_order
ON playlist_songs(playlist_id, sort_order);
```

歌曲 ID 以 TEXT 存储，并始终与 `source` 一起作为跨平台唯一标识。

### 17.3 client_accounts

目标字段：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `account_type` | TEXT NOT NULL | `qq` / `netease` |
| `account_id` | TEXT NOT NULL | 平台账号 ID |
| `access_key` | TEXT | 后端授权密钥 |
| `nickname` | TEXT NOT NULL DEFAULT '' | 昵称 |
| `avatar_url` | TEXT NOT NULL DEFAULT '' | 头像 |
| `updated_at` | INTEGER NOT NULL | 更新时间 |

主键：

```sql
PRIMARY KEY(account_type, account_id)
```

账号按 `account_type + account_id` 区分；同一数字 ID 可同时存在于两个平台。

### 17.4 settings

必需键：

```text
selected_source
active_account_netease
preferred_quality_netease
```

第一阶段必须支持：

- `selected_source`
- `active_account_qq`
- `active_account_netease`

按平台音质偏好可以随后实现，但键名提前保留。

## 18. UI 平台标识

必须显示平台标识的位置：

- 混合本地歌单中的歌曲
- 最近播放
- 播放队列
- 正在播放页
- 下载列表
- 播放失败提示
- 跨平台来源切换提示

当前搜索页已经选定平台时，可以不重复显示醒目标识，但歌曲数据中仍必须携带 `source`。

## 19. 第一阶段明确不做

- 不做“全部平台”聚合搜索
- 不做自动跨平台同名歌曲合并
- 不做自动跨平台音源兜底
- 不把两个平台的音质枚举强行合并
- 不让页面直接调用 QQ/网易云专用客户端
- 不让客户端持有平台原始 Cookie
- 不因为切换页面平台而停止当前播放

## 20. 第一阶段验收标准

1. 左上角可在 QQ 音乐和网易云音乐之间切换。
2. 两个平台分别保存自己的当前账号。
3. 无账号平台仍可切换，并按匿名模式请求。
4. 无账号时远程歌单显示登录引导。
5. 搜索使用当前选中平台。
6. 播放、歌词、MV 使用歌曲自身平台。
7. 切换平台不停止当前播放。
8. 本地歌单可以混合两个平台歌曲。
9. ID 相同的 QQ 和网易云歌曲不会冲突。
10. 后端 `accounts` 使用 `UNIQUE(account_type, account_id)`。
11. 后端凭据统一存储于 `credential`。
12. 客户端歌单歌曲主键包含 `source`。
13. 客户端账号主键包含 `account_type + account_id`。
14. 旧数据库结构直接清空重建，不执行数据迁移。
