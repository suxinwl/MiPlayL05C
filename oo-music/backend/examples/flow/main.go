package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"html/template"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	oomusic "github.com/rankgice/oo-music"
)

const defaultQuery = "周杰伦 晴天"

type options struct {
	query       string
	page        int
	pageSize    int
	pick        int
	quality     oomusic.Quality
	lyricLines  int
	playerPath  string
	openPlayer  bool
	showDetails bool
}

type namedSinger struct {
	Name string `json:"name"`
}

type albumInfo struct {
	ID   int64  `json:"id"`
	Mid  string `json:"mid"`
	Name string `json:"name"`
}

type mvRef struct {
	ID   int64  `json:"id"`
	VID  string `json:"vid"`
	Name string `json:"name"`
}

type searchSong struct {
	ID       int64         `json:"id"`
	Mid      string        `json:"mid"`
	Name     string        `json:"name"`
	Title    string        `json:"title"`
	Subtitle string        `json:"subtitle"`
	Interval int           `json:"interval"`
	Singers  []namedSinger `json:"singer"`
	Album    albumInfo     `json:"album"`
	MV       mvRef         `json:"mv"`
	VS       []string      `json:"vs"`
}

type searchResponse struct {
	Body struct {
		Song struct {
			List []searchSong `json:"list"`
		} `json:"song"`
	} `json:"body"`
}

type trackFile struct {
	Size128MP3 int64 `json:"size_128mp3"`
	Size320MP3 int64 `json:"size_320mp3"`
	SizeFLAC   int64 `json:"size_flac"`
	Size96AAC  int64 `json:"size_96aac"`
}

type trackDetail struct {
	ID         int64         `json:"id"`
	Mid        string        `json:"mid"`
	Name       string        `json:"name"`
	Title      string        `json:"title"`
	Subtitle   string        `json:"subtitle"`
	Interval   int           `json:"interval"`
	TimePublic string        `json:"time_public"`
	Singers    []namedSinger `json:"singer"`
	Album      albumInfo     `json:"album"`
	MV         mvRef         `json:"mv"`
	VS         []string      `json:"vs"`
	File       trackFile     `json:"file"`
}

type trackResponse struct {
	Tracks []trackDetail `json:"tracks"`
}

type mvInfo struct {
	VID              string        `json:"vid"`
	Name             string        `json:"name"`
	Desc             string        `json:"desc"`
	CoverPic         string        `json:"cover_pic"`
	Duration         int           `json:"duration"`
	PlayCount        int64         `json:"playcnt"`
	PublishDate      int64         `json:"pubdate"`
	PlayForbidReason int           `json:"play_forbid_reason"`
	Singers          []namedSinger `json:"singers"`
}

type mvStream struct {
	URL         []string `json:"url"`
	FreeflowURL []string `json:"freeflow_url"`
	CommURL     []string `json:"comm_url"`
	URLPath     string   `json:"urlPath"`
	CN          string   `json:"cn"`
	M3U8        string   `json:"m3u8"`
	Code        int      `json:"code"`
	FileType    int      `json:"filetype"`
	FileSize    int64    `json:"fileSize"`
	Expire      int      `json:"expire"`
}

type mvURLData struct {
	MP4 []mvStream `json:"mp4"`
	HLS []mvStream `json:"hls"`
}

type mvResult struct {
	Info   mvInfo
	Stream mvStream
	URL    string
}

type playerData struct {
	Title        string
	Singers      string
	Album        string
	PublicDate   string
	Duration     string
	CoverURL     string
	AudioURL     string
	AudioQuality string
	Lyric        string
	MVName       string
	MVDesc       string
	MVCoverURL   string
	MVURL        string
	HasMV        bool
	GeneratedAt  string
}

