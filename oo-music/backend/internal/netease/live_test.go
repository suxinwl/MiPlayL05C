//go:build integration

package netease

import (
	"context"
	"encoding/json"
	"os"
	"strconv"
	"testing"
	"time"
)

func TestLiveWeapiQRKey(t *testing.T) {
	client, err := NewClient()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cookies, err := client.normalizedCookies("")
	if err != nil {
		t.Fatal(err)
	}
	result, err := client.doWeapi(ctx, "/api/login/qrcode/unikey", map[string]any{"type": 3}, cookies)
	if err != nil {
		t.Fatal(err)
	}
	if result.Code != 200 {
		t.Fatalf("unexpected QR key response code %d: %s", result.Code, result.Message)
	}
	var body struct {
		UniKey string `json:"unikey"`
	}
	if err := json.Unmarshal(result.Raw, &body); err != nil {
		t.Fatal(err)
	}
	if body.UniKey == "" {
		t.Fatalf("QR key response did not include unikey: %s", result.Raw)
	}
}

func TestLiveAnonymousMusicEndpoints(t *testing.T) {
	if os.Getenv("OO_MUSIC_LIVE") != "1" {
		t.Skip("OO_MUSIC_LIVE is not set")
	}
	client, err := NewClient()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	search, err := client.SearchSongs(ctx, "", "晴天", 1, 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(search.Songs) == 0 {
		t.Fatal("anonymous search returned no songs")
	}
	songID := search.Songs[0].ID
	songs, err := client.GetSongs(ctx, "", []int64{songID})
	if err != nil {
		t.Fatal(err)
	}
	if len(songs) == 0 || songs[0].Name == "" {
		t.Fatalf("song detail was empty: %+v", songs)
	}
	lyric, err := client.GetLyric(ctx, "", songID)
	if err != nil {
		t.Fatal(err)
	}
	if lyric.Lyric == "" {
		t.Fatal("lyric text was empty")
	}
	playback, err := client.ResolveSongURL(ctx, "", songID, "128mp3", true)
	if err != nil {
		t.Fatal(err)
	}
	if playback.URL == "" {
		t.Fatalf("anonymous playback URL was unavailable: %+v", playback)
	}
	if songs[0].MV > 0 {
		if _, err := client.GetMV(ctx, "", songs[0].MV); err != nil {
			t.Fatal(err)
		}
	}
}

func TestLiveMVURL(t *testing.T) {
	if os.Getenv("OO_MUSIC_LIVE") != "1" {
		t.Skip("OO_MUSIC_LIVE is not set")
	}
	client, err := NewClient()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	search, err := client.SearchSongs(ctx, "", "晴天", 1, 10)
	if err != nil {
		t.Fatal(err)
	}
	ids := make([]int64, 0, len(search.Songs))
	for _, song := range search.Songs {
		ids = append(ids, song.ID)
	}
	songs, err := client.GetSongs(ctx, "", ids)
	if err != nil {
		t.Fatal(err)
	}
	for _, song := range songs {
		if song.MV <= 0 {
			continue
		}
		t.Logf("testing MV %d for song %d %s", song.MV, song.ID, song.Name)
		info, err := client.GetMV(ctx, "", song.MV)
		if err != nil {
			t.Fatalf("GetMV(%d): %v", song.MV, err)
		}
		if info.URL == "" {
			t.Fatalf("GetMV(%d) returned no URL: %+v", song.MV, info)
		}
		return
	}
	t.Fatal("search results did not contain a song with MV")
}

func TestLiveVIPStatus(t *testing.T) {
	cookie := os.Getenv("NETEASE_COOKIE")
	if cookie == "" {
		t.Skip("NETEASE_COOKIE is not set")
	}
	client, err := NewClient()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	account, err := client.Check(ctx, cookie, "")
	if err != nil {
		t.Fatal(err)
	}
	status, err := client.GetVIPStatus(ctx, account.Cookie, strconv.FormatInt(account.UID, 10))
	if err != nil {
		t.Fatal(err)
	}
	if !status.Active || status.ExpiresAt == nil {
		t.Fatalf("expected active VIP status, got %+v", status)
	}
}

func TestLiveInvitationDetail(t *testing.T) {
	cookie := os.Getenv("NETEASE_COOKIE")
	token := os.Getenv("NETEASE_INVITE_TOKEN")
	if cookie == "" || token == "" {
		t.Skip("NETEASE_COOKIE and NETEASE_INVITE_TOKEN are required")
	}
	client, err := NewClient()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	detail, err := client.GetInvitationDetail(ctx, cookie, token, "invite-cashier", "https://y.music.163.com/g/vip-invite-cashier/test")
	if err != nil {
		t.Fatal(err)
	}
	if detail.TokenExpireTime == nil {
		t.Fatalf("invitation detail missing expiry: %+v", detail)
	}
}
