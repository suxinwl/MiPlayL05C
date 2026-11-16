// Package api exposes a small HTTP API for the oo-music client.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	oomusic "github.com/rankgice/oo-music"
	"github.com/rankgice/oo-music/internal/account"
	"github.com/rankgice/oo-music/internal/netease"
)

const (
	defaultPageSize = 20
	maxPageSize     = 50
)

// PublicAPIAuthPolicy 提供公开业务接口的运行时鉴权策略。
type PublicAPIAuthPolicy interface {
	PublicAPIAuthRequired(context.Context) (bool, error)
}

// Server exposes a source-neutral JSON API backed by QQ Music and NetEase clients.
type Server struct {
	accounts         *account.Pool
	qqQR             QQLoginService
	neteaseQR        NeteaseQRService
	netease          neteaseMusicClient
	logger           *log.Logger
	publicAuthPolicy PublicAPIAuthPolicy
}

// NewHandler creates the HTTP handler used by the local music app backend.
func NewHandler(accounts *account.Pool, logger *log.Logger) http.Handler {
	return NewHandlerWithWebRoot(accounts, logger, "")
}

// NewHandlerWithWebRoot 创建同时提供 API 和已构建前端静态文件的处理器。
// webRoot 为空时只提供 API，适用于本地前端开发模式。
func NewHandlerWithWebRoot(accounts *account.Pool, logger *log.Logger, webRoot string) http.Handler {
	return NewHandlerWithWebRootAndQR(accounts, nil, logger, webRoot)
}

// NewHandlerWithWebRootAndQR 创建提供音乐 API、客户端扫码登录和管理网页静态文件的处理器。
// qr 必须与后台管理 API 使用同一个实例，否则两边创建的扫码会话无法互相查询。
func NewHandlerWithWebRootAndQR(accounts *account.Pool, qqQR QQLoginService, logger *log.Logger, webRoot string) http.Handler {
	return NewHandlerWithWebRootAndQRAndPolicy(accounts, qqQR, logger, webRoot, nil)
}

// NewHandlerWithWebRootAndQRAndPolicy 创建支持可开关公开接口鉴权的处理器。
func NewHandlerWithWebRootAndQRAndPolicy(
	accounts *account.Pool,
	qqQR QQLoginService,
	logger *log.Logger,
	webRoot string,
	policy PublicAPIAuthPolicy,
) http.Handler {
	return NewHandlerWithWebRootAndBothQRAndPolicy(accounts, qqQR, nil, logger, webRoot, policy)
}

// NewHandlerWithWebRootAndBothQRAndPolicy 创建同时支持 QQ 和网易云扫码登录的多平台处理器。
func NewHandlerWithWebRootAndBothQRAndPolicy(
	accounts *account.Pool,
	qqQR QQLoginService,
	neteaseQR NeteaseQRService,
	logger *log.Logger,
	webRoot string,
	policy PublicAPIAuthPolicy,
) http.Handler {
	if logger == nil {
		logger = log.Default()
	}
	neteaseClient, neteaseErr := netease.NewClient()
	if neteaseErr != nil {
		logger.Printf("创建网易云音乐媒体客户端失败: %v", neteaseErr)
	}
	if neteaseQR == nil && neteaseClient != nil {
		neteaseQR, neteaseErr = netease.NewQRService(neteaseClient, logger)
		if neteaseErr != nil {
			logger.Printf("创建网易云音乐扫码服务失败: %v", neteaseErr)
		}
	}
	server := &Server{
		accounts:         accounts,
		qqQR:             qqQR,
		neteaseQR:        neteaseQR,
		netease:          neteaseClient,
		logger:           logger,
		publicAuthPolicy: policy,
	}
	mux := http.NewServeMux()
	// 存活探针、扫码登录引导和静态网页必须始终公开，否则登录链路会中断。
	mux.HandleFunc("GET /healthz", server.handleLiveness)
	// 用户资料和远程歌单始终要求客户端授权，不受管理后台开关影响。
	mux.Handle("GET /api/client/account", server.requireClientAuthorization(http.HandlerFunc(server.handleClientAccount)))
	mux.Handle("GET /api/client/playlists", server.requireClientAuthorization(http.HandlerFunc(server.handleClientPlaylists)))
	mux.HandleFunc("POST /api/client/login/sessions", server.handleStartClientLogin)
	mux.HandleFunc("GET /api/client/login/sessions/{id}/image", server.handleClientLoginImage)
	mux.HandleFunc("GET /api/client/login/sessions/{id}", server.handlePollClientLogin)
	mux.HandleFunc("DELETE /api/client/login/sessions/{id}", server.handleCancelClientLogin)
	mux.Handle("GET /api/search", server.withPublicAPIAuthorization(http.HandlerFunc(server.handleSearch)))
	mux.Handle("GET /api/tracks", server.withPublicAPIAuthorization(http.HandlerFunc(server.handleTracks)))
	mux.Handle("GET /api/playback", server.withPublicAPIAuthorization(http.HandlerFunc(server.handlePlayback)))
	mux.Handle("GET /api/lyrics", server.withPublicAPIAuthorization(http.HandlerFunc(server.handleLyrics)))
	mux.Handle("GET /api/mv", server.withPublicAPIAuthorization(http.HandlerFunc(server.handleMV)))
	if webRoot = strings.TrimSpace(webRoot); webRoot != "" {
		mux.Handle("/", newSPAHandler(webRoot))
	}
	return server.withCORS(server.withLogging(mux))
}

