package oomusic

import (
	"context"
	"errors"
)

// TrackInfoOptions 配置 GetTrackInfo 调用。
type TrackInfoOptions struct {
	// IDs 包含 QQ 音乐数字歌曲 ID。
	IDs []int64
	// Types 可选，必须与 IDs 长度一致；缺省值会按网页端行为编码为 0。
	Types []int
}

// GetTrackInfo 调用 music.trackInfo.UniformRuleCtrl/CgiGetTrackInfo，
// 返回歌曲元数据，包含 data.tracks[].file 中的可用音质信息。
func (c *Client) GetTrackInfo(ctx context.Context, options TrackInfoOptions) (*CallResult, error) {
	if len(options.IDs) == 0 {
		return nil, errors.New("track IDs must not be empty")
	}
	types := options.Types
	if len(types) == 0 {
		types = make([]int, len(options.IDs))
	}
	if len(types) != len(options.IDs) {
		return nil, errors.New("track types and IDs must have the same length")
	}
	return c.CallQQ(ctx, "music.trackInfo.UniformRuleCtrl", "CgiGetTrackInfo", map[string]any{
		"types": types,
		"ids":   options.IDs,
	})
}
