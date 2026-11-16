package oomusic

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

func liveClient(t *testing.T) *Client {
	t.Helper()
	if os.Getenv("OO_MUSIC_LIVE") != "1" {
		t.Skip("设置 OO_MUSIC_LIVE=1 后运行 QQ 音乐线上集成测试")
	}
	client, err := NewClient()
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func liveContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	t.Cleanup(cancel)
	return ctx
}

func TestLiveAnonymousSearch(t *testing.T) {
	client := liveClient(t)
	ctx := liveContext(t)
	result, err := client.SearchSongs(ctx, "周杰伦", 1, 2)
	if err != nil {
		t.Fatal(err)
	}
	if result.Code != 0 {
		t.Fatalf("搜索业务码 %d: %s", result.Code, result.Data)
	}
	t.Logf("搜索结果: %s", result.Data)
}

func TestLiveAnonymousCore(t *testing.T) {
	client := liveClient(t)
	ctx := liveContext(t)

	t.Run("热门搜索词", func(t *testing.T) {
		result, err := client.GetHotKeys(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if result.Code != 0 || len(result.Data) == 0 {
			t.Fatalf("热门搜索词业务码 %d: %s", result.Code, result.Data)
		}
	})

	t.Run("歌曲信息", func(t *testing.T) {
		result, err := client.GetTrackInfo(ctx, TrackInfoOptions{IDs: []int64{102321278}})
		if err != nil {
			t.Fatal(err)
		}
		if result.Code != 0 || !strings.Contains(string(result.Data), `"mid"`) {
			t.Fatalf("歌曲信息业务码 %d: %s", result.Code, result.Data)
		}
	})

	t.Run("播放地址", func(t *testing.T) {
		result, err := client.ResolvePlayableBySong(ctx, ResolvePlayableBySongOptions{SongID: 102321278})
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("音质=%s PURL=%s 原因=%s 尝试=%+v", result.Quality, result.PURL, result.Reason, result.Tried)
	})

	t.Run("歌词", func(t *testing.T) {
		result, err := client.GetLyric(ctx, LyricOptions{SongMID: "000lXvdX0uOg8F", SongID: 102321278})
		if err != nil {
			t.Fatal(err)
		}
		if result.Code != 0 || result.Lyric == "" {
			t.Fatalf("歌词业务码 %d，歌词长度 %d", result.Code, len(result.Lyric))
		}
	})

	t.Run("歌单", func(t *testing.T) {
		result, err := client.GetPlaylistDetail(ctx, PlaylistOptions{DisstID: "2130981100", Limit: 2})
		if err != nil {
			t.Fatal(err)
		}
		// 匿名态可能因歌单权限或服务端策略不返回内容，这里只验证协议链路可达。
		t.Logf("歌单接口可达，业务码 %d，数据长度 %d", result.Code, len(result.Data))
	})
}