func main() {
	var (
		page       int
		pageSize   int
		pick       int
		quality    string
		lyricLines int
		playerPath string
		openPlayer bool
	)

	flag.IntVar(&page, "page", 1, "搜索结果页码，从 1 开始")
	flag.IntVar(&pageSize, "page-size", 10, "每页搜索结果数")
	flag.IntVar(&pick, "pick", 1, "选择第几条搜索结果，从 1 开始")
	flag.StringVar(&quality, "quality", "320mp3", "首选音质: 320mp3, flac, master, 128mp3, 96aac")
	flag.IntVar(&lyricLines, "lyric-lines", 30, "终端展示的歌词行数；0 表示全部")
	flag.StringVar(&playerPath, "player", "", "生成播放器 HTML 的路径；留空且指定 -open 时写入临时文件")
	flag.BoolVar(&openPlayer, "open", false, "生成并在默认浏览器中打开播放器")
	flag.Usage = func() {
		fmt.Fprintf(flag.CommandLine.Output(), "用法: go run ./examples/flow [flags] [歌曲关键词]\n\n")
		fmt.Fprintln(flag.CommandLine.Output(), "示例默认使用匿名模式；SDK 调用方可通过 oomusic.WithCredentials 显式配置账号。")
		fmt.Fprintln(flag.CommandLine.Output(), "\nflags:")
		flag.PrintDefaults()
	}
	flag.Parse()

	query := strings.TrimSpace(strings.Join(flag.Args(), " "))
	if query == "" {
		query = defaultQuery
	}
	parsedQuality, err := parseQuality(quality)
	if err != nil {
		fatalf("%v", err)
	}

	client, err := newClient()
	if err != nil {
		fatalf("创建客户端: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()

	err = run(ctx, client, options{
		query:       query,
		page:        page,
		pageSize:    pageSize,
		pick:        pick,
		quality:     parsedQuality,
		lyricLines:  lyricLines,
		playerPath:  playerPath,
		openPlayer:  openPlayer,
		showDetails: true,
	})
	if err != nil {
		fatalf("%v", err)
	}
}

func newClient() (*oomusic.Client, error) {
	return oomusic.NewClient(oomusic.WithRequestTimeout(25 * time.Second))
}

func run(ctx context.Context, client *oomusic.Client, opts options) error {
	if opts.page < 1 {
		return errors.New("page 必须大于等于 1")
	}
	if opts.pageSize < 1 {
		return errors.New("page-size 必须大于等于 1")
	}

	loginMode := "匿名模式"
	if client.IsLoggedIn() {
		loginMode = "登录模式"
	}
	fmt.Printf("QQ 音乐完整流程 Demo（%s）\n", loginMode)
	fmt.Printf("搜索关键词: %s\n\n", opts.query)

	fmt.Println("== 1. 搜索歌曲 ==")
	searchResult, err := client.SearchSongs(ctx, opts.query, opts.page, opts.pageSize)
	if err != nil {
		return fmt.Errorf("搜索歌曲: %w", err)
	}
	if err := ensureCode("搜索歌曲", searchResult); err != nil {
		return err
	}
	var search searchResponse
	if err := json.Unmarshal(searchResult.Data, &search); err != nil {
		return fmt.Errorf("解析搜索结果: %w", err)
	}
	if len(search.Body.Song.List) == 0 {
		return errors.New("没有搜索到歌曲，请更换关键词或检查登录态")
	}
	for i, song := range search.Body.Song.List {
		fmt.Printf("[%2d] %s - %s", i+1, song.Name, joinSingers(song.Singers))
		if song.Album.Name != "" {
			fmt.Printf("  《%s》", song.Album.Name)
		}
		if song.MV.VID != "" {
			fmt.Print("  [有 MV]")
		}
		fmt.Printf("  (歌曲ID=%d, MID=%s)\n", song.ID, song.Mid)
	}
	if opts.pick < 1 || opts.pick > len(search.Body.Song.List) {
		return fmt.Errorf("pick=%d 超出搜索结果范围 1-%d", opts.pick, len(search.Body.Song.List))
	}
	selected := search.Body.Song.List[opts.pick-1]
	fmt.Printf("\n已选择: %s - %s\n\n", selected.Name, joinSingers(selected.Singers))

	fmt.Println("== 2. 歌曲详情 ==")
	trackResult, err := client.GetTrackInfo(ctx, oomusic.TrackInfoOptions{
		IDs:   []int64{selected.ID},
		Types: []int{0},
	})
	if err != nil {
		return fmt.Errorf("查询歌曲详情: %w", err)
	}
	if err := ensureCode("歌曲详情", trackResult); err != nil {
		return err
	}
	var tracks trackResponse
	if err := json.Unmarshal(trackResult.Data, &tracks); err != nil {
		return fmt.Errorf("解析歌曲详情: %w", err)
	}
	if len(tracks.Tracks) == 0 {
		return errors.New("歌曲详情为空")
	}
	track := tracks.Tracks[0]
	if track.Mid == "" {
		track.Mid = selected.Mid
	}
	if track.MV.VID == "" {
		track.MV = selected.MV
	}
	printTrackDetails(track)

	fmt.Println("\n== 3. 播放地址 ==")
	playable := &oomusic.PlayableResult{Reason: "NO_VS"}
	if len(track.VS) > 0 && track.VS[0] != "" {
		qualities := qualityPreference(opts.quality)
		playable, err = client.ResolvePlayableBySong(ctx, oomusic.ResolvePlayableBySongOptions{
			SongMID:         track.Mid,
			SongID:          track.ID,
			VSFirst:         track.VS[0],
			PreferQualities: qualities,
		})
		if err != nil {
			fmt.Printf("查询播放地址失败: %v\n", err)
			playable = &oomusic.PlayableResult{Reason: "REQUEST_FAILED"}
		}
	} else {
		fmt.Println("歌曲详情未返回 vs，跳过播放地址查询")
	}
	fmt.Printf("首选音质: %s\n", opts.quality)
	if playable.URL == "" {
		fmt.Printf("未取得可播放地址，原因: %s\n", emptyFallback(playable.Reason, "UNKNOWN"))
		for _, attempt := range playable.Tried {
			fmt.Printf("  - %-8s %s\n", attempt.Quality, attempt.Reason)
		}
	} else {
		fmt.Printf("实际音质: %s\n", displayQuality(playable.Quality))
		fmt.Printf("播放地址: %s\n", playable.URL)
	}

	fmt.Println("\n== 4. 歌词 ==")
	var lyric oomusic.LyricResult
	lyricResult, lyricErr := client.GetLyric(ctx, oomusic.LyricOptions{SongMID: track.Mid, SongID: track.ID})
	if lyricErr != nil {
		fmt.Printf("获取歌词失败: %v\n", lyricErr)
	} else if lyricResult.Code != 0 || lyricResult.Lyric == "" {
		fmt.Printf("歌词不可用，业务码: %d\n", lyricResult.Code)
	} else {
		lyric = *lyricResult
		fmt.Printf("歌曲: %s - %s\n", lyric.SongName, lyric.SingerName)
		printLyric(lyric.Lyric, opts.lyricLines)
		if lyric.Trans != "" {
			fmt.Println("--- 翻译 ---")
			printLyric(lyric.Trans, opts.lyricLines)
		}
	}

	fmt.Println("\n== 5. 关联 MV ==")
	mv, err := fetchMV(ctx, client, track.MV.VID)
	if err != nil {
		fmt.Printf("MV 不可用: %v\n", err)
	} else {
		printMV(mv)
	}

	shouldWritePlayer := opts.openPlayer || strings.TrimSpace(opts.playerPath) != ""
	if shouldWritePlayer {
		path, err := writePlayerFile(opts.playerPath, playerData{
			Title:        firstNonEmpty(track.Name, track.Title, selected.Name),
			Singers:      joinSingers(firstSingers(track.Singers, selected.Singers)),
			Album:        firstNonEmpty(track.Album.Name, selected.Album.Name),
			PublicDate:   track.TimePublic,
			Duration:     formatDuration(track.Interval),
			CoverURL:     albumCoverURL(firstNonEmpty(track.Album.Mid, selected.Album.Mid)),
			AudioURL:     playable.URL,
			AudioQuality: displayQuality(playable.Quality),
			Lyric:        combineLyrics(lyric.Lyric, lyric.Trans),
			MVName:       mv.Info.Name,
			MVDesc:       mv.Info.Desc,
			MVCoverURL:   normalizeURL(firstNonEmpty(mv.Info.CoverPic, albumCoverURL(track.Album.Mid))),
			MVURL:        mv.URL,
			HasMV:        mv.URL != "",
			GeneratedAt:  time.Now().Format("2006-01-02 15:04:05"),
		})
		if err != nil {
			fmt.Printf("生成播放器失败: %v\n", err)
		} else {
			fmt.Printf("\n播放器网页: %s\n", path)
			if opts.openPlayer {
				if err := openFile(path); err != nil {
					fmt.Printf("自动打开失败: %v\n", err)
				}
			}
		}
	}

	return nil
}

func ensureCode(label string, result *oomusic.CallResult) error {
	if result.Code != 0 {
		return fmt.Errorf("%s返回业务码 %d: %s", label, result.Code, truncateJSON(result.Data, 500))
	}
	return nil
}

func printTrackDetails(track trackDetail) {
	fmt.Printf("歌名: %s\n", firstNonEmpty(track.Name, track.Title))
	if track.Subtitle != "" {
		fmt.Printf("副标题: %s\n", track.Subtitle)
	}
	fmt.Printf("歌手: %s\n", joinSingers(track.Singers))
	fmt.Printf("专辑: %s (%s)\n", track.Album.Name, track.Album.Mid)
	fmt.Printf("发行日期: %s\n", emptyFallback(track.TimePublic, "未知"))
	fmt.Printf("时长: %s\n", formatDuration(track.Interval))
	fmt.Printf("歌曲ID: %d\n", track.ID)
	fmt.Printf("歌曲 MID: %s\n", track.Mid)
	fmt.Printf("播放文件名基准 vs[0]: %s\n", track.VS[0])
	fmt.Printf("可用音质: %s\n", availableQualities(track.File))
}

func printMV(mv mvResult) {
	fmt.Printf("标题: %s\n", emptyFallback(mv.Info.Name, "未命名 MV"))
	if mv.Info.Desc != "" {
		fmt.Printf("描述: %s\n", mv.Info.Desc)
	}
	fmt.Printf("歌手: %s\n", joinSingers(mv.Info.Singers))
	fmt.Printf("MV VID: %s\n", mv.Info.VID)
	fmt.Printf("时长: %s\n", formatDuration(mv.Info.Duration))
	if mv.Info.PlayCount > 0 {
		fmt.Printf("播放量: %d\n", mv.Info.PlayCount)
	}
	if mv.Info.PublishDate > 0 {
		fmt.Printf("发布日期: %s\n", time.Unix(mv.Info.PublishDate, 0).Format("2006-01-02"))
	}
	if mv.Info.CoverPic != "" {
		fmt.Printf("封面: %s\n", normalizeURL(mv.Info.CoverPic))
	}
	if mv.URL == "" {
		fmt.Println("当前没有可用的 MV 播放地址")
		return
	}
	fmt.Printf("清晰度档位: %d，文件大小: %s，地址有效期: %s\n", mv.Stream.FileType, formatBytes(mv.Stream.FileSize), formatExpiry(mv.Stream.Expire))
	fmt.Printf("MV 播放地址: %s\n", mv.URL)
}

func fetchMV(ctx context.Context, client *oomusic.Client, vid string) (mvResult, error) {
	vid = strings.TrimSpace(vid)
	if vid == "" {
		return mvResult{}, errors.New("这首歌没有关联 MV")
	}
	infoResult, err := client.CallQQ(ctx, "music.video.VideoData", "get_video_info_batch", map[string]any{
		"vidlist": []string{vid},
		"required": []string{
			"vid", "type", "sid", "cover_pic", "duration", "singers", "video_pay", "name",
			"desc", "playcnt", "pubdate", "isfav", "fileid", "filesize_v2", "pay", "play_forbid_reason",
		},
	})
	if err != nil {
		return mvResult{}, fmt.Errorf("查询 MV 信息: %w", err)
	}
	if err := ensureCode("MV 信息", infoResult); err != nil {
		return mvResult{}, err
	}
	var infos map[string]mvInfo
	if err := json.Unmarshal(infoResult.Data, &infos); err != nil {
		return mvResult{}, fmt.Errorf("解析 MV 信息: %w", err)
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
		return mvResult{}, errors.New("MV 信息为空")
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
		return mvResult{}, fmt.Errorf("查询 MV 播放地址: %w", err)
	}
	if err := ensureCode("MV 播放地址", urlResult); err != nil {
		return mvResult{}, err
	}
	var urls map[string]mvURLData
	if err := json.Unmarshal(urlResult.Data, &urls); err != nil {
		return mvResult{}, fmt.Errorf("解析 MV 播放地址: %w", err)
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
		return mvResult{}, errors.New("MV 播放地址为空")
	}
	stream, playURL, ok := pickBestMVStream(data)
	if !ok {
		return mvResult{}, errors.New("服务端未返回可播放的 MV 地址，可能受版权、地区或账号权限限制")
	}
	return mvResult{Info: info, Stream: stream, URL: playURL}, nil
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
	if stream.M3U8 != "" {
		return stream.M3U8, true
	}
	return "", false
}

func qualityPreference(preferred oomusic.Quality) []oomusic.Quality {
	order := []oomusic.Quality{preferred}
	for _, quality := range oomusic.DefaultQualityOrder {
		if quality == preferred {
			continue
		}
		order = append(order, quality)
	}
	return order
}

func parseQuality(value string) (oomusic.Quality, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "master", "rs02":
		return oomusic.QualityMaster, nil
	case "flac", "lossless":
		return oomusic.QualityFLAC, nil
	case "320", "320mp3":
		return oomusic.QualityMP3320, nil
	case "128", "128mp3":
		return oomusic.QualityMP3128, nil
	case "aac", "96aac":
		return oomusic.QualityAAC96, nil
	default:
		return "", fmt.Errorf("未知音质 %q", value)
	}
}

func printLyric(lyric string, maxLines int) {
	lines := strings.Split(strings.TrimSpace(lyric), "\n")
	limit := len(lines)
	if maxLines > 0 && limit > maxLines {
		limit = maxLines
	}
	for _, line := range lines[:limit] {
		fmt.Println(line)
	}
	if limit < len(lines) {
		fmt.Printf("... 已省略 %d 行，可使用 -lyric-lines 0 查看全部\n", len(lines)-limit)
	}
}

func writePlayerFile(path string, data playerData) (string, error) {
	createdTemp := false
	path = strings.TrimSpace(path)
	if path == "" {
		file, err := os.CreateTemp("", "qqmusic-demo-*.html")
		if err != nil {
			return "", err
		}
		path = file.Name()
		if err := file.Close(); err != nil {
			return "", err
		}
		createdTemp = true
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(absolute), 0o755); err != nil {
		return "", err
	}
	file, err := os.OpenFile(absolute, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return "", err
	}
	defer file.Close()
	if err := renderPlayer(file, data); err != nil {
		if createdTemp {
			_ = os.Remove(absolute)
		}
		return "", err
	}
	return absolute, nil
}

func renderPlayer(w io.Writer, data playerData) error {
	tmpl, err := template.New("player").Parse(playerHTML)
	if err != nil {
		return err
	}
	return tmpl.Execute(w, data)
}

func openFile(path string) error {
	var command *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		command = exec.Command("open", path)
	case "windows":
		command = exec.Command("rundll32", "url.dll,FileProtocolHandler", path)
	default:
		command = exec.Command("xdg-open", path)
	}
	return command.Start()
}

