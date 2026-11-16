package oomusic

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// Quality 标识 QQ 音乐的音频交付音质。
type Quality string

const (
	// QualityMaster 请求网页端使用的 RS02 MP3 变体。
	QualityMaster Quality = "master"
	// QualityFLAC 请求无损 FLAC。
	QualityFLAC Quality = "flac"
	// QualityMP3320 请求 320 kbps MP3。
	QualityMP3320 Quality = "320mp3"
	// QualityMP3128 请求 128 kbps MP3。
	QualityMP3128 Quality = "128mp3"
	// QualityAAC96 请求 96 kbps AAC。
	QualityAAC96 Quality = "96aac"
)

// ErrSongNotFound 表示 CgiGetTrackInfo 未返回匹配歌曲。
var ErrSongNotFound = errors.New("QQ Music song was not found")

// ErrMissingFilename 表示构造播放文件名所需的参数不足。
var ErrMissingFilename = errors.New("QQ Music playback filename is missing")

// DefaultQualityOrder 是 ResolvePlayableBySong 使用的默认音质回退顺序。
// 默认优先使用兼容性和完整性更稳定的 320 kbps MP3；母带资源可能只返回试听片段。
var DefaultQualityOrder = []Quality{
	QualityMP3320,
	QualityMP3128,
	QualityAAC96,
	QualityFLAC,
	QualityMaster,
}

type qualitySpec struct {
	prefix  string
	ext     string
	sizeKey string
}

var qualitySpecs = map[Quality]qualitySpec{
	QualityMaster: {prefix: "RS02", ext: ".mp3"},
	QualityFLAC:   {prefix: "F000", ext: ".flac", sizeKey: "size_flac"},
	QualityMP3320: {prefix: "M800", ext: ".mp3", sizeKey: "size_320mp3"},
	QualityMP3128: {prefix: "M500", ext: ".mp3", sizeKey: "size_128mp3"},
	QualityAAC96:  {prefix: "C400", ext: ".m4a", sizeKey: "size_96aac"},
}

// ResolvePlaybackURLOptions 配置 ResolvePlaybackURL 调用。
type ResolvePlaybackURLOptions struct {
	// SongMID 是 14 位 QQ 音乐歌曲 MID。
	SongMID string
	// SongType 是数字歌曲类型，通常使用零值即可。
	SongType int
	// Filename 可选，可填写浏览器中捕获的完整播放文件名；
	// 设置后会优先于 VSFirst 和 Quality。
	Filename string
	// VSFirst 是用于构造播放文件名的媒体标识，通常填写 song.vs[0]。
	VSFirst string
	// Quality 决定播放文件名的前缀和扩展名。
	Quality Quality
	// GUID 是可选数字客户端 ID，留空时默认生成 10 位随机数字。
	GUID string
}

// PlaybackURL 是 ResolvePlaybackURL 的返回结果。
type PlaybackURL struct {
	// Code 是 GetEVkey 的业务状态码。
	Code int
	// Filename 是提交给 GetEVkey 的完整文件名。
	Filename string
	// SIP 包含接口返回的 CDN 基础地址。
	SIP []string
	// PURL 是相对播放路径；无权限或无匹配资源时为空。
	PURL string
	// URL 是 SIP[0] 与 PURL 拼接后的播放地址。
	URL string
}

