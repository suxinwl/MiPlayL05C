package oomusic

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

const (
	playlistDetailPageSize = 200
	maxPlaylistSongPages   = 100
	maxPlaylistSongs       = 20000
)

// PlaylistOptions 配置 GetPlaylistDetail 调用。
type PlaylistOptions struct {
	// DisstID 是数字歌单 ID。
	DisstID string
	// DirID 是 QQ 音乐歌单目录 ID。读取用户歌单详情时应传入列表接口返回的 dirId。
	DirID string
	// Offset 是从 0 开始的歌曲偏移量。
	Offset int
	// Limit 是最多返回的歌曲数量。
	Limit int
}

// UserPlaylist 是当前 QQ 音乐账号创建的歌单及其歌曲 ID 快照。
type UserPlaylist struct {
	// ID 是 QQ 音乐歌单 ID，普通歌单通常来自 tid，收藏歌单可能来自 dissid 或 dirid。
	ID string
	// DirID 是 QQ 音乐歌单目录 ID，用于新版 CgiGetDiss 详情接口。
	DirID string
	// Name 是歌单名称。
	Name string
	// CoverURL 是 QQ 音乐返回的歌单封面地址。
	CoverURL string
	// SongCount 是 QQ 音乐声明的歌曲数量。
	SongCount int
	// SongIDs 是按歌单顺序排列的 QQ 音乐数字歌曲 ID。
	SongIDs []int64
}

// GetPlaylistDetail 调用 music.srfDissInfo.DissInfo/CgiGetDiss，
// 返回歌单元数据及指定区间的歌曲。该 RPC 使用未加密的 musicu.fcg，
// 且 disstid、dirid 必须以 JSON number 传递。
func (c *Client) GetPlaylistDetail(ctx context.Context, options PlaylistOptions) (*CallResult, error) {
	disstID := strings.TrimSpace(options.DisstID)
	if disstID == "" {
		return nil, errors.New("playlist ID must not be empty")
	}
	disstIDNumber, err := strconv.ParseInt(disstID, 10, 64)
	if err != nil {
		return nil, fmt.Errorf("playlist ID %q is not numeric: %w", disstID, err)
	}
	dirIDNumber := int64(0)
	if dirID := strings.TrimSpace(options.DirID); dirID != "" {
		dirIDNumber, err = strconv.ParseInt(dirID, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("playlist directory ID %q is not numeric: %w", dirID, err)
		}
	}
	return c.callMusicU(ctx, "music.srfDissInfo.DissInfo", "CgiGetDiss", map[string]any{
		"disstid":      disstIDNumber,
		"dirid":        dirIDNumber,
		"userinfo":     1,
		"tag":          1,
		"orderlist":    1,
		"song_begin":   options.Offset,
		"song_num":     defaultPositive(options.Limit, 10),
		"onlysonglist": 0,
	})
}

// IsPlaylistFav 调用 music.musicasset.PlaylistFavRead/IsPlaylistFan，
// 查询当前登录账号是否收藏指定歌单。
func (c *Client) IsPlaylistFav(ctx context.Context, tid string) (*CallResult, error) {
	tid = strings.TrimSpace(tid)
	if tid == "" {
		return nil, errors.New("playlist TID must not be empty")
	}
	return c.CallQQ(ctx, "music.musicasset.PlaylistFavRead", "IsPlaylistFan", map[string]any{
		"v_tid": []string{tid},
	})
}

// GetUserCreatedPlaylists 使用当前客户端登录态读取指定 UIN 的 QQ 音乐创建歌单。
//
// 该方法先调用 music.musicasset.PlaylistBaseRead/GetPlaylistByUin 取得歌单
// 列表，再分页调用 CgiGetDiss 补齐每个歌单的数字歌曲 ID。遇到
// QQ 音乐业务码 1000 时会返回 *APIError，调用方应将该账号标记为登录态失效。
func (c *Client) GetUserCreatedPlaylists(ctx context.Context, uin string) ([]UserPlaylist, error) {
	if !c.IsLoggedIn() {
		return nil, errors.New("reading user playlists requires a logged-in client")
	}
	uin = strings.TrimSpace(uin)
	if uin == "" {
		uin = c.session.uin
	}
	if uin == "" {
		return nil, errors.New("QQ Music UIN must not be empty")
	}

	result, err := c.CallQQ(ctx, "music.musicasset.PlaylistBaseRead", "GetPlaylistByUin", map[string]any{
		"uin":            uin,
		"bWithoutStatus": false,
	})
	if err != nil {
		return nil, err
	}
	if result == nil {
		return nil, errors.New("query user playlists returned no result")
	}
	if result.Code != 0 {
		return nil, &APIError{Code: result.Code, Raw: result.Raw}
	}
	playlists, err := parseUserPlaylists(result.Data)
	if err != nil {
		return nil, err
	}
	for index := range playlists {
		songIDs, err := c.getPlaylistSongIDs(ctx, playlists[index])
		if err != nil {
			return nil, err
		}
		playlists[index].SongIDs = songIDs
	}
	return playlists, nil
}