// handleLiveness 仅表示 HTTP 进程可响应，不查询账号状态，也不会触发体验卡领取。
func (s *Server) handleLiveness(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, struct {
		Status string `json:"status"`
	}{Status: "ok"})
}

type song struct {
	Source             account.AccountType `json:"source"`
	ID                 int64               `json:"id"`
	MID                string              `json:"mid"`
	Name               string              `json:"name"`
	Artists            []string            `json:"artists"`
	Album              string              `json:"album"`
	AlbumMID           string              `json:"albumMid"`
	CoverURL           string              `json:"coverUrl"`
	DurationSeconds    int                 `json:"durationSeconds"`
	HasMV              bool                `json:"hasMv"`
	MVVID              string              `json:"mvVid,omitempty"`
	AvailableQualities []string            `json:"availableQualities"`
}

type searchResponse struct {
	Source   account.AccountType `json:"source"`
	Query    string              `json:"query"`
	Page     int                 `json:"page"`
	PageSize int                 `json:"pageSize"`
	Items    []song              `json:"items"`
}

func (s *Server) handleSearch(w http.ResponseWriter, r *http.Request) {
	source, ok := s.readMusicSource(w, r)
	if !ok {
		return
	}
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	if query == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_query", "搜索关键词不能为空")
		return
	}
	page := positiveQueryInt(r, "page", 1)
	pageSize := positiveQueryInt(r, "page_size", defaultPageSize)
	if pageSize > maxPageSize {
		pageSize = maxPageSize
	}

	if source == account.AccountTypeNetease {
		if !s.neteaseAvailable(w) {
			return
		}
		cookie, _, _, err := s.neteaseCookieForMedia(r.Context(), account.MediaAccountAny)
		if err != nil {
			s.neteaseMediaError(w, "选择网易云音乐账号失败", err)
			return
		}
		result, err := s.netease.SearchSongs(r.Context(), cookie, query, page, pageSize)
		if err != nil {
			s.neteaseMediaError(w, "搜索网易云歌曲失败", err)
			return
		}
		writeJSON(w, http.StatusOK, searchResponse{
			Source:   source,
			Query:    query,
			Page:     page,
			PageSize: pageSize,
			Items:    neteaseSongsToAPI(result.Songs),
		})
		return
	}

	client, err := s.qqClientForMedia(r.Context(), account.MediaAccountAny)
	if err != nil {
		s.internalError(w, "选择 QQ 音乐账号失败", err)
		return
	}
	result, err := client.SearchSongs(r.Context(), query, page, pageSize)
	if err != nil {
		s.internalError(w, "搜索歌曲失败", err)
		return
	}
	if result.Code != 0 {
		s.musicError(w, "搜索歌曲", result.Code, result.Data)
		return
	}
	items, err := decodeSearchSongs(result.Data)
	if err != nil {
		s.internalError(w, "解析搜索结果失败", err)
		return
	}
	writeJSON(w, http.StatusOK, searchResponse{
		Source:   source,
		Query:    query,
		Page:     page,
		PageSize: pageSize,
		Items:    items,
	})
}

type tracksResponse struct {
	Source account.AccountType `json:"source"`
	Items  []song              `json:"items"`
}

