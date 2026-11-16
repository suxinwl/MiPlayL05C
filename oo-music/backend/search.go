package oomusic

import (
	"context"
	"errors"
	"strings"
)

// SearchType 是 QQ 音乐桌面搜索接口使用的 search_type 值。
type SearchType int

const (
	// SearchTypeSong 表示搜索歌曲。
	SearchTypeSong SearchType = 0
	// SearchTypeAlbum 表示搜索专辑。
	SearchTypeAlbum SearchType = 2
	// SearchTypeMV 表示搜索 MV。
	SearchTypeMV SearchType = 4
	// SearchTypeLyric 表示搜索歌词。
	SearchTypeLyric SearchType = 7
	// SearchTypeUser 表示搜索用户。
	SearchTypeUser SearchType = 8
)

// SearchOptions 配置 Search 调用。
type SearchOptions struct {
	// Query 是非空的搜索关键词。
	Query string
	// Type 选择搜索类别，零值对应 SearchTypeSong。
	Type SearchType
	// SearchID 可选，用于指定 QQ 音乐埋点 ID；
	// 留空时 SDK 会自动生成随机数字 ID。
	SearchID string
	// Page 是从 1 开始的页码，小于 1 时使用第 1 页。
	Page int
	// PageSize 是每页结果数，小于 1 时使用 10。
	PageSize int
	// RemotePlace 是埋点来源，留空时使用 "yqq.yqq.yqq"。
	RemotePlace string
}

// Search 调用 music.search.SearchCgiService/DoSearchForQQMusicDesktop，
// 返回歌曲、专辑、MV、歌词或用户的原始 JSON 数据。
func (c *Client) Search(ctx context.Context, options SearchOptions) (*CallResult, error) {
	query := strings.TrimSpace(options.Query)
	if query == "" {
		return nil, errors.New("search query must not be empty")
	}
	searchID := strings.TrimSpace(options.SearchID)
	if searchID == "" {
		var err error
		searchID, err = randomDigits(17)
		if err != nil {
			return nil, err
		}
	}
	remotePlace := firstNonEmpty(strings.TrimSpace(options.RemotePlace), "yqq.yqq.yqq")
	return c.CallQQ(ctx, "music.search.SearchCgiService", "DoSearchForQQMusicDesktop", map[string]any{
		"remoteplace":  remotePlace,
		"searchid":     searchID,
		"search_type":  int(options.Type),
		"query":        query,
		"page_num":     defaultPositive(options.Page, 1),
		"num_per_page": defaultPositive(options.PageSize, 10),
	})
}

// SearchSongs 是固定使用 SearchTypeSong 的便捷搜索方法。
func (c *Client) SearchSongs(ctx context.Context, query string, page, pageSize int) (*CallResult, error) {
	return c.Search(ctx, SearchOptions{
		Query:    query,
		Type:     SearchTypeSong,
		Page:     page,
		PageSize: pageSize,
	})
}

// GetHotKeys 调用 music.musicsearch.HotkeyService/GetHotkeyForQQMusicMobile，
// 返回 QQ 音乐当前搜索热词。
func (c *Client) GetHotKeys(ctx context.Context) (*CallResult, error) {
	searchID, err := randomDigits(17)
	if err != nil {
		return nil, err
	}
	return c.CallQQ(ctx, "music.musicsearch.HotkeyService", "GetHotkeyForQQMusicMobile", map[string]any{
		"searchid":    searchID,
		"remoteplace": "txt.yqq.top",
		"from":        "yqqweb",
	})
}
