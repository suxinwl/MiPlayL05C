package netease

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"
)

const (
	maxPlaylistCount  = 100
	maxPlaylistSongs  = 20000
	maxSongDetailIDs  = 50
	neteaseMVURLRange = 1080
)

// ErrUnsupportedQuality 表示调用方传入了当前网易云适配层不支持的音质名。
var ErrUnsupportedQuality = errors.New("不支持的网易云音质")

// Song 是网易云音乐搜索和详情接口的规范化歌曲。
type Song struct {
	ID                 int64
	Name               string
	Artists            []string
	Album              string
	AlbumID            int64
	CoverURL           string
	DurationSeconds    int
	MV                 int64
	AvailableQualities []string
}

// SearchResult 是一次网易云歌曲搜索的规范化结果。
type SearchResult struct {
	Songs []Song
	Total int
}

// SongURLAttempt 记录一次音质解析结果。
type SongURLAttempt struct {
	Quality string
	Reason  string
}

// SongURL 是网易云歌曲播放地址和实际音质。
type SongURL struct {
	URL      string
	Quality  string
	Reason   string
	Type     string
	Bitrate  int
	Size     int64
	Attempts []SongURLAttempt
}

// Lyric 是网易云歌词、翻译和罗马音文本。
type Lyric struct {
	Lyric        string
	Translation  string
	Romanization string
}

// MVInfo 是网易云 MV 元数据和播放地址。
type MVInfo struct {
	ID              int64
	Name            string
	Description     string
	CoverURL        string
	DurationSeconds int
	URL             string
	Bitrate         int
	FileSize        int64
	Reason          string
}

// UserPlaylist 是网易云账号创建或收藏的歌单及歌曲 ID 快照。
type UserPlaylist struct {
	ID        string
	Name      string
	CoverURL  string
	SongCount int
	SongIDs   []int64
}

// SearchSongs 搜索网易云歌曲。网易云分页从 1 开始，对外与 QQ 接口保持一致。
func (c *Client) SearchSongs(ctx context.Context, cookie, query string, page, pageSize int) (SearchResult, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return SearchResult{}, errors.New("搜索关键词不能为空")
	}
	if page < 1 {
		page = 1
	}
	if pageSize < 1 {
		pageSize = 20
	}
	if pageSize > 100 {
		pageSize = 100
	}
	cookies, err := c.normalizedCookies(cookie)
	if err != nil {
		return SearchResult{}, err
	}
	payload := map[string]any{
		"s":      query,
		"type":   1,
		"limit":  pageSize,
		"offset": (page - 1) * pageSize,
		"total":  true,
	}
	result, err := c.doWeapi(ctx, "/api/cloudsearch/pc", payload, cookies)
	if err != nil {
		return SearchResult{}, err
	}
	if err := neteaseMusicCodeError("搜索歌曲", result); err != nil {
		return SearchResult{}, err
	}
	var response struct {
		Result struct {
			Songs     []neteaseSong  `json:"songs"`
			SongCount flexibleNumber `json:"songCount"`
		} `json:"result"`
	}
	if err := json.Unmarshal(result.Raw, &response); err != nil {
		return SearchResult{}, fmt.Errorf("解析网易云搜索结果: %w", err)
	}
	songs := make([]Song, 0, len(response.Result.Songs))
	for _, item := range response.Result.Songs {
		songs = append(songs, item.normalized())
	}
	return SearchResult{Songs: songs, Total: response.Result.SongCount.Int()}, nil
}

