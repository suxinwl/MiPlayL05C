package api

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	oomusic "github.com/rankgice/oo-music"
	"github.com/rankgice/oo-music/internal/account"
)

func TestDecodeSearchSongsBuildsCoverURL(t *testing.T) {
	data, err := json.Marshal(map[string]any{
		"body": map[string]any{
			"song": map[string]any{
				"list": []map[string]any{{
					"id":       97773,
					"mid":      "0039MnYb0qxYhV",
					"name":     "晴天",
					"interval": 269,
					"singer":   []map[string]any{{"name": "周杰伦"}},
					"album":    map[string]any{"mid": "000MkMni19ClKG", "name": "叶惠美"},
					"mv":       map[string]any{"vid": "w0026q7f01a"},
				}},
			},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	items, err := decodeSearchSongs(data)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("unexpected item count: %d", len(items))
	}
	got := items[0]
	if got.Source != account.AccountTypeQQ || got.Name != "晴天" || got.Album != "叶惠美" || !got.HasMV || got.MVVID != "w0026q7f01a" {
		t.Fatalf("unexpected song: %+v", got)
	}
	if got.CoverURL != "https://y.gtimg.cn/music/photo_new/T002R300x300M000000MkMni19ClKG.jpg" {
		t.Fatalf("unexpected cover URL: %s", got.CoverURL)
	}
}

func TestQualityPreferenceStartsWithRequestedQuality(t *testing.T) {
	order, name, err := qualityPreference("flac")
	if err != nil {
		t.Fatal(err)
	}
	if name != string(oomusic.QualityFLAC) || len(order) == 0 || order[0] != oomusic.QualityFLAC {
		t.Fatalf("unexpected quality order: name=%s order=%v", name, order)
	}
}

func TestQualityPreferenceDefaultsToStableMP3(t *testing.T) {
	order, name, err := qualityPreference("")
	if err != nil {
		t.Fatal(err)
	}
	if name != string(oomusic.QualityMP3320) || len(order) == 0 || order[0] != oomusic.QualityMP3320 {
		t.Fatalf("unexpected default quality order: name=%s order=%v", name, order)
	}
}

func TestNormalizeMediaURLUsesHTTPS(t *testing.T) {
	got := normalizeMediaURL("http://aqqmusic.tc.qq.com/example.m4a")
	want := "https://aqqmusic.tc.qq.com/example.m4a"
	if got != want {
		t.Fatalf("unexpected normalized URL: %s", got)
	}
}

func TestPickBestMVStreamPrefersHigherQualityPlayableMP4(t *testing.T) {
	data := mvURLData{
		MP4: []mvStream{
			{Code: 1, FileType: 80, URL: []string{"https://example.com/broken.mp4"}},
			{Code: 0, FileType: 40, URL: []string{"https://example.com/720.mp4"}},
			{Code: 0, FileType: 60, FreeflowURL: []string{"https://example.com/1080.mp4"}},
		},
		HLS: []mvStream{
			{Code: 0, FileType: 30, M3U8: "https://example.com/video.m3u8"},
		},
	}
	stream, mediaURL, ok := pickBestMVStream(data)
	if !ok {
		t.Fatal("expected a playable MV stream")
	}
	if stream.FileType != 60 || mediaURL != "https://example.com/1080.mp4" {
		t.Fatalf("unexpected stream: %+v URL=%s", stream, mediaURL)
	}
}

func TestLivenessDoesNotRequireAccountPool(t *testing.T) {
	handler := NewHandler(nil, log.New(io.Discard, "", 0))
	request := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("unexpected status: %d body=%s", response.Code, response.Body.String())
	}
	if strings.TrimSpace(response.Body.String()) != `{"status":"ok"}` {
		t.Fatalf("unexpected body: %s", response.Body.String())
	}
}

func TestEmbeddedWebServesIndexAssetsAndSPAFallback(t *testing.T) {
	webRoot := t.TempDir()
	if err := os.WriteFile(filepath.Join(webRoot, "index.html"), []byte("<html>admin</html>"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(webRoot, "assets"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(webRoot, "assets", "app.js"), []byte("console.log('ok')"), 0o600); err != nil {
		t.Fatal(err)
	}

	handler := NewHandlerWithWebRoot(nil, log.New(io.Discard, "", 0), webRoot)
	for _, testCase := range []struct {
		path string
		want string
		code int
	}{
		{path: "/", want: "<html>admin</html>", code: http.StatusOK},
		{path: "/assets/app.js", want: "console.log('ok')", code: http.StatusOK},
		{path: "/accounts/1", want: "<html>admin</html>", code: http.StatusOK},
		{path: "/api/not-found", want: "404 page not found", code: http.StatusNotFound},
	} {
		request := httptest.NewRequest(http.MethodGet, testCase.path, nil)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != testCase.code {
			t.Fatalf("%s: unexpected status: %d body=%s", testCase.path, response.Code, response.Body.String())
		}
		if !strings.Contains(response.Body.String(), testCase.want) {
			t.Fatalf("%s: unexpected body: %s", testCase.path, response.Body.String())
		}
	}
}