func albumCoverURL(mid string) string {
	if strings.TrimSpace(mid) == "" {
		return ""
	}
	return fmt.Sprintf("https://y.gtimg.cn/music/photo_new/T002R300x300M000%s.jpg", mid)
}

func normalizeURL(value string) string {
	return strings.Replace(value, "http://", "https://", 1)
}

func joinSingers(singers []namedSinger) string {
	names := make([]string, 0, len(singers))
	for _, singer := range singers {
		if name := strings.TrimSpace(singer.Name); name != "" {
			names = append(names, name)
		}
	}
	if len(names) == 0 {
		return "未知歌手"
	}
	return strings.Join(names, "/")
}

func firstSingers(primary, fallback []namedSinger) []namedSinger {
	if len(primary) > 0 {
		return primary
	}
	return fallback
}

func availableQualities(file trackFile) string {
	values := make([]string, 0, 4)
	if file.SizeFLAC > 0 {
		values = append(values, "FLAC")
	}
	if file.Size320MP3 > 0 {
		values = append(values, "320kbps MP3")
	}
	if file.Size128MP3 > 0 {
		values = append(values, "128kbps MP3")
	}
	if file.Size96AAC > 0 {
		values = append(values, "96kbps AAC")
	}
	if len(values) == 0 {
		return "未返回音质信息"
	}
	return strings.Join(values, "、")
}