// ResolvePlaybackURL 调用 music.vkey.GetEVkey/GetUrl。
// 该方法不绕过账号权益；不可播放或受限歌曲会返回空 PURL。
func (c *Client) ResolvePlaybackURL(ctx context.Context, options ResolvePlaybackURLOptions) (*PlaybackURL, error) {
	songMID := strings.TrimSpace(options.SongMID)
	if songMID == "" {
		return nil, errors.New("song MID must not be empty")
	}
	filename := strings.TrimSpace(options.Filename)
	if filename == "" {
		if options.VSFirst == "" || options.Quality == "" {
			return nil, ErrMissingFilename
		}
		var err error
		filename, err = BuildFilename(options.VSFirst, options.Quality)
		if err != nil {
			return nil, err
		}
	}
	guid := strings.TrimSpace(options.GUID)
	if guid == "" {
		var err error
		guid, err = randomDigits(10)
		if err != nil {
			return nil, err
		}
	}
	result, err := c.CallQQ(ctx, "music.vkey.GetEVkey", "GetUrl", map[string]any{
		"guid":      guid,
		"songmid":   []string{songMID},
		"songtype":  []int{options.SongType},
		"uin":       c.session.uin,
		"loginflag": boolInt(c.session.isLoggedIn()),
		"platform":  "20",
		"xcdn":      1,
		"filename":  []string{filename},
	})
	if err != nil {
		return nil, err
	}
	var data struct {
		SIP        []string `json:"sip"`
		MidURLInfo []struct {
			PURL string `json:"purl"`
		} `json:"midurlinfo"`
	}
	if len(result.Data) > 0 {
		if err := json.Unmarshal(result.Data, &data); err != nil {
			return nil, fmt.Errorf("decode playback URL data: %w", err)
		}
	}
	playback := &PlaybackURL{Code: result.Code, Filename: filename, SIP: data.SIP}
	if len(data.MidURLInfo) > 0 {
		playback.PURL = data.MidURLInfo[0].PURL
	}
	if playback.PURL != "" && len(playback.SIP) > 0 {
		playback.URL = playback.SIP[0] + playback.PURL
	}
	return playback, nil
}

// ResolvePlayableBySongOptions 配置 ResolvePlayableBySong 调用。
type ResolvePlayableBySongOptions struct {
	// SongMID 是可选歌曲 MID；省略时会用 SongID 查询。
	SongMID string
	// SongID 是数字歌曲 ID，在 SongMID 或 VS 缺失时用于获取元数据。
	SongID int64
	// VSFirst 是可选的 song.vs[0] 值；缺失时会依次回退到
	// file.media_mid 和歌曲 MID。
	VSFirst string
	// PreferQualities 覆盖 DefaultQualityOrder。
	PreferQualities []Quality
	// GUID 是可选数字客户端 ID。
	GUID string
}

// PlaybackAttempt 记录音质回退过程中的一次尝试。
type PlaybackAttempt struct {
	// Quality 是本次尝试的音质。
	Quality Quality
	// Reason 说明本次尝试被跳过或未得到播放路径的原因。
	Reason string
}

// PlayableResult 是 ResolvePlayableBySong 的返回结果。
type PlayableResult struct {
	// PlaybackURL 内嵌最终选中的音频流详情。
	PlaybackURL
	// Quality 是最终选中的音质，无可用音频流时为空。
	Quality Quality
	// Reason 在未找到可播放音质时给出原因。
	Reason string
	// Tried 包含每种音质的回退诊断记录。
	Tried []PlaybackAttempt
}

// ResolvePlayableBySong 按需补齐歌曲元数据，再依次尝试各音质，
// 返回第一个通过 CDN 可用性校验的结果。
func (c *Client) ResolvePlayableBySong(ctx context.Context, options ResolvePlayableBySongOptions) (*PlayableResult, error) {
	songMID := strings.TrimSpace(options.SongMID)
	vsFirst := strings.TrimSpace(options.VSFirst)
	var file trackFile
	if options.SongID != 0 {
		track, err := c.lookupTrack(ctx, options.SongID)
		if err != nil {
			if songMID == "" || vsFirst == "" {
				return nil, err
			}
		} else {
			if songMID == "" {
				songMID = track.Mid
			}
			if vsFirst == "" && len(track.VS) > 0 {
				vsFirst = track.VS[0]
			}
			file = track.File
		}
	} else if songMID == "" {
		return nil, errors.New("song ID is required when song MID is missing")
	}
	if songMID == "" {
		return nil, errors.New("song MID could not be determined")
	}
	if vsFirst == "" && file.MediaMid != "" {
		vsFirst = strings.TrimSpace(file.MediaMid)
	}
	if vsFirst == "" {
		vsFirst = songMID
	}
	if vsFirst == "" {
		return &PlayableResult{Reason: "NO_VS"}, nil
	}
	qualities := options.PreferQualities
	if len(qualities) == 0 {
		qualities = DefaultQualityOrder
	}
	result := &PlayableResult{}
	foundPURL := false
	for _, quality := range qualities {
		spec, ok := qualitySpecs[quality]
		if !ok {
			result.Tried = append(result.Tried, PlaybackAttempt{Quality: quality, Reason: "unknown-quality"})
			continue
		}
		if spec.sizeKey != "" && file.hasInfo() && file.size(spec.sizeKey) <= 0 {
			result.Tried = append(result.Tried, PlaybackAttempt{Quality: quality, Reason: "no-size"})
			continue
		}
		playback, err := c.ResolvePlaybackURL(ctx, ResolvePlaybackURLOptions{
			SongMID: songMID,
			VSFirst: vsFirst,
			Quality: quality,
			GUID:    options.GUID,
		})
		if err != nil {
			return nil, err
		}
		if playback.PURL == "" {
			result.Tried = append(result.Tried, PlaybackAttempt{Quality: quality, Reason: "empty-purl"})
			continue
		}
		foundPURL = true
		if reason := c.probePlaybackURL(ctx, playback.URL); reason != "" {
			result.Tried = append(result.Tried, PlaybackAttempt{Quality: quality, Reason: reason})
			continue
		}
		result.PlaybackURL = *playback
		result.Quality = quality
		return result, nil
	}
	if foundPURL {
		result.Reason = "NO_VALID_AUDIO_SOURCE"
	} else {
		result.Reason = "NO_PLAYABLE_QUALITY"
	}
	return result, nil
}