func (s *Server) handleTracks(w http.ResponseWriter, r *http.Request) {
	source, ok := s.readMusicSource(w, r)
	if !ok {
		return
	}
	ids, err := positiveInt64ListQuery(r, "ids", maxPageSize)
	if err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_ids", "ids 必须是逗号分隔的正整数歌曲 ID")
		return
	}
	if source == account.AccountTypeNetease {
		if !s.neteaseAvailable(w) {
			return
		}
		cookie, _, _, err := s.neteaseCookieForMedia(r.Context(), account.MediaAccountAny)
		if err != nil {
			s.neteaseMediaError(w, "选择网易云音乐账号失败", err)
			return
		}
		items, err := s.netease.GetSongs(r.Context(), cookie, ids)
		if err != nil {
			s.neteaseMediaError(w, "查询网易云歌曲详情失败", err)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		writeJSON(w, http.StatusOK, tracksResponse{Source: source, Items: neteaseSongsToAPI(items)})
		return
	}

	client, err := s.qqClientForMedia(r.Context(), account.MediaAccountAny)
	if err != nil {
		s.internalError(w, "选择 QQ 音乐账号失败", err)
		return
	}
	result, err := client.GetTrackInfo(r.Context(), oomusic.TrackInfoOptions{
		IDs:   ids,
		Types: make([]int, len(ids)),
	})
	if err != nil {
		s.internalError(w, "查询歌曲详情失败", err)
		return
	}
	if result.Code != 0 {
		s.musicError(w, "查询歌曲详情", result.Code, result.Data)
		return
	}
	items, err := decodeTrackSongs(result.Data)
	if err != nil {
		s.internalError(w, "解析歌曲详情失败", err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, tracksResponse{Source: source, Items: items})
}

type playbackAttempt struct {
	Quality string `json:"quality"`
	Reason  string `json:"reason"`
}

type playbackResponse struct {
	Source    account.AccountType `json:"source"`
	SongID    int64               `json:"songId"`
	Available bool                `json:"available"`
	URL       string              `json:"url,omitempty"`
	Quality   string              `json:"quality,omitempty"`
	Reason    string              `json:"reason,omitempty"`
	Attempts  []playbackAttempt   `json:"attempts,omitempty"`
}

func (s *Server) handlePlayback(w http.ResponseWriter, r *http.Request) {
	source, ok := s.readMusicSource(w, r)
	if !ok {
		return
	}
	songID, err := requiredInt64Query(r, "song_id")
	if err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_song_id", "song_id 必须是有效的歌曲 ID")
		return
	}
	allowFallback := true
	if value, exists := optionalBoolQuery(r, "allow_fallback"); exists {
		allowFallback = value
	}
	if source == account.AccountTypeNetease {
		if !s.neteaseAvailable(w) {
			return
		}
		cookie, _, _, err := s.neteaseCookieForMedia(r.Context(), account.MediaAccountVIP)
		if err != nil {
			s.neteaseMediaError(w, "选择网易云音乐账号失败", err)
			return
		}
		result, err := s.netease.ResolveSongURL(
			r.Context(), cookie, songID, r.URL.Query().Get("quality"), allowFallback,
		)
		if errors.Is(err, netease.ErrUnsupportedQuality) {
			writeAPIError(w, http.StatusBadRequest, "invalid_quality", err.Error())
			return
		}
		if err != nil {
			s.neteaseMediaError(w, "查询网易云播放地址失败", err)
			return
		}
		response := playbackResponse{
			Source:    source,
			SongID:    songID,
			Available: result.URL != "",
			URL:       result.URL,
			Quality:   result.Quality,
			Reason:    result.Reason,
		}
		for _, attempt := range result.Attempts {
			response.Attempts = append(response.Attempts, playbackAttempt{
				Quality: attempt.Quality,
				Reason:  attempt.Reason,
			})
		}
		w.Header().Set("Cache-Control", "no-store")
		writeJSON(w, http.StatusOK, response)
		return
	}

	qualities, qualityName, err := qualityPreference(r.URL.Query().Get("quality"))
	if err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_quality", err.Error())
		return
	}
	if !allowFallback {
		qualities = qualities[:1]
	}

	client, err := s.qqClientForMedia(r.Context(), account.MediaAccountVIP)
	if err != nil {
		s.internalError(w, "选择 QQ 音乐账号失败", err)
		return
	}
	result, err := client.ResolvePlayableBySong(r.Context(), oomusic.ResolvePlayableBySongOptions{
		SongID:          songID,
		PreferQualities: qualities,
	})
	if err != nil {
		s.internalError(w, "查询播放地址失败", err)
		return
	}
	mediaURL := normalizeMediaURL(result.URL)
	response := playbackResponse{
		Source:    source,
		SongID:    songID,
		Available: mediaURL != "",
		URL:       mediaURL,
		Quality:   string(result.Quality),
		Reason:    result.Reason,
	}
	if response.Quality == "" && !response.Available {
		response.Quality = qualityName
	}
	for _, attempt := range result.Tried {
		response.Attempts = append(response.Attempts, playbackAttempt{
			Quality: string(attempt.Quality),
			Reason:  attempt.Reason,
		})
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, response)
}

