package api

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/rankgice/oo-music/internal/account"
	"github.com/rankgice/oo-music/internal/netease"
)

type fakeNeteaseMusicClient struct {
	searchResult netease.SearchResult
	searchErr    error
	songs        []netease.Song
	songsErr     error
	songURL      netease.SongURL
	songURLErr   error
	lyric        netease.Lyric
	lyricErr     error
	mv           netease.MVInfo
	mvErr        error
	playlists    []netease.UserPlaylist
	playlistsErr error
	lastCookie   string
	lastQuality  string
}

func (f *fakeNeteaseMusicClient) SearchSongs(_ context.Context, cookie, _ string, _, _ int) (netease.SearchResult, error) {
	f.lastCookie = cookie
	return f.searchResult, f.searchErr
}

func (f *fakeNeteaseMusicClient) GetSongs(_ context.Context, cookie string, _ []int64) ([]netease.Song, error) {
	f.lastCookie = cookie
	return f.songs, f.songsErr
}

func (f *fakeNeteaseMusicClient) ResolveSongURL(_ context.Context, cookie string, _ int64, quality string, _ bool) (netease.SongURL, error) {
	f.lastCookie = cookie
	f.lastQuality = quality
	return f.songURL, f.songURLErr
}

func (f *fakeNeteaseMusicClient) GetLyric(_ context.Context, cookie string, _ int64) (netease.Lyric, error) {
	f.lastCookie = cookie
	return f.lyric, f.lyricErr
}

func (f *fakeNeteaseMusicClient) GetMV(_ context.Context, cookie string, _ int64) (netease.MVInfo, error) {
	f.lastCookie = cookie
	return f.mv, f.mvErr
}

func (f *fakeNeteaseMusicClient) GetUserPlaylists(_ context.Context, cookie, _ string) ([]netease.UserPlaylist, error) {
	f.lastCookie = cookie
	return f.playlists, f.playlistsErr
}

type fakeNeteaseQRService struct {
	startResult netease.QRStartResult
	pollResult  netease.QRPollResult
	canceled    bool
}