// probePlaybackURL 使用单字节 Range 请求确认 CDN 文件真实存在。
// 空字符串表示可用；其他返回值是写入回退诊断的原因。
func (c *Client) probePlaybackURL(ctx context.Context, mediaURL string) string {
	if strings.TrimSpace(mediaURL) == "" {
		return "empty-url"
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, mediaURL, nil)
	if err != nil {
		return "cdn-invalid-url"
	}
	request.Header.Set("Range", "bytes=0-0")
	request.Header.Set("Accept", "*/*")
	request.Header.Set("Referer", "https://y.qq.com/")
	request.Header.Set("User-Agent", c.userAgent)
	response, err := c.httpClient.Do(request)
	if err != nil {
		return "cdn-request-failed"
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent {
		return fmt.Sprintf("cdn-http-%d", response.StatusCode)
	}
	if response.ContentLength == 0 {
		return "cdn-empty-response"
	}
	// 只读取一个字节，避免某些 CDN 忽略 Range 时下载完整音频。
	if _, err := io.CopyN(io.Discard, response.Body, 1); err != nil {
		return "cdn-read-failed"
	}
	return ""
}

// BuildFilename 根据媒体标识和音质构造 QQ 音乐播放文件名。
func BuildFilename(vsFirst string, quality Quality) (string, error) {
	vsFirst = strings.TrimSpace(vsFirst)
	if vsFirst == "" {
		return "", ErrMissingFilename
	}
	spec, ok := qualitySpecs[quality]
	if !ok {
		return "", fmt.Errorf("unknown QQ Music quality %q", quality)
	}
	return spec.prefix + vsFirst + spec.ext, nil
}

type trackFile struct {
	MediaMid   string `json:"media_mid"`
	Size128MP3 int64  `json:"size_128mp3"`
	Size320MP3 int64  `json:"size_320mp3"`
	SizeFLAC   int64  `json:"size_flac"`
	Size96AAC  int64  `json:"size_96aac"`
}

func (f trackFile) hasInfo() bool {
	return f.Size128MP3 > 0 || f.Size320MP3 > 0 || f.SizeFLAC > 0 || f.Size96AAC > 0
}

func (f trackFile) size(key string) int64 {
	switch key {
	case "size_128mp3":
		return f.Size128MP3
	case "size_320mp3":
		return f.Size320MP3
	case "size_flac":
		return f.SizeFLAC
	case "size_96aac":
		return f.Size96AAC
	default:
		return 0
	}
}

type trackMetadata struct {
	Mid  string    `json:"mid"`
	VS   []string  `json:"vs"`
	File trackFile `json:"file"`
}

func (c *Client) lookupTrack(ctx context.Context, songID int64) (*trackMetadata, error) {
	result, err := c.GetTrackInfo(ctx, TrackInfoOptions{IDs: []int64{songID}})
	if err != nil {
		return nil, err
	}
	var data struct {
		Tracks []trackMetadata `json:"tracks"`
	}
	if err := json.Unmarshal(result.Data, &data); err != nil {
		return nil, fmt.Errorf("decode track information: %w", err)
	}
	if len(data.Tracks) == 0 {
		return nil, ErrSongNotFound
	}
	return &data.Tracks[0], nil
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}
