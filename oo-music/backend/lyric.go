package oomusic

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// LyricOptions 配置 GetLyric 调用。
type LyricOptions struct {
	// SongMID 是必填的 14 位 QQ 音乐歌曲 MID。
	SongMID string
	// SongID 是可选数字歌曲 ID，非零值会发送以提升匹配准确度。
	SongID int64
}

// RawLyricFields 保留 QQ 音乐返回的原始 base64 歌词字段。
type RawLyricFields struct {
	// Lyric 是原始 base64 编码歌词文本。
	Lyric string
	// Trans 是原始 base64 编码翻译文本。
	Trans string
	// Roma 是原始 base64 编码罗马音文本。
	Roma string
}

// LyricResult 包含 GetPlayLyricInfo 解码后的歌词数据。
type LyricResult struct {
	// Code 是接口业务状态码。
	Code int
	// SongName 是接口返回的歌曲名。
	SongName string
	// SingerName 是接口返回的歌手名。
	SingerName string
	// Lyric 是解码后的 LRC 歌词文本。
	Lyric string
	// Trans 是解码后的翻译歌词文本。
	Trans string
	// Roma 是解码后的罗马音文本。
	Roma string
	// Raw 包含原始 base64 字段。
	Raw RawLyricFields
}

// GetLyric 调用 music.musichallSong.PlayLyricInfo/GetPlayLyricInfo，
// 将歌词、翻译和罗马音从 base64 解码为 UTF-8 文本。
func (c *Client) GetLyric(ctx context.Context, options LyricOptions) (*LyricResult, error) {
	songMID := strings.TrimSpace(options.SongMID)
	if songMID == "" {
		return nil, errors.New("song MID must not be empty")
	}
	param := map[string]any{"songMID": songMID}
	if options.SongID != 0 {
		param["songID"] = options.SongID
	}
	call, err := c.CallQQ(ctx, "music.musichallSong.PlayLyricInfo", "GetPlayLyricInfo", param)
	if err != nil {
		return nil, err
	}
	var data struct {
		SongName   string `json:"songName"`
		SingerName string `json:"singerName"`
		Lyric      string `json:"lyric"`
		Trans      string `json:"trans"`
		Roma       string `json:"roma"`
	}
	if len(call.Data) > 0 {
		if err := json.Unmarshal(call.Data, &data); err != nil {
			return nil, fmt.Errorf("decode lyric data: %w", err)
		}
	}
	return &LyricResult{
		Code:       call.Code,
		SongName:   data.SongName,
		SingerName: data.SingerName,
		Lyric:      decodeBase64Text(data.Lyric),
		Trans:      decodeBase64Text(data.Trans),
		Roma:       decodeBase64Text(data.Roma),
		Raw: RawLyricFields{
			Lyric: data.Lyric,
			Trans: data.Trans,
			Roma:  data.Roma,
		},
	}, nil
}

func decodeBase64Text(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	decoders := []*base64.Encoding{
		base64.StdEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.RawURLEncoding,
	}
	for _, decoder := range decoders {
		if decoded, err := decoder.DecodeString(value); err == nil {
			return string(decoded)
		}
	}
	return ""
}