func TestMusicSourceParsingAndInvalidSourceResponse(t *testing.T) {
	for _, testCase := range []struct {
		raw  string
		want account.AccountType
	}{
		{raw: "qq", want: account.AccountTypeQQ},
		{raw: "netease", want: account.AccountTypeNetease},
	} {
		got, err := parseMusicSource(testCase.raw)
		if err != nil || got != testCase.want {
			t.Fatalf("parseMusicSource(%q)=%q,%v want=%q", testCase.raw, got, err, testCase.want)
		}
	}
	for _, raw := range []string{"", "kugou"} {
		if _, err := parseMusicSource(raw); err == nil {
			t.Fatalf("parseMusicSource(%q) unexpectedly succeeded", raw)
		}
	}

	handler := NewHandler(nil, log.New(io.Discard, "", 0))
	request := httptest.NewRequest(http.MethodGet, "/api/search?source=kugou&q=test", nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), `"invalid_source"`) {
		t.Fatalf("unexpected invalid source response: status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestCORSAllowsPlatformSourceHeader(t *testing.T) {
	handler := NewHandler(nil, log.New(io.Discard, "", 0))
	request := httptest.NewRequest(http.MethodOptions, "/api/search", nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if !strings.Contains(response.Header().Get("Access-Control-Allow-Headers"), account.ClientSourceHeader) {
		t.Fatalf("source header missing from CORS: %s", response.Header().Get("Access-Control-Allow-Headers"))
	}
}

func (f *fakeNeteaseQRService) Start(context.Context) (netease.QRStartResult, error) {
	return f.startResult, nil
}

func (f *fakeNeteaseQRService) Image(string) ([]byte, error) {
	return []byte("netease-qr"), nil
}

func (f *fakeNeteaseQRService) Poll(context.Context, string) (netease.QRPollResult, error) {
	return f.pollResult, nil
}

func (f *fakeNeteaseQRService) Cancel(string) error {
	f.canceled = true
	return nil
}

func newMultiPlatformTestServer(t *testing.T) (*account.Store, *account.Pool, *fakeNeteaseMusicClient, *Server) {
	t.Helper()
	store, err := account.Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	pool := account.NewPool(store, log.New(io.Discard, "", 0))
	fake := &fakeNeteaseMusicClient{}
	server := &Server{
		accounts: pool,
		netease:  fake,
		logger:   log.New(io.Discard, "", 0),
	}
	return store, pool, fake, server
}

func TestNeteaseMediaHandlersUseSelectedCookieAndUnifiedDTO(t *testing.T) {
	store, _, fake, server := newMultiPlatformTestServer(t)
	_, err := store.UpsertNeteaseCredentials(context.Background(), "12345678", "MUSIC_U=selected-cookie", nil)
	if err != nil {
		t.Fatal(err)
	}
	fake.searchResult = netease.SearchResult{Songs: []netease.Song{{
		ID: 186016, Name: "晴天", Artists: []string{"周杰伦"}, Album: "叶惠美",
		CoverURL: "https://example.com/cover.jpg", DurationSeconds: 269, MV: 186001,
		AvailableQualities: []string{"flac"},
	}}}
	fake.songs = []netease.Song{{ID: 186016, Name: "晴天", Artists: []string{"周杰伦"}, MV: 186001}}
	fake.songURL = netease.SongURL{URL: "https://example.com/audio.mp3", Quality: "320mp3", Attempts: []netease.SongURLAttempt{{Quality: "flac", Reason: "需要会员"}}}
	fake.lyric = netease.Lyric{Lyric: "[00:00]晴天", Translation: "翻译", Romanization: "romaji"}
	fake.mv = netease.MVInfo{ID: 186001, Name: "晴天 MV", URL: "https://example.com/mv.mp4", DurationSeconds: 270}

	handler := server.withPublicAPIAuthorization(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/search":
			server.handleSearch(w, r)
		case "/tracks":
			server.handleTracks(w, r)
		case "/playback":
			server.handlePlayback(w, r)
		case "/lyrics":
			server.handleLyrics(w, r)
		case "/mv":
			server.handleMV(w, r)
		default:
			http.NotFound(w, r)
		}
	}))

	assertJSONRequest(t, handler, "/search?source=netease&q=晴天", func(payload searchResponse) {
		if payload.Source != account.AccountTypeNetease || len(payload.Items) != 1 || payload.Items[0].Source != account.AccountTypeNetease || payload.Items[0].ID != 186016 {
			t.Fatalf("unexpected NetEase search response: %+v", payload)
		}
	})
	if !strings.Contains(fake.lastCookie, "MUSIC_U=selected-cookie") {
		t.Fatalf("selected NetEase cookie was not used")
	}

	assertJSONRequest(t, handler, "/tracks?source=netease&ids=186016", func(payload tracksResponse) {
		if payload.Source != account.AccountTypeNetease || len(payload.Items) != 1 || payload.Items[0].Source != account.AccountTypeNetease {
			t.Fatalf("unexpected NetEase tracks response: %+v", payload)
		}
	})
	assertJSONRequest(t, handler, "/playback?source=netease&song_id=186016&quality=flac", func(payload playbackResponse) {
		if payload.Source != account.AccountTypeNetease || !payload.Available || payload.Quality != "320mp3" {
			t.Fatalf("unexpected NetEase playback response: %+v", payload)
		}
	})
	if fake.lastQuality != "flac" {
		t.Fatalf("playback quality was not forwarded: %s", fake.lastQuality)
	}
	assertJSONRequest(t, handler, "/lyrics?source=netease&song_id=186016", func(payload lyricResponse) {
		if payload.Source != account.AccountTypeNetease || payload.Title != "晴天" || payload.Lyric == "" {
			t.Fatalf("unexpected NetEase lyric response: %+v", payload)
		}
	})
	assertJSONRequest(t, handler, "/mv?source=netease&song_id=186016", func(payload mvResponse) {
		if payload.Source != account.AccountTypeNetease || !payload.Available || payload.VID != "186001" {
			t.Fatalf("unexpected NetEase MV response: %+v", payload)
		}
	})
}