// GetSongs 批量读取网易云歌曲详情。
func (c *Client) GetSongs(ctx context.Context, cookie string, ids []int64) ([]Song, error) {
	ids = normalizeSongIDs(ids)
	if len(ids) == 0 {
		return nil, errors.New("歌曲 ID 不能为空")
	}
	if len(ids) > maxSongDetailIDs {
		return nil, fmt.Errorf("歌曲数量超过上限 %d", maxSongDetailIDs)
	}
	payload := make([]map[string]int64, 0, len(ids))
	for _, id := range ids {
		payload = append(payload, map[string]int64{"id": id})
	}
	cPayload, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	cookies, err := c.normalizedCookies(cookie)
	if err != nil {
		return nil, err
	}
	result, err := c.doWeapi(ctx, "/api/v3/song/detail", map[string]any{
		"c": string(cPayload),
	}, cookies)
	if err != nil {
		return nil, err
	}
	if err := neteaseMusicCodeError("查询歌曲详情", result); err != nil {
		return nil, err
	}
	var response struct {
		Songs []neteaseSong `json:"songs"`
	}
	if err := json.Unmarshal(result.Raw, &response); err != nil {
		return nil, fmt.Errorf("解析网易云歌曲详情: %w", err)
	}
	songs := make([]Song, 0, len(response.Songs))
	for _, item := range response.Songs {
		songs = append(songs, item.normalized())
	}
	return songs, nil
}

// ResolveSongURL 按统一音质名请求网易云播放地址，并在不可用时降级。
func (c *Client) ResolveSongURL(ctx context.Context, cookie string, songID int64, quality string, allowFallback bool) (SongURL, error) {
	if songID <= 0 {
		return SongURL{}, errors.New("歌曲 ID 必须为正整数")
	}
	levels, err := neteaseQualityLevels(quality)
	if err != nil {
		return SongURL{}, err
	}
	if !allowFallback && len(levels) > 1 {
		levels = levels[:1]
	}
	cookies, err := c.normalizedCookies(cookie)
	if err != nil {
		return SongURL{}, err
	}
	result := SongURL{}
	for _, level := range levels {
		apiResult, requestErr := c.doWeapi(ctx, "/api/song/enhance/player/url/v1", map[string]any{
			"ids":        fmt.Sprintf("[%d]", songID),
			"level":      level.API,
			"encodeType": level.EncodeType,
		}, cookies)
		if requestErr != nil {
			result.Attempts = append(result.Attempts, SongURLAttempt{Quality: level.Unified, Reason: requestErr.Error()})
			continue
		}
		if apiResult.Code != 200 {
			if isUnauthorizedCode(apiResult.Code) {
				return SongURL{}, ErrUnauthorized
			}
			reason := fmt.Sprintf("播放地址接口返回业务码 %d", apiResult.Code)
			result.Attempts = append(result.Attempts, SongURLAttempt{Quality: level.Unified, Reason: reason})
			continue
		}
		item, reason, parseErr := parseNeteaseSongURL(apiResult.Raw)
		if parseErr != nil {
			result.Attempts = append(result.Attempts, SongURLAttempt{Quality: level.Unified, Reason: parseErr.Error()})
			continue
		}
		if item.URL == "" {
			result.Attempts = append(result.Attempts, SongURLAttempt{Quality: level.Unified, Reason: reason})
			continue
		}
		item.URL = normalizeNeteaseURL(item.URL)
		item.Quality = level.Unified
		item.Attempts = result.Attempts
		return item, nil
	}
	result.Reason = "没有可用的网易云播放地址"
	return result, nil
}

// GetLyric 查询网易云歌词、翻译和罗马音。
func (c *Client) GetLyric(ctx context.Context, cookie string, songID int64) (Lyric, error) {
	if songID <= 0 {
		return Lyric{}, errors.New("歌曲 ID 必须为正整数")
	}
	cookies, err := c.normalizedCookies(cookie)
	if err != nil {
		return Lyric{}, err
	}
	result, err := c.doWeapi(ctx, "/api/song/lyric", map[string]any{
		"id": songID,
		"lv": -1,
		"kv": -1,
		"tv": -1,
		"rv": -1,
	}, cookies)
	if err != nil {
		return Lyric{}, err
	}
	if err := neteaseMusicCodeError("查询歌词", result); err != nil {
		return Lyric{}, err
	}
	var response struct {
		LRC    neteaseLyric `json:"lrc"`
		Tlyric neteaseLyric `json:"tlyric"`
		Roma   neteaseLyric `json:"romalrc"`
	}
	if err := json.Unmarshal(result.Raw, &response); err != nil {
		return Lyric{}, fmt.Errorf("解析网易云歌词: %w", err)
	}
	return Lyric{
		Lyric:        response.LRC.Lyric,
		Translation:  response.Tlyric.Lyric,
		Romanization: response.Roma.Lyric,
	}, nil
}