func displayQuality(quality oomusic.Quality) string {
	switch quality {
	case oomusic.QualityMaster:
		return "master / RS02"
	case oomusic.QualityFLAC:
		return "FLAC"
	case oomusic.QualityMP3320:
		return "320kbps MP3"
	case oomusic.QualityMP3128:
		return "128kbps MP3"
	case oomusic.QualityAAC96:
		return "96kbps AAC"
	case "":
		return "无"
	default:
		return string(quality)
	}
}

func formatDuration(seconds int) string {
	if seconds <= 0 {
		return "未知"
	}
	return fmt.Sprintf("%02d:%02d", seconds/60, seconds%60)
}

func formatExpiry(seconds int) string {
	if seconds <= 0 {
		return "未知"
	}
	if seconds%3600 == 0 {
		return fmt.Sprintf("%d 小时", seconds/3600)
	}
	return fmt.Sprintf("%.1f 小时", float64(seconds)/3600)
}

func formatBytes(value int64) string {
	if value <= 0 {
		return "未知"
	}
	const (
		kib = 1024
		mib = 1024 * kib
		gib = 1024 * mib
	)
	switch {
	case value >= gib:
		return fmt.Sprintf("%.2f GiB", float64(value)/gib)
	case value >= mib:
		return fmt.Sprintf("%.2f MiB", float64(value)/mib)
	default:
		return fmt.Sprintf("%.2f KiB", float64(value)/kib)
	}
}