type lyricResponse struct {
	Source       account.AccountType `json:"source"`
	SongID       int64               `json:"songId"`
	SongMID      string              `json:"songMid,omitempty"`
	Title        string              `json:"title"`
	Artist       string              `json:"artist"`
	Lyric        string              `json:"lyric"`
	Translation  string              `json:"translation"`
	Romanization string              `json:"romanization"`
}

func (s *Server) handleLyrics(w http.ResponseWriter, r *http.Request) {
	source, ok := s.readMusicSource(w, r)
	if !ok {
		return
	}
	songID, err := requiredInt64Query(r, "song_id")
	if err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_song_id", "song_id 必须是有效的歌曲 ID")
		return
	}
	if source == account.AccountTypeNetease {
		if !s.neteaseAvailable(w) {
			return
		}
		cookie, _, _, err := s.neteaseCookieForMedia(r.Context(), account.MediaAccountAny)
		if err != nil {
			s.neteaseMediaError(w, "选择网易云音乐账号失败", err)
			return
		}
		result, err := s.netease.GetLyric(r.Context(), cookie, songID)
		if err != nil {
			s.neteaseMediaError(w, "查询网易云歌词失败", err)
			return
		}
		title := ""
		artist := ""
		if details, detailErr := s.netease.GetSongs(r.Context(), cookie, []int64{songID}); detailErr == nil && len(details) > 0 {
			title = details[0].Name
			artist = strings.Join(details[0].Artists, " / ")
		}
		writeJSON(w, http.StatusOK, lyricResponse{
			Source:       source,
			SongID:       songID,
			Title:        title,
			Artist:       artist,
			Lyric:        result.Lyric,
			Translation:  result.Translation,
			Romanization: result.Romanization,
		})
		return
	}

	client, err := s.qqClientForMedia(r.Context(), account.MediaAccountAny)
	if err != nil {
		s.internalError(w, "选择 QQ 音乐账号失败", err)
		return
	}
	songMID := strings.TrimSpace(r.URL.Query().Get("mid"))
	if songMID == "" {
		track, err := s.lookupTrack(r.Context(), client, songID)
		if err != nil {
			s.internalError(w, "查询歌曲信息失败", err)
			return
		}
		songMID = track.Mid
	}
	if songMID == "" {
		writeAPIError(w, http.StatusUnprocessableEntity, "missing_song_mid", "歌曲没有可用于查询歌词的 MID")
		return
	}

	result, err := client.GetLyric(r.Context(), oomusic.LyricOptions{SongMID: songMID, SongID: songID})
	if err != nil {
		s.internalError(w, "查询歌词失败", err)
		return
	}
	if result.Code != 0 {
		writeAPIError(w, http.StatusBadGateway, "lyric_unavailable", fmt.Sprintf("歌词接口返回业务码 %d", result.Code))
		return
	}
	writeJSON(w, http.StatusOK, lyricResponse{
		Source:       source,
		SongID:       songID,
		SongMID:      songMID,
		Title:        result.SongName,
		Artist:       result.SingerName,
		Lyric:        result.Lyric,
		Translation:  result.Trans,
		Romanization: result.Roma,
	})
}

type trackMetadata struct {
	Mid string `json:"mid"`
	MV  qqMV   `json:"mv"`
}

func (s *Server) lookupTrack(ctx context.Context, client *oomusic.Client, songID int64) (*trackMetadata, error) {
	result, err := client.GetTrackInfo(ctx, oomusic.TrackInfoOptions{IDs: []int64{songID}, Types: []int{0}})
	if err != nil {
		return nil, err
	}
	if result.Code != 0 {
		return nil, fmt.Errorf("track API code %d", result.Code)
	}
	var data struct {
		Tracks []trackMetadata `json:"tracks"`
	}
	if err := json.Unmarshal(result.Data, &data); err != nil {
		return nil, err
	}
	if len(data.Tracks) == 0 {
		return nil, oomusic.ErrSongNotFound
	}
	return &data.Tracks[0], nil
}

type mvResponse struct {
	Source          account.AccountType `json:"source"`
	SongID          int64               `json:"songId,omitempty"`
	VID             string              `json:"vid"`
	Available       bool                `json:"available"`
	URL             string              `json:"url,omitempty"`
	Name            string              `json:"name,omitempty"`
	Description     string              `json:"description,omitempty"`
	CoverURL        string              `json:"coverUrl,omitempty"`
	DurationSeconds int                 `json:"durationSeconds,omitempty"`
	FileType        int                 `json:"fileType,omitempty"`
	Bitrate         int                 `json:"bitrate,omitempty"`
	FileSize        int64               `json:"fileSize,omitempty"`
	Reason          string              `json:"reason,omitempty"`
}