// GetMV 查询网易云 MV 元数据和播放地址。
func (c *Client) GetMV(ctx context.Context, cookie string, mvID int64) (MVInfo, error) {
	if mvID <= 0 {
		return MVInfo{}, errors.New("MV ID 必须为正整数")
	}
	cookies, err := c.normalizedCookies(cookie)
	if err != nil {
		return MVInfo{}, err
	}
	infoResult, err := c.doWeapi(ctx, "/api/mv/detail", map[string]any{"id": mvID}, cookies)
	if err != nil {
		return MVInfo{}, err
	}
	if err := neteaseMusicCodeError("查询 MV 信息", infoResult); err != nil {
		return MVInfo{}, err
	}
	info, err := parseNeteaseMVInfo(infoResult.Raw, mvID)
	if err != nil {
		return MVInfo{}, err
	}
	urlResult, err := c.doWeapi(ctx, "/api/song/enhance/play/mv/url", map[string]any{
		"id": mvID,
		"r":  neteaseMVURLRange,
	}, cookies)
	if err != nil {
		return info, err
	}
	if err := neteaseMusicCodeError("查询 MV 播放地址", urlResult); err != nil {
		return info, err
	}
	mediaURL, bitrate, fileSize, reason, err := parseNeteaseMVURL(urlResult.Raw)
	if err != nil {
		return info, err
	}
	info.URL = normalizeNeteaseURL(mediaURL)
	info.Bitrate = bitrate
	info.FileSize = fileSize
	info.Reason = reason
	return info, nil
}

// GetUserPlaylists 读取网易云用户创建和收藏的歌单，并补齐歌曲 ID。
func (c *Client) GetUserPlaylists(ctx context.Context, cookie, uid string) ([]UserPlaylist, error) {
	uid = strings.TrimSpace(uid)
	if uid == "" {
		return nil, errors.New("网易云账号 ID 不能为空")
	}
	cookies, err := c.normalizedCookies(cookie)
	if err != nil {
		return nil, err
	}
	result, err := c.doWeapi(ctx, "/api/user/playlist", map[string]any{
		"uid":          uid,
		"limit":        maxPlaylistCount,
		"offset":       0,
		"includeVideo": true,
	}, cookies)
	if err != nil {
		return nil, err
	}
	if err := neteaseMusicCodeError("查询用户歌单", result); err != nil {
		return nil, err
	}
	var response struct {
		Playlist []neteaseUserPlaylist `json:"playlist"`
	}
	if err := json.Unmarshal(result.Raw, &response); err != nil {
		return nil, fmt.Errorf("解析网易云用户歌单: %w", err)
	}
	playlists := make([]UserPlaylist, 0, len(response.Playlist))
	seen := make(map[string]struct{}, len(response.Playlist))
	for _, item := range response.Playlist {
		id := strconv.FormatInt(item.ID.Int64(), 10)
		if item.ID.Int64() <= 0 {
			continue
		}
		if _, exists := seen[id]; exists {
			continue
		}
		seen[id] = struct{}{}
		songIDs := []int64{}
		if item.TrackCount.Int() > 0 {
			songIDs, err = c.getPlaylistSongIDs(ctx, cookies, item.ID.Int64())
			if err != nil {
				return nil, fmt.Errorf("读取网易云歌单 %s 歌曲: %w", id, err)
			}
		}
		playlists = append(playlists, UserPlaylist{
			ID:        id,
			Name:      strings.TrimSpace(item.Name),
			CoverURL:  normalizeNeteaseURL(item.CoverURL),
			SongCount: item.TrackCount.Int(),
			SongIDs:   songIDs,
		})
	}
	return playlists, nil
}