func TestNeteaseMediaUsesPoolVIPInsteadOfClientBoundAccount(t *testing.T) {
	store, pool, fake, server := newMultiPlatformTestServer(t)
	ctx := context.Background()
	bound, err := store.UpsertNeteaseCredentials(ctx, "12345678", "MUSIC_U=bound-cookie", nil)
	if err != nil {
		t.Fatal(err)
	}
	poolVIP, err := store.UpsertNeteaseCredentials(ctx, "87654321", "MUSIC_U=pool-vip-cookie", nil)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	if err := store.UpdateVipStatus(ctx, poolVIP.ID, account.VipLevelVIP, now.Add(24*time.Hour), now); err != nil {
		t.Fatal(err)
	}
	fake.songs = []netease.Song{{ID: 186016, Name: "晴天", Artists: []string{"周杰伦"}}}
	server.accounts = pool

	handler := server.withPublicAPIAuthorization(http.HandlerFunc(server.handleTracks))
	request := httptest.NewRequest(http.MethodGet, "/api/tracks?source=netease&ids=186016", nil)
	request.Header.Set(account.ClientSourceHeader, "netease")
	request.Header.Set(account.ClientAccountIDHeader, bound.AccountID)
	request.Header.Set(account.ClientAccessKeyHeader, bound.AccessKey)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if fake.lastCookie != "MUSIC_U=pool-vip-cookie" {
		t.Fatalf("shared media used client-bound account instead of pool VIP: %q", fake.lastCookie)
	}
}