func combineLyrics(lyric, trans string) string {
	if lyric == "" {
		return "暂无歌词"
	}
	if trans == "" {
		return lyric
	}
	return lyric + "\n\n【翻译】\n" + trans
}

func truncateJSON(data []byte, limit int) string {
	text := strings.TrimSpace(string(data))
	if limit <= 0 || len(text) <= limit {
		return text
	}
	return text[:limit] + "..."
}

func emptyFallback(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}

const playerHTML = `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{.Title}} - QQ 音乐 Demo</title>
  <style>
    :root { color-scheme: dark; --bg:#121212; --panel:#1d1d1f; --muted:#9b9ba1; --accent:#31c27c; }
    * { box-sizing: border-box; }
    body { margin:0; background:linear-gradient(180deg,#1b3529 0,#121212 420px); color:#f5f5f7; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
    main { width:min(1080px,calc(100% - 32px)); margin:0 auto; padding:42px 0 64px; }
    .hero { display:grid; grid-template-columns:220px 1fr; gap:30px; align-items:end; margin-bottom:34px; }
    .cover { width:220px; aspect-ratio:1; object-fit:cover; border-radius:12px; box-shadow:0 18px 50px #0009; background:#29292d; }
    h1 { font-size:clamp(30px,5vw,58px); margin:0 0 10px; line-height:1.05; }
    .meta { color:var(--muted); line-height:1.8; }
    .panel { background:var(--panel); border:1px solid #303034; border-radius:16px; padding:22px; margin:18px 0; }
    h2 { margin:0 0 16px; font-size:20px; }
    audio,video { width:100%; border-radius:10px; background:#000; }
    video { max-height:70vh; }
    .notice { color:var(--muted); font-size:13px; margin-top:10px; }
    pre { white-space:pre-wrap; overflow-wrap:anywhere; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; line-height:1.75; color:#ddd; margin:0; }
    a { color:var(--accent); }
    @media (max-width: 680px) { .hero { grid-template-columns:1fr; } .cover { width:160px; } }
  </style>
</head>
<body>
<main>
  <section class="hero">
    {{if .CoverURL}}<img class="cover" src="{{.CoverURL}}" alt="专辑封面">{{else}}<div class="cover"></div>{{end}}
    <div>
      <h1>{{.Title}}</h1>
      <div class="meta">
        <div>{{.Singers}}</div>
        {{if .Album}}<div>专辑：{{.Album}}</div>{{end}}
        <div>{{if .PublicDate}}发行：{{.PublicDate}} · {{end}}时长：{{.Duration}}</div>
        {{if .AudioQuality}}<div>音质：{{.AudioQuality}}</div>{{end}}
      </div>
    </div>
  </section>

  <section class="panel">
    <h2>音频播放</h2>
    {{if .AudioURL}}
    <audio controls preload="metadata" src="{{.AudioURL}}"></audio>
    <div class="notice"><a href="{{.AudioURL}}" target="_blank" rel="noreferrer">在新窗口打开音频</a></div>
    {{else}}<div class="notice">当前账号未取得音频播放地址。</div>{{end}}
  </section>

  <section class="panel">
    <h2>MV</h2>
    {{if .HasMV}}
    <video controls preload="metadata" poster="{{.MVCoverURL}}" src="{{.MVURL}}"></video>
    <h3>{{.MVName}}</h3>
    {{if .MVDesc}}<div class="notice">{{.MVDesc}}</div>{{end}}
    <div class="notice"><a href="{{.MVURL}}" target="_blank" rel="noreferrer">在新窗口打开 MV</a></div>
    {{else}}<div class="notice">没有可用的关联 MV 播放地址。</div>{{end}}
  </section>

  <section class="panel">
    <h2>歌词</h2>
    <pre>{{.Lyric}}</pre>
  </section>

  <div class="notice">生成时间：{{.GeneratedAt}}。页面包含临时签名地址，请勿公开分享。</div>
</main>
</body>
</html>`