func (c *Client) getPlaylistSongIDs(ctx context.Context, cookies map[string]string, playlistID int64) ([]int64, error) {
	result, err := c.doWeapi(ctx, "/api/v6/playlist/detail", map[string]any{
		"id": playlistID,
		"n":  1000,
		"s":  8,
	}, cookies)
	if err != nil {
		return nil, err
	}
	if err := neteaseMusicCodeError("查询歌单详情", result); err != nil {
		return nil, err
	}
	var response struct {
		Playlist struct {
			TrackIDs []struct {
				ID flexibleNumber `json:"id"`
			} `json:"trackIds"`
			Tracks []neteaseSong `json:"tracks"`
		} `json:"playlist"`
	}
	if err := json.Unmarshal(result.Raw, &response); err != nil {
		return nil, err
	}
	ids := make([]int64, 0, len(response.Playlist.TrackIDs))
	seen := make(map[int64]struct{}, len(response.Playlist.TrackIDs))
	for _, item := range response.Playlist.TrackIDs {
		id := item.ID.Int64()
		if id <= 0 {
			continue
		}
		if _, exists := seen[id]; exists {
			continue
		}
		seen[id] = struct{}{}
		ids = append(ids, id)
		if len(ids) >= maxPlaylistSongs {
			break
		}
	}
	if len(ids) == 0 {
		for _, item := range response.Playlist.Tracks {
			if item.ID <= 0 {
				continue
			}
			if _, exists := seen[item.ID]; exists {
				continue
			}
			seen[item.ID] = struct{}{}
			ids = append(ids, item.ID)
			if len(ids) >= maxPlaylistSongs {
				break
			}
		}
	}
	return ids, nil
}

type neteaseSong struct {
	ID          int64            `json:"id"`
	Name        string           `json:"name"`
	Artists     []neteaseArtist  `json:"ar"`
	ArtistOld   []neteaseArtist  `json:"artists"`
	Album       neteaseAlbum     `json:"al"`
	AlbumOld    neteaseAlbum     `json:"album"`
	Duration    flexibleNumber   `json:"dt"`
	DurationOld flexibleNumber   `json:"duration"`
	MV          flexibleNumber   `json:"mv"`
	H           *neteaseSongFile `json:"h"`
	M           *neteaseSongFile `json:"m"`
	L           *neteaseSongFile `json:"l"`
	SQ          *neteaseSongFile `json:"sq"`
	HR          *neteaseSongFile `json:"hr"`
}

type neteaseArtist struct {
	Name string `json:"name"`
}

type neteaseAlbum struct {
	ID     flexibleNumber `json:"id"`
	Name   string         `json:"name"`
	PicURL string         `json:"picUrl"`
}

type neteaseSongFile struct {
	Bitrate int   `json:"br"`
	Size    int64 `json:"size"`
}

func (s neteaseSong) normalized() Song {
	artists := s.Artists
	if len(artists) == 0 {
		artists = s.ArtistOld
	}
	artistNames := make([]string, 0, len(artists))
	for _, artist := range artists {
		if name := strings.TrimSpace(artist.Name); name != "" {
			artistNames = append(artistNames, name)
		}
	}
	album := s.Album
	if strings.TrimSpace(album.Name) == "" && s.AlbumOld.ID.Int64() > 0 {
		album = s.AlbumOld
	}
	duration := s.Duration.Int64()
	if duration <= 0 {
		duration = s.DurationOld.Int64()
	}
	return Song{
		ID:                 s.ID,
		Name:               strings.TrimSpace(s.Name),
		Artists:            artistNames,
		Album:              strings.TrimSpace(album.Name),
		AlbumID:            album.ID.Int64(),
		CoverURL:           normalizeNeteaseURL(album.PicURL),
		DurationSeconds:    int(duration / 1000),
		MV:                 s.MV.Int64(),
		AvailableQualities: neteaseSongQualities(s),
	}
}

func neteaseSongQualities(song neteaseSong) []string {
	qualities := make([]string, 0, 4)
	if song.HR != nil {
		qualities = append(qualities, "master")
	}
	if song.SQ != nil {
		qualities = append(qualities, "flac")
	}
	if song.H != nil {
		qualities = append(qualities, "320mp3")
	}
	if song.M != nil || song.L != nil {
		qualities = append(qualities, "128mp3")
	}
	return qualities
}

