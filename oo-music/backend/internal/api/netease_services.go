package api

import (
	"context"

	"github.com/rankgice/oo-music/internal/netease"
)

type neteaseMusicClient interface {
	SearchSongs(context.Context, string, string, int, int) (netease.SearchResult, error)
	GetSongs(context.Context, string, []int64) ([]netease.Song, error)
	ResolveSongURL(context.Context, string, int64, string, bool) (netease.SongURL, error)
	GetLyric(context.Context, string, int64) (netease.Lyric, error)
	GetMV(context.Context, string, int64) (netease.MVInfo, error)
	GetUserPlaylists(context.Context, string, string) ([]netease.UserPlaylist, error)
}

// NeteaseQRService 是客户端网易云扫码登录所需的最小能力。
type NeteaseQRService interface {
	Start(context.Context) (netease.QRStartResult, error)
	Image(string) ([]byte, error)
	Poll(context.Context, string) (netease.QRPollResult, error)
	Cancel(string) error
}