func TestNeteaseSearchFallsBackToAnonymousWithoutAccount(t *testing.T) {
	_, _, fake, server := newMultiPlatformTestServer(t)
	fake.searchResult = netease.SearchResult{Songs: []netease.Song{{ID: 1, Name: "匿名歌曲"}}}
	handler := server.withPublicAPIAuthorization(http.HandlerFunc(server.handleSearch))
	request := httptest.NewRequest(http.MethodGet, "/api/search?source=netease&q=test", nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if fake.lastCookie != "" {
		t.Fatalf("anonymous search unexpectedly used a cookie")
	}
}

func TestNeteaseAuthorizationUsesPlatformHeader(t *testing.T) {
	store, pool, _, server := newMultiPlatformTestServer(t)
	item, err := store.UpsertNeteaseCredentials(context.Background(), "12345678", "MUSIC_U=cookie", nil)
	if err != nil {
		t.Fatal(err)
	}
	server.accounts = pool
	handler := server.withPublicAPIAuthorization(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authorized, ok := AuthorizedClientAccount(r.Context())
		if !ok || authorized.Type != account.AccountTypeNetease || authorized.AccountID != item.AccountID {
			t.Fatalf("unexpected authorized account: %+v ok=%t", authorized, ok)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	request := httptest.NewRequest(http.MethodGet, "/tracks?ids=1", nil)
	request.Header.Set(account.ClientSourceHeader, "netease")
	request.Header.Set(account.ClientAccountIDHeader, item.AccountID)
	request.Header.Set(account.ClientAccessKeyHeader, item.AccessKey)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}

	wrongSource := httptest.NewRequest(http.MethodGet, "/tracks?source=qq&ids=1", nil)
	wrongSource.Header.Set(account.ClientAccountIDHeader, item.AccountID)
	wrongSource.Header.Set(account.ClientAccessKeyHeader, item.AccessKey)
	wrongResponse := httptest.NewRecorder()
	handler.ServeHTTP(wrongResponse, wrongSource)
	if wrongResponse.Code != http.StatusUnauthorized {
		t.Fatalf("platform mismatch status=%d body=%s", wrongResponse.Code, wrongResponse.Body.String())
	}
}

func TestClientPlaylistsRoutesNeteaseAuthorizedAccount(t *testing.T) {
	store, pool, fake, server := newMultiPlatformTestServer(t)
	ctx := context.Background()
	item, err := store.UpsertNeteaseCredentials(ctx, "12345678", "MUSIC_U=bound-cookie", nil)
	if err != nil {
		t.Fatal(err)
	}
	poolVIP, err := store.UpsertNeteaseCredentials(ctx, "87654321", "MUSIC_U=pool-vip-cookie", nil)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	if err := store.UpdateVipStatus(ctx, poolVIP.ID, account.VipLevelVIP, now.Add(24*time.Hour), now); err != nil {
		t.Fatal(err)
	}
	server.accounts = pool
	fake.playlists = []netease.UserPlaylist{{
		ID: "1001", Name: "网易云歌单", SongCount: 2, SongIDs: []int64{11, 22},
	}}
	handler := server.requireClientAuthorization(http.HandlerFunc(server.handleClientPlaylists))
	request := httptest.NewRequest(http.MethodGet, "/api/client/playlists?source=netease", nil)
	request.Header.Set(account.ClientAccountIDHeader, item.AccountID)
	request.Header.Set(account.ClientAccessKeyHeader, item.AccessKey)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if fake.lastCookie != "MUSIC_U=bound-cookie" {
		t.Fatalf("playlist request did not use client-bound account: %q", fake.lastCookie)
	}
	var payload clientPlaylistsResponse
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Source != account.AccountTypeNetease || len(payload.Playlists) != 1 || payload.Playlists[0].Source != account.AccountTypeNetease || len(payload.Playlists[0].SongIDs) != 2 {
		t.Fatalf("unexpected playlists: %+v", payload)
	}
}

func TestClientAccountReturnsNeteaseIdentity(t *testing.T) {
	store, pool, _, _ := newMultiPlatformTestServer(t)
	item, err := store.UpsertNeteaseCredentials(context.Background(), "12345678", "MUSIC_U=cookie", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateProfile(context.Background(), item.ID, "网易云用户", "https://example.com/avatar.png"); err != nil {
		t.Fatal(err)
	}
	handler := NewHandlerWithWebRootAndQRAndPolicy(pool, nil, log.New(io.Discard, "", 0), "", nil)
	request := httptest.NewRequest(http.MethodGet, "/api/client/account?source=netease", nil)
	request.Header.Set(account.ClientAccountIDHeader, item.AccountID)
	request.Header.Set(account.ClientAccessKeyHeader, item.AccessKey)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	var payload clientAccountResponse
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Source != account.AccountTypeNetease || payload.AccountID != "12345678" || payload.Nickname != "网易云用户" {
		t.Fatalf("unexpected client account: %+v", payload)
	}
}

func TestNeteaseClientQRStartAndCancel(t *testing.T) {
	fake := &fakeNeteaseQRService{startResult: netease.QRStartResult{QRSession: netease.QRSession{
		ID: "netease-session", Status: netease.QRStatusWaiting, Message: "等待扫码", ExpiresAt: time.Now().Add(time.Minute),
	}}}
	handler := NewHandlerWithWebRootAndBothQRAndPolicy(nil, nil, fake, log.New(io.Discard, "", 0), "", nil)

	start := httptest.NewRequest(http.MethodPost, "/api/client/login/sessions?source=netease", nil)
	startResponse := httptest.NewRecorder()
	handler.ServeHTTP(startResponse, start)
	if startResponse.Code != http.StatusCreated || !strings.Contains(startResponse.Body.String(), `"source":"netease"`) {
		t.Fatalf("unexpected start response: status=%d body=%s", startResponse.Code, startResponse.Body.String())
	}
	image := httptest.NewRequest(http.MethodGet, "/api/client/login/sessions/netease-session/image?source=netease", nil)
	imageResponse := httptest.NewRecorder()
	handler.ServeHTTP(imageResponse, image)
	if imageResponse.Code != http.StatusOK || imageResponse.Body.String() != "netease-qr" {
		t.Fatalf("unexpected image response: status=%d body=%s", imageResponse.Code, imageResponse.Body.String())
	}
	cancel := httptest.NewRequest(http.MethodDelete, "/api/client/login/sessions/netease-session?source=netease", nil)
	cancelResponse := httptest.NewRecorder()
	handler.ServeHTTP(cancelResponse, cancel)
	if cancelResponse.Code != http.StatusNoContent || !fake.canceled {
		t.Fatalf("unexpected cancel response: status=%d canceled=%t", cancelResponse.Code, fake.canceled)
	}
}

func assertJSONRequest[T any](t *testing.T, handler http.Handler, target string, assert func(T)) {
	t.Helper()
	request := httptest.NewRequest(http.MethodGet, target, nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("%s status=%d body=%s", target, response.Code, response.Body.String())
	}
	var payload T
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	assert(payload)
}