type neteaseQualityLevel struct {
	API        string
	EncodeType string
	Unified    string
}

func neteaseQualityLevels(raw string) ([]neteaseQualityLevel, error) {
	raw = strings.ToLower(strings.TrimSpace(raw))
	var preferred string
	switch raw {
	case "", "320", "320mp3", "exhigh":
		preferred = "exhigh"
	case "128", "128mp3", "standard":
		preferred = "standard"
	case "192", "192mp3", "higher":
		preferred = "higher"
	case "flac", "lossless":
		preferred = "lossless"
	case "master", "hires", "hi-res", "rs02":
		preferred = "hires"
	case "aac", "96aac":
		preferred = "higher"
	default:
		return nil, fmt.Errorf("%w: %q", ErrUnsupportedQuality, raw)
	}
	all := []neteaseQualityLevel{
		{API: "hires", EncodeType: "flac", Unified: "master"},
		{API: "lossless", EncodeType: "flac", Unified: "flac"},
		{API: "exhigh", EncodeType: "mp3", Unified: "320mp3"},
		{API: "higher", EncodeType: "mp3", Unified: "192mp3"},
		{API: "standard", EncodeType: "mp3", Unified: "128mp3"},
	}
	start := 0
	for index, level := range all {
		if level.API == preferred {
			start = index
			break
		}
	}
	return append([]neteaseQualityLevel(nil), all[start:]...), nil
}

type neteaseSongURLItem struct {
	URL       string          `json:"url"`
	Type      string          `json:"type"`
	Bitrate   flexibleNumber  `json:"br"`
	Size      flexibleNumber  `json:"size"`
	Code      flexibleNumber  `json:"code"`
	Fee       flexibleNumber  `json:"fee"`
	FreeTrial json.RawMessage `json:"freeTrialInfo"`
}

