package api

import (
	"errors"
	"net/http"

	"github.com/rankgice/oo-music/internal/account"
)

type clientPlaylist struct {
	Source    account.AccountType `json:"source"`
	ID        string              `json:"id"`
	Name      string              `json:"name"`
	CoverURL  string              `json:"coverUrl"`
	SongCount int                 `json:"songCount"`
	SongIDs   []int64             `json:"songIds"`
}

type clientPlaylistsResponse struct {
	Source    account.AccountType `json:"source"`
	Playlists []clientPlaylist    `json:"playlists"`
}

// handleClientPlaylists 使用请求中平台账号/accessKey 对应的账号读取远程歌单。
// 该调用不会切换账号池的活动实例，也不会向客户端暴露平台登录凭据。
func (s *Server) handleClientPlaylists(w http.ResponseWriter, r *http.Request) {
	authorized, ok := AuthorizedClientAccount(r.Context())
	if !ok {
		writeAPIError(w, http.StatusUnauthorized, "client_unauthorized", "客户端授权已失效，请重新扫码登录")
		return
	}

	response := clientPlaylistsResponse{
		Source:    authorized.Type,
		Playlists: []clientPlaylist{},
	}
	if authorized.Type == account.AccountTypeNetease {
		if !s.neteaseAvailable(w) {
			return
		}
		item, err := s.accounts.CredentialForAccount(r.Context(), authorized.Type, authorized.AccountID)
		if err != nil {
			s.clientAccountError(w, err)
			return
		}
		playlists, err := s.netease.GetUserPlaylists(r.Context(), item.Credential, item.AccountID)
		if err != nil {
			s.neteaseMediaError(w, "读取网易云账号歌单失败", err)
			return
		}
		for _, playlist := range playlists {
			songIDs := playlist.SongIDs
			if songIDs == nil {
				songIDs = []int64{}
			}
			response.Playlists = append(response.Playlists, clientPlaylist{
				Source:    authorized.Type,
				ID:        playlist.ID,
				Name:      playlist.Name,
				CoverURL:  playlist.CoverURL,
				SongCount: playlist.SongCount,
				SongIDs:   songIDs,
			})
		}
		w.Header().Set("Cache-Control", "no-store")
		writeJSON(w, http.StatusOK, response)
		return
	}

	playlists, err := s.accounts.ReadAccountPlaylists(r.Context(), authorized.AccountID)
	if err != nil {
		switch {
		case errors.Is(err, account.ErrInvalidClientAuthorization):
			writeAPIError(w, http.StatusUnauthorized, "client_unauthorized", "客户端授权已失效，请重新扫码登录")
		case errors.Is(err, account.ErrAccountLoginExpired):
			writeAPIError(w, http.StatusUnauthorized, "client_unauthorized", "QQ 音乐登录态已过期，请重新扫码授权")
		case errors.Is(err, account.ErrNoAccount):
			writeAPIError(w, http.StatusUnauthorized, "client_unauthorized", "客户端授权账号不存在")
		default:
			s.logger.Printf("读取客户端授权账号歌单失败: %v", err)
			writeAPIError(w, http.StatusInternalServerError, "playlist_fetch_failed", "读取 QQ 音乐歌单失败")
		}
		return
	}

	response.Playlists = make([]clientPlaylist, 0, len(playlists))
	for _, playlist := range playlists {
		songIDs := playlist.SongIDs
		if songIDs == nil {
			songIDs = []int64{}
		}
		response.Playlists = append(response.Playlists, clientPlaylist{
			Source:    authorized.Type,
			ID:        playlist.ID,
			Name:      playlist.Name,
			CoverURL:  playlist.CoverURL,
			SongCount: playlist.SongCount,
			SongIDs:   songIDs,
		})
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, response)
}

func (s *Server) clientAccountError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, account.ErrAccountLoginExpired), errors.Is(err, account.ErrInvalidClientAuthorization):
		writeAPIError(w, http.StatusUnauthorized, "client_unauthorized", "客户端授权已失效，请重新授权")
	case errors.Is(err, account.ErrNoAccount):
		writeAPIError(w, http.StatusUnauthorized, "client_unauthorized", "客户端授权账号不存在")
	default:
		s.internalError(w, "读取客户端授权账号失败", err)
	}
}
