package netease

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestClientSearchSongsNormalizesCloudSearchResult(t *testing.T) {
	client := newMusicTestClient(t, func(r *http.Request) string {
		if r.URL.Path != "/weapi/cloudsearch/pc" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		return `{
			"code":200,
			"result":{
				"songCount":1,
				"songs":[{
					"id":186016,
					"name":"晴天",
					"ar":[{"name":"周杰伦"}],
					"al":{"id":18875,"name":"叶惠美","picUrl":"http://p1.music.126.net/cover.jpg"},
					"dt":269000,
					"mv":186001,
					"h":{"br":320000,"size":100},
					"sq":{"br":900000,"size":200}
				}]
			}
		}`
	})

	result, err := client.SearchSongs(context.Background(), "", "晴天", 1, 20)
	if err != nil {
		t.Fatal(err)
	}
	if result.Total != 1 || len(result.Songs) != 1 {
		t.Fatalf("unexpected result: %+v", result)
	}
	song := result.Songs[0]
	if song.ID != 186016 || song.Name != "晴天" || song.Album != "叶惠美" || song.DurationSeconds != 269 || song.MV != 186001 {
		t.Fatalf("unexpected song: %+v", song)
	}
	if len(song.Artists) != 1 || song.Artists[0] != "周杰伦" {
		t.Fatalf("unexpected artists: %+v", song.Artists)
	}
	if song.CoverURL != "https://p1.music.126.net/cover.jpg" {
		t.Fatalf("unexpected cover: %s", song.CoverURL)
	}
	if len(song.AvailableQualities) != 2 || song.AvailableQualities[0] != "flac" {
		t.Fatalf("unexpected qualities: %+v", song.AvailableQualities)
	}
}

func TestClientGetSongsParsesLegacyFields(t *testing.T) {
	client := newMusicTestClient(t, func(r *http.Request) string {
		if r.URL.Path != "/weapi/v3/song/detail" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		return `{
			"code":200,
			"songs":[{
				"id":123,
				"name":"歌曲",
				"artists":[{"name":"歌手"}],
				"album":{"id":9,"name":"专辑","picUrl":"http://example.com/a.jpg"},
				"duration":180000,
				"l":{"br":128000,"size":10}
			}]
		}`
	})

	songs, err := client.GetSongs(context.Background(), "", []int64{123})
	if err != nil {
		t.Fatal(err)
	}
	if len(songs) != 1 || songs[0].DurationSeconds != 180 || songs[0].Artists[0] != "歌手" {
		t.Fatalf("unexpected songs: %+v", songs)
	}
}

func TestClientResolveSongURLFallsBackAndUpgradesHTTP(t *testing.T) {
	calls := 0
	client := newMusicTestClient(t, func(r *http.Request) string {
		if r.URL.Path != "/weapi/song/enhance/player/url/v1" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		calls++
		if calls == 1 {
			return `{"code":200,"data":[{"id":123,"url":null,"code":200,"fee":1}]}`
		}
		return `{"code":200,"data":[{"id":123,"url":"http://m10.music.126.net/a.mp3","br":320000,"size":4096,"type":"mp3","code":200}]}`
	})

	result, err := client.ResolveSongURL(context.Background(), "", 123, "flac", true)
	if err != nil {
		t.Fatal(err)
	}
	if result.URL != "https://m10.music.126.net/a.mp3" || result.Quality != "320mp3" || result.Bitrate != 320000 {
		t.Fatalf("unexpected playback result: %+v", result)
	}
	if len(result.Attempts) != 1 || result.Attempts[0].Quality != "flac" {
		t.Fatalf("unexpected attempts: %+v", result.Attempts)
	}
}

func TestClientGetLyricNormalizesText(t *testing.T) {
	client := newMusicTestClient(t, func(r *http.Request) string {
		if r.URL.Path != "/weapi/song/lyric" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		return `{"code":200,"lrc":{"lyric":"[00:00]hello"},"tlyric":{"lyric":"你好"},"romalrc":{"lyric":"hello"}}`
	})

	result, err := client.GetLyric(context.Background(), "", 123)
	if err != nil {
		t.Fatal(err)
	}
	if result.Lyric != "[00:00]hello" || result.Translation != "你好" || result.Romanization != "hello" {
		t.Fatalf("unexpected lyric: %+v", result)
	}
}

func TestClientGetMVReadsInfoAndURL(t *testing.T) {
	client := newMusicTestClient(t, func(r *http.Request) string {
		switch r.URL.Path {
		case "/weapi/mv/detail":
			return `{"code":200,"data":{"id":456,"name":"MV","desc":"描述","cover":"http://example.com/c.jpg","duration":120000}}`
		case "/weapi/song/enhance/play/mv/url":
			return `{"code":200,"data":{"url":"http://example.com/mv.mp4","br":1080,"size":2048}}`
		default:
			t.Errorf("unexpected path: %s", r.URL.Path)
			return `{"code":500}`
		}
	})

	result, err := client.GetMV(context.Background(), "", 456)
	if err != nil {
		t.Fatal(err)
	}
	if result.ID != 456 || result.Name != "MV" || result.URL != "https://example.com/mv.mp4" || result.DurationSeconds != 120 {
		t.Fatalf("unexpected MV: %+v", result)
	}
}

func TestClientGetUserPlaylistsIncludesTrackIDs(t *testing.T) {
	client := newMusicTestClient(t, func(r *http.Request) string {
		switch r.URL.Path {
		case "/weapi/user/playlist":
			return `{"code":200,"playlist":[{"id":1001,"name":"我的歌单","coverImgUrl":"http://example.com/p.jpg","trackCount":2}]}`
		case "/weapi/v6/playlist/detail":
			return `{"code":200,"playlist":{"trackIds":[{"id":11},{"id":22},{"id":11}],"tracks":[]}}`
		default:
			t.Errorf("unexpected path: %s", r.URL.Path)
			return `{"code":500}`
		}
	})

	playlists, err := client.GetUserPlaylists(context.Background(), "", "12345")
	if err != nil {
		t.Fatal(err)
	}
	if len(playlists) != 1 || playlists[0].ID != "1001" {
		t.Fatalf("unexpected playlists: %+v", playlists)
	}
	if len(playlists[0].SongIDs) != 2 || playlists[0].SongIDs[0] != 11 || playlists[0].SongIDs[1] != 22 {
		t.Fatalf("unexpected track IDs: %+v", playlists[0].SongIDs)
	}
}

type musicRoundTripFunc func(*http.Request) (*http.Response, error)

func (f musicRoundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

func newMusicTestClient(t *testing.T, handler func(*http.Request) string) *Client {
	t.Helper()
	client, err := NewClient(WithHTTPClient(&http.Client{Transport: musicRoundTripFunc(func(request *http.Request) (*http.Response, error) {
		body := handler(request)
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{"application/json"}},
			Body:       io.NopCloser(strings.NewReader(body)),
			Request:    request,
		}, nil
	})}))
	if err != nil {
		t.Fatal(err)
	}
	client.now = func() time.Time { return time.Date(2026, 11, 9, 10, 0, 0, 0, time.UTC) }
	return client
}