type mvInfo struct {
	VID      string `json:"vid"`
	Name     string `json:"name"`
	Desc     string `json:"desc"`
	CoverPic string `json:"cover_pic"`
	Duration int    `json:"duration"`
}

type mvStream struct {
	URL         []string `json:"url"`
	FreeflowURL []string `json:"freeflow_url"`
	CommURL     []string `json:"comm_url"`
	M3U8        string   `json:"m3u8"`
	Code        int      `json:"code"`
	FileType    int      `json:"filetype"`
	FileSize    int64    `json:"fileSize"`
}

type mvURLData struct {
	MP4 []mvStream `json:"mp4"`
	HLS []mvStream `json:"hls"`
}

func (s *Server) handleMV(w http.ResponseWriter, r *http.Request) {
	source, ok := s.readMusicSource(w, r)
	if !ok {
		return
	}
	rawSongID := strings.TrimSpace(r.URL.Query().Get("song_id"))
	vid := strings.TrimSpace(r.URL.Query().Get("vid"))
	if vid == "" {
		vid = strings.TrimSpace(r.URL.Query().Get("mv_id"))
	}
	var songID int64
	var err error
	if rawSongID != "" {
		songID, err = strconv.ParseInt(rawSongID, 10, 64)
		if err != nil || songID <= 0 {
			writeAPIError(w, http.StatusBadRequest, "invalid_song_id", "song_id 必须是有效的歌曲 ID")
			return
		}
	}
	if songID == 0 && vid == "" {
		writeAPIError(w, http.StatusBadRequest, "missing_mv_identifier", "song_id 和 vid 至少提供一个")
		return
	}

	if source == account.AccountTypeNetease {
		if !s.neteaseAvailable(w) {
			return
		}
		cookie, _, _, err := s.neteaseCookieForMedia(r.Context(), account.MediaAccountAny)
		if err != nil {
			s.neteaseMediaError(w, "选择网易云音乐账号失败", err)
			return
		}
		mvID := int64(0)
		if vid != "" {
			mvID, err = strconv.ParseInt(vid, 10, 64)
			if err != nil || mvID <= 0 {
				writeAPIError(w, http.StatusBadRequest, "invalid_mv_id", "网易云 MV ID 必须是正整数")
				return
			}
		}
		if mvID == 0 {
			songs, err := s.netease.GetSongs(r.Context(), cookie, []int64{songID})
			if err != nil {
				s.neteaseMediaError(w, "查询网易云歌曲 MV 信息失败", err)
				return
			}
			if len(songs) == 0 || songs[0].MV <= 0 {
				writeAPIError(w, http.StatusUnprocessableEntity, "mv_unavailable", "这首歌曲没有关联 MV")
				return
			}
			mvID = songs[0].MV
		}
		info, err := s.netease.GetMV(r.Context(), cookie, mvID)
		if err != nil {
			s.neteaseMediaError(w, "查询网易云 MV 播放地址失败", err)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		writeJSON(w, http.StatusOK, mvResponse{
			Source:          source,
			SongID:          songID,
			VID:             strconv.FormatInt(mvID, 10),
			Available:       info.URL != "",
			URL:             info.URL,
			Name:            info.Name,
			Description:     info.Description,
			CoverURL:        info.CoverURL,
			DurationSeconds: info.DurationSeconds,
			Bitrate:         info.Bitrate,
			FileSize:        info.FileSize,
			Reason:          info.Reason,
		})
		return
	}

	client, err := s.qqClientForMedia(r.Context(), account.MediaAccountAny)
	if err != nil {
		s.internalError(w, "选择 QQ 音乐账号失败", err)
		return
	}
	if vid == "" {
		track, err := s.lookupTrack(r.Context(), client, songID)
		if err != nil {
			s.internalError(w, "查询歌曲 MV 信息失败", err)
			return
		}
		vid = strings.TrimSpace(track.MV.VID)
	}
	if vid == "" {
		writeAPIError(w, http.StatusUnprocessableEntity, "mv_unavailable", "这首歌曲没有关联 MV")
		return
	}

	info, stream, mediaURL, reason, err := fetchMV(r.Context(), client, vid)
	if err != nil {
		s.internalError(w, "查询 MV 播放地址失败", err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, mvResponse{
		Source:          source,
		SongID:          songID,
		VID:             vid,
		Available:       mediaURL != "",
		URL:             normalizeMediaURL(mediaURL),
		Name:            info.Name,
		Description:     info.Desc,
		CoverURL:        normalizeMediaURL(info.CoverPic),
		DurationSeconds: info.Duration,
		FileType:        stream.FileType,
		FileSize:        stream.FileSize,
		Reason:          reason,
	})
}

func fetchMV(ctx context.Context, client *oomusic.Client, vid string) (mvInfo, mvStream, string, string, error) {
	infoResult, err := client.CallQQ(ctx, "music.video.VideoData", "get_video_info_batch", map[string]any{
		"vidlist": []string{vid},
		"required": []string{
			"vid", "type", "sid", "cover_pic", "duration", "singers", "video_pay", "name",
			"desc", "playcnt", "pubdate", "isfav", "fileid", "filesize_v2", "pay", "play_forbid_reason",
		},
	})
	if err != nil {
		return mvInfo{}, mvStream{}, "", "", fmt.Errorf("查询 MV 信息: %w", err)
	}
	if infoResult.Code != 0 {
		return mvInfo{}, mvStream{}, "", "", fmt.Errorf("MV 信息接口返回业务码 %d", infoResult.Code)
	}
	var infos map[string]mvInfo
	if err := json.Unmarshal(infoResult.Data, &infos); err != nil {
		return mvInfo{}, mvStream{}, "", "", fmt.Errorf("解析 MV 信息: %w", err)
	}
	info, ok := infos[vid]
	if !ok {
		for _, candidate := range infos {
			info = candidate
			ok = true
			break
		}
	}
	if !ok {
		return mvInfo{}, mvStream{}, "", "", errors.New("MV 信息为空")
	}
	if info.VID == "" {
		info.VID = vid
	}

	urlResult, err := client.CallQQ(ctx, "music.stream.MvUrlProxy", "GetMvUrls", map[string]any{
		"vids":         []string{vid},
		"request_type": 10003,
		"addrtype":     3,
		"format":       264,
		"maxFiletype":  60,
	})
	if err != nil {
		return info, mvStream{}, "", "", fmt.Errorf("查询 MV 播放地址: %w", err)
	}
	if urlResult.Code != 0 {
		return info, mvStream{}, "", "", fmt.Errorf("MV 播放地址接口返回业务码 %d", urlResult.Code)
	}
	var urls map[string]mvURLData
	if err := json.Unmarshal(urlResult.Data, &urls); err != nil {
		return info, mvStream{}, "", "", fmt.Errorf("解析 MV 播放地址: %w", err)
	}
	data, ok := urls[vid]
	if !ok {
		for _, candidate := range urls {
			data = candidate
			ok = true
			break
		}
	}
	if !ok {
		return info, mvStream{}, "", "服务端未返回 MV 播放信息", nil
	}
	stream, playURL, ok := pickBestMVStream(data)
	if !ok {
		return info, mvStream{}, "", "服务端未返回可播放的 MV 地址，可能受版权、地区或账号权限限制", nil
	}
	return info, stream, playURL, "", nil
}

func pickBestMVStream(data mvURLData) (mvStream, string, bool) {
	streams := make([]mvStream, 0, len(data.MP4)+len(data.HLS))
	streams = append(streams, data.MP4...)
	streams = append(streams, data.HLS...)
	filtered := streams[:0]
	for _, stream := range streams {
		if stream.Code != 0 {
			continue
		}
		if _, ok := streamPlayURL(stream); ok {
			filtered = append(filtered, stream)
		}
	}
	sort.SliceStable(filtered, func(i, j int) bool {
		if filtered[i].FileType != filtered[j].FileType {
			return filtered[i].FileType > filtered[j].FileType
		}
		return filtered[i].FileSize > filtered[j].FileSize
	})
	if len(filtered) == 0 {
		return mvStream{}, "", false
	}
	playURL, _ := streamPlayURL(filtered[0])
	return filtered[0], playURL, true
}

func streamPlayURL(stream mvStream) (string, bool) {
	for _, candidates := range [][]string{stream.FreeflowURL, stream.CommURL, stream.URL} {
		for _, candidate := range candidates {
			candidate = strings.TrimSpace(candidate)
			if candidate != "" && (strings.HasPrefix(candidate, "http://") || strings.HasPrefix(candidate, "https://")) {
				return candidate, true
			}
		}
	}
	if candidate := strings.TrimSpace(stream.M3U8); candidate != "" {
		return candidate, true
	}
	return "", false
}

type qqSinger struct {
	Name string `json:"name"`
}

type qqAlbum struct {
	ID   int64  `json:"id"`
	Mid  string `json:"mid"`
	Name string `json:"name"`
}

type qqMV struct {
	VID string `json:"vid"`
}

type qqSearchSong struct {
	ID       int64      `json:"id"`
	Mid      string     `json:"mid"`
	Name     string     `json:"name"`
	Title    string     `json:"title"`
	Interval int        `json:"interval"`
	Singers  []qqSinger `json:"singer"`
	Album    qqAlbum    `json:"album"`
	MV       qqMV       `json:"mv"`
}

func decodeSearchSongs(data []byte) ([]song, error) {
	var response struct {
		Body struct {
			Song struct {
				List []qqSearchSong `json:"list"`
			} `json:"song"`
		} `json:"body"`
	}
	if err := json.Unmarshal(data, &response); err != nil {
		return nil, err
	}
	items := make([]song, 0, len(response.Body.Song.List))
	for _, item := range response.Body.Song.List {
		artists := make([]string, 0, len(item.Singers))
		for _, artist := range item.Singers {
			if name := strings.TrimSpace(artist.Name); name != "" {
				artists = append(artists, name)
			}
		}
		items = append(items, song{
			Source:             account.AccountTypeQQ,
			ID:                 item.ID,
			MID:                item.Mid,
			Name:               firstNonEmpty(item.Name, item.Title),
			Artists:            artists,
			Album:              item.Album.Name,
			AlbumMID:           item.Album.Mid,
			CoverURL:           albumCoverURL(item.Album.Mid),
			DurationSeconds:    item.Interval,
			HasMV:              strings.TrimSpace(item.MV.VID) != "",
			MVVID:              strings.TrimSpace(item.MV.VID),
			AvailableQualities: []string{},
		})
	}
	return items, nil
}

type qqTrackFile struct {
	Size128MP3 int64 `json:"size_128mp3"`
	Size320MP3 int64 `json:"size_320mp3"`
	SizeFLAC   int64 `json:"size_flac"`
	Size96AAC  int64 `json:"size_96aac"`
}

type qqTrackSong struct {
	ID       int64       `json:"id"`
	Mid      string      `json:"mid"`
	Name     string      `json:"name"`
	Title    string      `json:"title"`
	Interval int         `json:"interval"`
	Singers  []qqSinger  `json:"singer"`
	Album    qqAlbum     `json:"album"`
	MV       qqMV        `json:"mv"`
	File     qqTrackFile `json:"file"`
}

func decodeTrackSongs(data []byte) ([]song, error) {
	var response struct {
		Tracks []qqTrackSong `json:"tracks"`
	}
	if err := json.Unmarshal(data, &response); err != nil {
		return nil, err
	}
	items := make([]song, 0, len(response.Tracks))
	for _, item := range response.Tracks {
		artists := make([]string, 0, len(item.Singers))
		for _, artist := range item.Singers {
			if name := strings.TrimSpace(artist.Name); name != "" {
				artists = append(artists, name)
			}
		}
		qualities := make([]string, 0, 4)
		if item.File.SizeFLAC > 0 {
			qualities = append(qualities, string(oomusic.QualityFLAC))
		}
		if item.File.Size320MP3 > 0 {
			qualities = append(qualities, string(oomusic.QualityMP3320))
		}
		if item.File.Size128MP3 > 0 {
			qualities = append(qualities, string(oomusic.QualityMP3128))
		}
		if item.File.Size96AAC > 0 {
			qualities = append(qualities, string(oomusic.QualityAAC96))
		}
		items = append(items, song{
			Source:             account.AccountTypeQQ,
			ID:                 item.ID,
			MID:                item.Mid,
			Name:               firstNonEmpty(item.Name, item.Title),
			Artists:            artists,
			Album:              item.Album.Name,
			AlbumMID:           item.Album.Mid,
			CoverURL:           albumCoverURL(item.Album.Mid),
			DurationSeconds:    item.Interval,
			HasMV:              strings.TrimSpace(item.MV.VID) != "",
			MVVID:              strings.TrimSpace(item.MV.VID),
			AvailableQualities: qualities,
		})
	}
	return items, nil
}

func neteaseSongsToAPI(items []netease.Song) []song {
	result := make([]song, 0, len(items))
	for _, item := range items {
		artists := item.Artists
		if artists == nil {
			artists = []string{}
		}
		qualities := item.AvailableQualities
		if qualities == nil {
			qualities = []string{}
		}
		mvID := ""
		if item.MV > 0 {
			mvID = strconv.FormatInt(item.MV, 10)
		}
		result = append(result, song{
			Source:             account.AccountTypeNetease,
			ID:                 item.ID,
			Name:               item.Name,
			Artists:            artists,
			Album:              item.Album,
			CoverURL:           item.CoverURL,
			DurationSeconds:    item.DurationSeconds,
			HasMV:              item.MV > 0,
			MVVID:              mvID,
			AvailableQualities: qualities,
		})
	}
	return result
}

func normalizeMediaURL(mediaURL string) string {
	mediaURL = strings.TrimSpace(mediaURL)
	if strings.HasPrefix(mediaURL, "http://") {
		return "https://" + strings.TrimPrefix(mediaURL, "http://")
	}
	return mediaURL
}

func albumCoverURL(albumMID string) string {
	albumMID = strings.TrimSpace(albumMID)
	if albumMID == "" {
		return ""
	}
	return fmt.Sprintf("https://y.gtimg.cn/music/photo_new/T002R300x300M000%s.jpg", albumMID)
}

func qualityPreference(value string) ([]oomusic.Quality, string, error) {
	value = strings.ToLower(strings.TrimSpace(value))
	var preferred oomusic.Quality
	switch value {
	case "", "320", "320mp3":
		preferred = oomusic.QualityMP3320
	case "master", "rs02":
		preferred = oomusic.QualityMaster
	case "flac", "lossless":
		preferred = oomusic.QualityFLAC
	case "128", "128mp3":
		preferred = oomusic.QualityMP3128
	case "aac", "96aac":
		preferred = oomusic.QualityAAC96
	default:
		return nil, "", fmt.Errorf("不支持的音质 %q", value)
	}
	order := []oomusic.Quality{preferred}
	for _, quality := range oomusic.DefaultQualityOrder {
		if quality != preferred {
			order = append(order, quality)
		}
	}
	return order, string(preferred), nil
}

func positiveQueryInt(r *http.Request, key string, fallback int) int {
	value, err := strconv.Atoi(r.URL.Query().Get(key))
	if err != nil || value < 1 {
		return fallback
	}
	return value
}

func requiredInt64Query(r *http.Request, key string) (int64, error) {
	value, err := strconv.ParseInt(strings.TrimSpace(r.URL.Query().Get(key)), 10, 64)
	if err != nil || value <= 0 {
		return 0, errors.New("invalid positive integer")
	}
	return value, nil
}

func optionalBoolQuery(r *http.Request, key string) (bool, bool) {
	rawValue := strings.TrimSpace(r.URL.Query().Get(key))
	if rawValue == "" {
		return false, false
	}
	value, err := strconv.ParseBool(rawValue)
	if err != nil {
		return false, false
	}
	return value, true
}

func positiveInt64ListQuery(r *http.Request, key string, limit int) ([]int64, error) {
	rawValue := strings.TrimSpace(r.URL.Query().Get(key))
	if rawValue == "" {
		return nil, errors.New("missing value")
	}
	parts := strings.Split(rawValue, ",")
	if len(parts) > limit {
		return nil, fmt.Errorf("too many values: %d > %d", len(parts), limit)
	}
	values := make([]int64, 0, len(parts))
	seen := make(map[int64]struct{}, len(parts))
	for _, part := range parts {
		value, err := strconv.ParseInt(strings.TrimSpace(part), 10, 64)
		if err != nil || value <= 0 {
			return nil, errors.New("invalid positive integer")
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		values = append(values, value)
	}
	if len(values) == 0 {
		return nil, errors.New("empty list")
	}
	return values, nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

type errorBody struct {
	Error apiError `json:"error"`
}

type apiError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func writeAPIError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, errorBody{Error: apiError{Code: code, Message: message}})
}

func (s *Server) internalError(w http.ResponseWriter, message string, err error) {
	s.logger.Printf("%s: %v", message, err)
	writeAPIError(w, http.StatusBadGateway, "upstream_error", message)
}

func (s *Server) musicError(w http.ResponseWriter, operation string, code int, data []byte) {
	s.logger.Printf("%s returned business code %d: %s", operation, code, truncate(string(data), 500))
	writeAPIError(w, http.StatusBadGateway, "upstream_business_error", fmt.Sprintf("%s返回业务码 %d", operation, code))
}

func truncate(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	return value[:limit] + "..."
}

func (s *Server) withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, "+account.ClientSourceHeader+", "+account.ClientAccountIDHeader+", "+account.ClientAccessKeyHeader)
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) withLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		next.ServeHTTP(w, r)
		s.logger.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(started).Round(time.Millisecond))
	})
}
