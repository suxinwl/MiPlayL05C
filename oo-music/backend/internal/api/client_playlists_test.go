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

	oomusic "github.com/rankgice/oo-music"
	"github.com/rankgice/oo-music/internal/account"
)

func TestClientPlaylistsReturnsAuthorizedAccountPlaylistsWithoutCredentials(t *testing.T) {
	store, err := account.Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	pool := account.NewPool(store, log.New(io.Discard, "", 0))
	item, err := pool.Upsert(context.Background(), "209192670", "secret-qm-key")
	if err != nil {
		t.Fatal(err)
	}
	pool.SetUserPlaylistReader(func(_ context.Context, _ *oomusic.Client, uin string) ([]oomusic.UserPlaylist, error) {
		if uin != item.AccountID {
			t.Fatalf("unexpected authorized UIN: %s", uin)
		}
		return []oomusic.UserPlaylist{{
			ID:        "101",
			Name:      "测试歌单",
			CoverURL:  "https://example.com/cover.jpg",
			SongCount: 2,
			SongIDs:   []int64{11, 22},
		}}, nil
	})
	handler := NewHandler(pool, log.New(io.Discard, "", 0))
	request := httptest.NewRequest(http.MethodGet, "/api/client/playlists", nil)
	request.Header.Set(account.ClientSourceHeader, "qq")
	request.Header.Set(account.ClientAccountIDHeader, item.AccountID)
	request.Header.Set(account.ClientAccessKeyHeader, item.AccessKey)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	if strings.Contains(response.Body.String(), "secret-qm-key") || strings.Contains(response.Body.String(), item.AccessKey) {
		t.Fatalf("playlist response leaked credentials: %s", response.Body.String())
	}
	var payload clientPlaylistsResponse
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Playlists) != 1 || payload.Playlists[0].ID != "101" || len(payload.Playlists[0].SongIDs) != 2 {
		t.Fatalf("unexpected playlists: %+v", payload)
	}
}
