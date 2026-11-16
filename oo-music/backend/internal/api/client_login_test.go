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

	oomusic "github.com/rankgice/oo-music"
	"github.com/rankgice/oo-music/internal/account"
	"github.com/rankgice/oo-music/internal/qqlogin"
)

type fakeClientQRLoginService struct {
	startResult qqlogin.StartResult
	pollResult  qqlogin.PollResult
	image       []byte
	canceled    bool
}

func (f *fakeClientQRLoginService) Start(context.Context) (qqlogin.StartResult, error) {
	return f.startResult, nil
}

func (f *fakeClientQRLoginService) Poll(context.Context, string) (qqlogin.PollResult, error) {
	return f.pollResult, nil
}

func (f *fakeClientQRLoginService) Image(string) ([]byte, error) {
	return append([]byte(nil), f.image...), nil
}

func (f *fakeClientQRLoginService) Cancel(string) error {
	f.canceled = true
	return nil
}

func TestClientQRLoginReturnsPlatformIdentityAndAccessKey(t *testing.T) {
	store, err := account.Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	pool := account.NewPool(store, log.New(io.Discard, "", 0))
	pool.SetUserProfileReader(func(context.Context, *oomusic.Client, string) (*oomusic.CallResult, error) {
		return &oomusic.CallResult{
			Code: 0,
			Data: []byte(`{"map_userinfo":{"209192670":{"uin":209192670,"nick":"扫码昵称","headurl":"https://example.com/avatar.png"}}}`),
		}, nil
	})
	qr := &fakeClientQRLoginService{
		startResult: qqlogin.StartResult{
			Session: qqlogin.Session{
				ID:        "session-1",
				Status:    qqlogin.StatusWaiting,
				Message:   "请使用手机 QQ 扫码",
				ExpiresAt: time.Now().UTC().Add(5 * time.Minute),
			},
			ImagePNG: []byte("png-image"),
		},
		pollResult: qqlogin.PollResult{
			Session: qqlogin.Session{ID: "session-1", Status: qqlogin.StatusCompleted, Message: "登录成功"},
			UIN:     "209192670",
			QMKeyst: "secret-qm-key",
		},
		image: []byte("png-image"),
	}
	handler := NewHandlerWithWebRootAndQR(pool, qr, log.New(io.Discard, "", 0), "")

	start := httptest.NewRecorder()
	handler.ServeHTTP(start, httptest.NewRequest(http.MethodPost, "/api/client/login/sessions?source=qq", nil))
	if start.Code != http.StatusCreated {
		t.Fatalf("start status=%d body=%s", start.Code, start.Body.String())
	}
	if !strings.Contains(start.Body.String(), `"imageUrl":"/api/client/login/sessions/session-1/image?source=qq"`) {
		t.Fatalf("unexpected image URL: %s", start.Body.String())
	}

	image := httptest.NewRecorder()
	handler.ServeHTTP(image, httptest.NewRequest(http.MethodGet, "/api/client/login/sessions/session-1/image?source=qq", nil))
	if image.Code != http.StatusOK || image.Header().Get("Content-Type") != "image/png" || image.Body.String() != "png-image" {
		t.Fatalf("unexpected image response: status=%d headers=%v body=%q", image.Code, image.Header(), image.Body.String())
	}
	if image.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("QR image must not be cached: %v", image.Header())
	}

	poll := httptest.NewRecorder()
	handler.ServeHTTP(poll, httptest.NewRequest(http.MethodGet, "/api/client/login/sessions/session-1?source=qq", nil))
	if poll.Code != http.StatusOK {
		t.Fatalf("poll status=%d body=%s", poll.Code, poll.Body.String())
	}
	if !strings.Contains(poll.Body.String(), `"imageUrl":"/api/client/login/sessions/session-1/image?source=qq"`) {
		t.Fatalf("poll did not keep a stable image URL: %s", poll.Body.String())
	}
	if strings.Contains(poll.Body.String(), "secret-qm-key") || strings.Contains(poll.Body.String(), "qmKeyst") {
		t.Fatalf("poll leaked QQ Music credentials: %s", poll.Body.String())
	}
	var payload struct {
		Source    string `json:"source"`
		AccountID string `json:"accountId"`
		AccessKey string `json:"accessKey"`
		Nickname  string `json:"nickname"`
		AvatarURL string `json:"avatarUrl"`
	}
	if err := json.Unmarshal(poll.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Source != "qq" || payload.AccountID != "209192670" || payload.AccessKey == "" || payload.Nickname != "扫码昵称" || payload.AvatarURL != "https://example.com/avatar.png" {
		t.Fatalf("unexpected client credentials: %+v", payload)
	}
	saved, err := store.ListAccounts(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(saved) != 1 || saved[0].AccessKey != payload.AccessKey {
		t.Fatalf("access key was not persisted: %+v", saved)
	}
	if saved[0].Nickname != payload.Nickname || saved[0].AvatarURL != payload.AvatarURL {
		t.Fatalf("profile was not persisted: %+v", saved)
	}

	again := httptest.NewRecorder()
	handler.ServeHTTP(again, httptest.NewRequest(http.MethodGet, "/api/client/login/sessions/session-1?source=qq", nil))
	if !strings.Contains(again.Body.String(), `"accessKey":"`+payload.AccessKey+`"`) {
		t.Fatalf("repeated poll rotated access key: %s", again.Body.String())
	}

	options := httptest.NewRecorder()
	handler.ServeHTTP(options, httptest.NewRequest(http.MethodOptions, "/api/client/login/sessions?source=qq", nil))
	if !strings.Contains(options.Header().Get("Access-Control-Allow-Methods"), "POST") ||
		!strings.Contains(options.Header().Get("Access-Control-Allow-Headers"), account.ClientAccessKeyHeader) {
		t.Fatalf("CORS does not allow client authorization headers: %v", options.Header())
	}

	cancel := httptest.NewRecorder()
	handler.ServeHTTP(cancel, httptest.NewRequest(http.MethodDelete, "/api/client/login/sessions/session-1?source=qq", nil))
	if cancel.Code != http.StatusNoContent || !qr.canceled {
		t.Fatalf("QR session was not canceled: status=%d canceled=%t", cancel.Code, qr.canceled)
	}
}

func TestClientAccountProfileAuthorization(t *testing.T) {
	store, err := account.Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	pool := account.NewPool(store, log.New(io.Discard, "", 0))
	ctx := context.Background()
	item, err := pool.Upsert(ctx, "209192670", "secret-qm-key")
	if err != nil {
		t.Fatal(err)
	}
	pool.SetUserProfileReader(func(_ context.Context, _ *oomusic.Client, uin string) (*oomusic.CallResult, error) {
		return &oomusic.CallResult{
			Code: 0,
			Data: []byte(`{"map_userinfo":{"` + uin + `":{"uin":209192670,"nick":"授权昵称","headurl":"https://example.com/avatar.png"}}}`),
		}, nil
	})
	handler := NewHandler(pool, log.New(io.Discard, "", 0))

	request := httptest.NewRequest(http.MethodGet, "/api/client/account?source=qq", nil)
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
	if payload.Source != account.AccountTypeQQ || payload.AccountID != item.AccountID || payload.Nickname != "授权昵称" || payload.AvatarURL != "https://example.com/avatar.png" {
		t.Fatalf("unexpected account profile: %+v", payload)
	}
	if strings.Contains(response.Body.String(), "secret-qm-key") {
		t.Fatalf("profile response leaked qm_keyst: %s", response.Body.String())
	}

	unauthorized := httptest.NewRequest(http.MethodGet, "/api/client/account?source=qq", nil)
	unauthorized.Header.Set(account.ClientAccountIDHeader, item.AccountID)
	unauthorized.Header.Set(account.ClientAccessKeyHeader, "wrong-access-key")
	unauthorizedResponse := httptest.NewRecorder()
	handler.ServeHTTP(unauthorizedResponse, unauthorized)
	if unauthorizedResponse.Code != http.StatusUnauthorized {
		t.Fatalf("invalid key status=%d body=%s", unauthorizedResponse.Code, unauthorizedResponse.Body.String())
	}
}

func TestClientAccountProfileRejectsExpiredQQLoginWithCachedProfile(t *testing.T) {
	store, err := account.Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	pool := account.NewPool(store, log.New(io.Discard, "", 0))
	ctx := context.Background()
	item, err := pool.Upsert(ctx, "209192670", "secret-qm-key")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateProfile(ctx, item.ID, "缓存昵称", "https://example.com/cached.png"); err != nil {
		t.Fatal(err)
	}
	pool.SetUserProfileReader(func(context.Context, *oomusic.Client, string) (*oomusic.CallResult, error) {
		return &oomusic.CallResult{Code: 1000}, nil
	})
	handler := NewHandler(pool, log.New(io.Discard, "", 0))

	request := httptest.NewRequest(http.MethodGet, "/api/client/account?source=qq", nil)
	request.Header.Set(account.ClientAccountIDHeader, item.AccountID)
	request.Header.Set(account.ClientAccessKeyHeader, item.AccessKey)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)

	if response.Code != http.StatusUnauthorized {
		t.Fatalf("expired QQ login returned status=%d body=%s", response.Code, response.Body.String())
	}
	saved, err := store.AccountByID(ctx, item.ID)
	if err != nil {
		t.Fatal(err)
	}
	if saved.LoginValid || saved.AccessKey != "" {
		t.Fatalf("expired login did not clear authorization: %+v", saved)
	}
}