func parseNeteaseSongURL(raw []byte) (SongURL, string, error) {
	var response struct {
		Data []neteaseSongURLItem `json:"data"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return SongURL{}, "", err
	}
	if len(response.Data) == 0 {
		return SongURL{}, "平台没有返回播放数据", nil
	}
	item := response.Data[0]
	if strings.TrimSpace(item.URL) != "" {
		return SongURL{
			URL:     item.URL,
			Type:    item.Type,
			Bitrate: int(item.Bitrate.Int64()),
			Size:    item.Size.Int64(),
		}, "", nil
	}
	reason := "平台未返回播放地址"
	if item.Code.Int64() > 0 && item.Code.Int64() != 200 {
		reason = fmt.Sprintf("平台返回歌曲状态码 %d", item.Code.Int64())
	} else if item.Fee.Int64() > 0 || (len(item.FreeTrial) > 0 && string(item.FreeTrial) != "null" && string(item.FreeTrial) != "{}") {
		reason = "歌曲需要会员、购买或仅支持试听"
	}
	return SongURL{}, reason, nil
}

type neteaseLyric struct {
	Lyric string `json:"lyric"`
}

type neteaseUserPlaylist struct {
	ID         flexibleNumber `json:"id"`
	Name       string         `json:"name"`
	CoverURL   string         `json:"coverImgUrl"`
	TrackCount flexibleNumber `json:"trackCount"`
}

func parseNeteaseMVInfo(raw []byte, fallbackID int64) (MVInfo, error) {
	var response struct {
		Data json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return MVInfo{}, err
	}
	type mvDetail struct {
		ID       flexibleNumber `json:"id"`
		Name     string         `json:"name"`
		Desc     string         `json:"desc"`
		Cover    string         `json:"cover"`
		Duration flexibleNumber `json:"duration"`
	}
	var item mvDetail
	if len(response.Data) > 0 && string(response.Data) != "null" {
		if err := json.Unmarshal(response.Data, &item); err != nil {
			var list []mvDetail
			if listErr := json.Unmarshal(response.Data, &list); listErr != nil || len(list) == 0 {
				return MVInfo{}, err
			}
			item = list[0]
		}
	}
	id := item.ID.Int64()
	if id <= 0 {
		id = fallbackID
	}
	return MVInfo{
		ID:              id,
		Name:            strings.TrimSpace(item.Name),
		Description:     strings.TrimSpace(item.Desc),
		CoverURL:        normalizeNeteaseURL(item.Cover),
		DurationSeconds: int(item.Duration.Int64() / 1000),
	}, nil
}

func parseNeteaseMVURL(raw []byte) (string, int, int64, string, error) {
	var response struct {
		Data json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(raw, &response); err != nil {
		return "", 0, 0, "", err
	}
	mediaURL, fileType, fileSize, ok := firstNeteaseMedia(response.Data)
	if ok {
		return mediaURL, fileType, fileSize, "", nil
	}
	return "", 0, 0, "平台未返回可播放的 MV 地址", nil
}

func firstNeteaseMedia(raw json.RawMessage) (string, int, int64, bool) {
	if len(raw) == 0 || string(raw) == "null" {
		return "", 0, 0, false
	}
	if value := firstJSONString(raw); value != "" {
		return value, 0, 0, true
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(raw, &object); err == nil {
		if value := firstJSONString(object["url"]); value != "" {
			return value, firstJSONInt(object["br"]), firstJSONInt64(object["size"]), true
		}
		for _, key := range []string{"data", "urlInfo", "brs"} {
			if nested, exists := object[key]; exists {
				if value, fileType, fileSize, ok := firstNeteaseMedia(nested); ok {
					return value, fileType, fileSize, true
				}
			}
		}
		for _, nested := range object {
			if value, fileType, fileSize, ok := firstNeteaseMedia(nested); ok {
				return value, fileType, fileSize, true
			}
		}
	}
	var list []json.RawMessage
	if err := json.Unmarshal(raw, &list); err == nil {
		for _, item := range list {
			if value, fileType, fileSize, ok := firstNeteaseMedia(item); ok {
				return value, fileType, fileSize, true
			}
		}
	}
	return "", 0, 0, false
}

func firstJSONString(raw json.RawMessage) string {
	var value string
	if len(raw) == 0 || json.Unmarshal(raw, &value) != nil {
		return ""
	}
	return normalizeNeteaseURL(value)
}

func firstJSONInt(raw json.RawMessage) int {
	var number flexibleNumber
	if len(raw) == 0 || json.Unmarshal(raw, &number) != nil {
		return 0
	}
	return int(number.Int64())
}

func firstJSONInt64(raw json.RawMessage) int64 {
	var number flexibleNumber
	if len(raw) == 0 || json.Unmarshal(raw, &number) != nil {
		return 0
	}
	return number.Int64()
}

type flexibleNumber int64

func (n *flexibleNumber) UnmarshalJSON(raw []byte) error {
	value := strings.TrimSpace(string(raw))
	if value == "" || value == "null" {
		*n = 0
		return nil
	}
	value = strings.Trim(value, `"`)
	if value == "" {
		*n = 0
		return nil
	}
	if index := strings.IndexByte(value, '.'); index >= 0 {
		value = value[:index]
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return err
	}
	*n = flexibleNumber(parsed)
	return nil
}

func (n flexibleNumber) Int() int {
	return int(n)
}

func (n flexibleNumber) Int64() int64 {
	return int64(n)
}

func normalizeSongIDs(ids []int64) []int64 {
	result := make([]int64, 0, len(ids))
	seen := make(map[int64]struct{}, len(ids))
	for _, id := range ids {
		if id <= 0 {
			continue
		}
		if _, exists := seen[id]; exists {
			continue
		}
		seen[id] = struct{}{}
		result = append(result, id)
	}
	return result
}

func neteaseMusicCodeError(operation string, result apiResult) error {
	if result.Code == 200 {
		return nil
	}
	if isUnauthorizedCode(result.Code) {
		return ErrUnauthorized
	}
	return fmt.Errorf("网易云%s返回业务码 %d: %s", operation, result.Code, result.Message)
}

func normalizeNeteaseURL(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	if parsed.Scheme == "http" {
		parsed.Scheme = "https"
	}
	return parsed.String()
}