func (c *Client) getPlaylistSongIDs(ctx context.Context, playlist UserPlaylist) ([]int64, error) {
	if playlist.SongCount <= 0 {
		return []int64{}, nil
	}
	limitedCount := playlist.SongCount
	if limitedCount > maxPlaylistSongs {
		limitedCount = maxPlaylistSongs
	}
	ids := make([]int64, 0, limitedCount)
	seen := make(map[int64]struct{}, limitedCount)
	offset := 0
	for page := 0; page < maxPlaylistSongPages && offset < limitedCount; page++ {
		limit := playlistDetailPageSize
		if remaining := limitedCount - offset; remaining < limit {
			limit = remaining
		}
		result, err := c.GetPlaylistDetail(ctx, PlaylistOptions{
			DisstID: playlist.ID,
			DirID:   playlist.DirID,
			Offset:  offset,
			Limit:   limit,
		})
		if err != nil {
			return nil, fmt.Errorf("query playlist %s songs: %w", playlist.ID, err)
		}
		if result == nil {
			return nil, fmt.Errorf("query playlist %s songs returned no result", playlist.ID)
		}
		if result.Code != 0 {
			return nil, &APIError{Code: result.Code, Raw: result.Raw}
		}
		pageIDs, total, err := parsePlaylistSongIDs(result.Data)
		if err != nil {
			return nil, fmt.Errorf("decode playlist %s songs: %w", playlist.ID, err)
		}
		for _, songID := range pageIDs {
			if songID <= 0 {
				continue
			}
			if _, exists := seen[songID]; exists {
				continue
			}
			seen[songID] = struct{}{}
			ids = append(ids, songID)
		}
		if len(pageIDs) == 0 {
			break
		}
		offset += len(pageIDs)
		if total > 0 && offset >= total {
			break
		}
	}
	return ids, nil
}

func parseUserPlaylists(data json.RawMessage) ([]UserPlaylist, error) {
	var payload struct {
		Playlists []struct {
			DirName        string         `json:"dirName"`
			DissName       string         `json:"diss_name"`
			PicURL         string         `json:"picUrl"`
			DissCover      string         `json:"diss_cover"`
			SongNum        flexibleInt    `json:"songNum"`
			SongCount      flexibleInt    `json:"songCount"`
			SongCountSnake flexibleInt    `json:"song_count"`
			SongCNT        flexibleInt    `json:"song_cnt"`
			DirID          flexibleString `json:"dirId"`
			DirIDSnake     flexibleString `json:"dirid"`
			TID            flexibleString `json:"tid"`
			DissID         flexibleString `json:"dissid"`
		} `json:"v_playlist"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, fmt.Errorf("decode user playlist list: %w", err)
	}
	result := make([]UserPlaylist, 0, len(payload.Playlists))
	seen := make(map[string]struct{}, len(payload.Playlists))
	for _, item := range payload.Playlists {
		id := firstNonZeroPlaylistID(
			item.TID.String(),
			item.DissID.String(),
			item.DirID.String(),
			item.DirIDSnake.String(),
		)
		if id == "" {
			continue
		}
		if _, exists := seen[id]; exists {
			continue
		}
		seen[id] = struct{}{}
		songCount := firstPositiveInt(
			item.SongNum.Int(),
			item.SongCount.Int(),
			item.SongCNT.Int(),
			item.SongCountSnake.Int(),
		)
		name := firstNonEmpty(strings.TrimSpace(item.DirName), strings.TrimSpace(item.DissName))
		coverURL := firstNonEmpty(strings.TrimSpace(item.PicURL), strings.TrimSpace(item.DissCover))
		dirID := firstNonZeroPlaylistID(item.DirID.String(), item.DirIDSnake.String())
		result = append(result, UserPlaylist{
			ID:        id,
			DirID:     dirID,
			Name:      name,
			CoverURL:  coverURL,
			SongCount: songCount,
			SongIDs:   []int64{},
		})
	}
	return result, nil
}

func parsePlaylistSongIDs(data json.RawMessage) ([]int64, int, error) {
	var payload struct {
		SongList []struct {
			ID     flexibleInt `json:"id"`
			SongID flexibleInt `json:"songid"`
		} `json:"songlist"`
		Total    flexibleInt `json:"total"`
		TotalNum flexibleInt `json:"total_song_num"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, 0, err
	}
	ids := make([]int64, 0, len(payload.SongList))
	for _, item := range payload.SongList {
		songID := item.ID.Int()
		if songID <= 0 {
			songID = item.SongID.Int()
		}
		if songID > 0 {
			ids = append(ids, int64(songID))
		}
	}
	total := payload.Total.Int()
	if total <= 0 {
		total = payload.TotalNum.Int()
	}
	return ids, total, nil
}

func firstNonZeroPlaylistID(values ...string) string {
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" && value != "0" {
			return value
		}
	}
	return ""
}

func firstPositiveInt(values ...int) int {
	for _, value := range values {
		if value > 0 {
			return value
		}
	}
	return 0
}

type flexibleString string

func (value *flexibleString) UnmarshalJSON(data []byte) error {
	if len(data) == 0 || string(data) == "null" {
		*value = ""
		return nil
	}
	var text string
	if err := json.Unmarshal(data, &text); err == nil {
		*value = flexibleString(text)
		return nil
	}
	var number json.Number
	if err := json.Unmarshal(data, &number); err == nil {
		*value = flexibleString(number.String())
		return nil
	}
	return fmt.Errorf("value is not a string or number: %s", truncateForError(data))
}

func (value flexibleString) String() string {
	return string(value)
}

type flexibleInt int

func (value *flexibleInt) UnmarshalJSON(data []byte) error {
	if len(data) == 0 || string(data) == "null" {
		*value = 0
		return nil
	}
	var number int
	if err := json.Unmarshal(data, &number); err == nil {
		*value = flexibleInt(number)
		return nil
	}
	var text string
	if err := json.Unmarshal(data, &text); err == nil {
		parsed, parseErr := strconv.Atoi(strings.TrimSpace(text))
		if parseErr != nil {
			return fmt.Errorf("parse integer %q: %w", text, parseErr)
		}
		*value = flexibleInt(parsed)
		return nil
	}
	return fmt.Errorf("value is not an integer")
}

func (value flexibleInt) Int() int {
	return int(value)
}
