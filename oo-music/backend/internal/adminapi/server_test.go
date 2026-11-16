package adminapi

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/rankgice/oo-music/internal/account"
	"github.com/rankgice/oo-music/internal/admin"
	"github.com/rankgice/oo-music/internal/netease"
	"github.com/rankgice/oo-music/internal/qqlogin"
)

type fakeAccountManager struct {
	items       []account.PublicAccount
	upsertCalls int
	lastUIN     string
	lastKey     string
	lastType    account.AccountType
}

func (f *fakeAccountManager) ListBoundAccounts(context.Context) ([]account.PublicAccount, error) {
	return append([]account.PublicAccount(nil), f.items...), nil
}

func (f *fakeAccountManager) Upsert(_ context.Context, uin, qmKeyst string) (account.Account, error) {
	f.upsertCalls++
	f.lastUIN = uin
	f.lastKey = qmKeyst
	return account.Account{ID: 99, Type: account.AccountTypeQQ, AccountID: uin, Credential: qmKeyst, LoginValid: true}, nil
}

func (f *fakeAccountManager) UpsertNetease(_ context.Context, uid, cookie string, _ *time.Time, _, _ string) (account.Account, error) {
	f.upsertCalls++
	f.lastUIN = uid
	f.lastKey = cookie
	f.lastType = account.AccountTypeNetease
	return account.Account{ID: 100, Type: account.AccountTypeNetease, AccountID: uid, Credential: cookie, LoginValid: true}, nil
}

func (f *fakeAccountManager) CreateManualAccount(_ context.Context, accountType account.AccountType, uid, credential string) (account.PublicAccount, string, error) {
	f.lastType = accountType
	f.lastUIN = uid
	f.lastKey = credential
	return account.PublicAccount{ID: 101, AccountType: accountType, AccountTypeName: accountType.Name(), Available: true, LoggedIn: true, UINMasked: uid, LoginValid: true}, "", nil
}

func (f *fakeAccountManager) UpdateAccountCredential(_ context.Context, id int64, credential string) (account.PublicAccount, string, error) {
	f.lastKey = credential
	return account.PublicAccount{ID: id, Available: true, LoggedIn: true, UINMasked: "2091****70", VipLevelName: "普通用户", LoginValid: true}, "登录态验证失败，仅已保存新密钥", nil
}

func (f *fakeAccountManager) DeleteBoundAccount(_ context.Context, id int64) error {
	for index, item := range f.items {
		if item.ID == id {
			f.items = append(f.items[:index], f.items[index+1:]...)
			return nil
		}
	}
	return account.ErrNoAccount
}

func (f *fakeAccountManager) RefreshBoundAccount(_ context.Context, id int64) (account.PublicAccount, error) {
	for _, item := range f.items {
		if item.ID == id {
			return item, nil
		}
	}
	return account.PublicAccount{}, account.ErrNoAccount
}

func (f *fakeAccountManager) RefreshProfile(_ context.Context, uin string) (account.Account, error) {
	return account.Account{ID: 99, Type: account.AccountTypeQQ, AccountID: uin, Nickname: "测试用户", AvatarURL: "https://example.com/avatar.png", LoginValid: true}, nil
}

type fakeQRService struct {
	pollResult qqlogin.PollResult
	canceled   bool
}

func (f *fakeQRService) Start(context.Context) (qqlogin.StartResult, error) {
	now := time.Now().UTC()
	return qqlogin.StartResult{
		Session:  qqlogin.Session{ID: "opaque-session", Status: qqlogin.StatusWaiting, Message: "等待扫码", ExpiresAt: now.Add(time.Minute)},
		ImagePNG: []byte("png-image"),
	}, nil
}

func (f *fakeQRService) Get(id string) (qqlogin.Session, error) {
	return qqlogin.Session{ID: id, Status: qqlogin.StatusWaiting, Message: "等待扫码"}, nil
}

func (f *fakeQRService) Image(id string) ([]byte, error) {
	return []byte("png-image"), nil
}

func (f *fakeQRService) Poll(context.Context, string) (qqlogin.PollResult, error) {
	return f.pollResult, nil
}

func (f *fakeQRService) Cancel(string) error {
	f.canceled = true
	return nil
}

type fakeNeteaseQRService struct {
	startResult netease.QRStartResult
	pollResult  netease.QRPollResult
	canceled    bool
}

func (f *fakeNeteaseQRService) Start(context.Context) (netease.QRStartResult, error) {
	if f.startResult.ID != "" {
		return f.startResult, nil
	}
	now := time.Now().UTC()
	return netease.QRStartResult{
		QRSession: netease.QRSession{ID: "netease-session", Status: netease.QRStatusWaiting, Message: "等待扫码", ExpiresAt: now.Add(time.Minute)},
		ImagePNG:  []byte("netease-png"),
	}, nil
}

func (f *fakeNeteaseQRService) Get(id string) (netease.QRSession, error) {
	return netease.QRSession{ID: id, Status: netease.QRStatusWaiting}, nil
}

func (f *fakeNeteaseQRService) Image(string) ([]byte, error) {
	return []byte("netease-png"), nil
}

func (f *fakeNeteaseQRService) Poll(context.Context, string) (netease.QRPollResult, error) {
	return f.pollResult, nil
}

func (f *fakeNeteaseQRService) Cancel(string) error {
	f.canceled = true
	return nil
}

func newAdminAPITestHandler(t *testing.T, manager *fakeAccountManager, qr *fakeQRService) (http.Handler, *admin.User) {
	return newAdminAPITestHandlerWithNetease(t, manager, qr, &fakeNeteaseQRService{})
}

func newAdminAPITestHandlerWithNetease(t *testing.T, manager *fakeAccountManager, qr *fakeQRService, neteaseQR *fakeNeteaseQRService) (http.Handler, *admin.User) {
	t.Helper()
	store, err := admin.Open(filepath.Join(t.TempDir(), "adminapi.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := store.Close(); err != nil {
			t.Errorf("close admin store: %v", err)
		}
	})
	created, user, err := store.EnsureInitialUser(context.Background(), "admin", "correct-password")
	if err != nil || !created {
		t.Fatalf("create initial admin: created=%v user=%+v err=%v", created, user, err)
	}
	auth, err := admin.NewAuthService(store, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	handler, err := NewHandler(
		store,
		auth,
		manager,
		qr,
		neteaseQR,
		log.New(io.Discard, "", 0),
		Config{AllowedOrigins: []string{"http://127.0.0.1:5173"}},
	)
	if err != nil {
		t.Fatal(err)
	}
	return handler, &user
}

func performRequest(t *testing.T, handler http.Handler, method, path, body, token, origin string) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(method, path, strings.NewReader(body))
	if body != "" {
		request.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	if origin != "" {
		request.Header.Set("Origin", origin)
	}
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	return recorder
}

func loginAsTestAdmin(t *testing.T, handler http.Handler) (string, admin.User) {
	t.Helper()
	response := performRequest(t, handler, http.MethodPost, "/api/admin/login", `{"username":"admin","password":"correct-password"}`, "", "")
	if response.Code != http.StatusOK {
		t.Fatalf("login status=%d body=%s", response.Code, response.Body.String())
	}
	var payload struct {
		Token string     `json:"token"`
		User  admin.User `json:"user"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Token == "" || payload.User.ID <= 0 {
		t.Fatalf("unexpected login response: %+v", payload)
	}
	return payload.Token, payload.User
}

func TestAdminAPIRequiresBearerAndSetsSecurityHeaders(t *testing.T) {
	manager := &fakeAccountManager{}
	handler, _ := newAdminAPITestHandler(t, manager, &fakeQRService{})

	unauthorized := performRequest(t, handler, http.MethodGet, "/api/admin/users", "", "", "")
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", unauthorized.Code, unauthorized.Body.String())
	}
	if unauthorized.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("missing no-store header: %v", unauthorized.Header())
	}

	preflight := performRequest(t, handler, http.MethodOptions, "/api/admin/users", "", "", "http://127.0.0.1:5173")
	if preflight.Code != http.StatusNoContent {
		t.Fatalf("unexpected preflight status: %d", preflight.Code)
	}
	if preflight.Header().Get("Access-Control-Allow-Origin") != "http://127.0.0.1:5173" {
		t.Fatalf("unexpected CORS headers: %v", preflight.Header())
	}
	if !strings.Contains(preflight.Header().Get("Access-Control-Allow-Headers"), "Authorization") {
		t.Fatalf("Authorization must be allowed: %v", preflight.Header())
	}
}

func TestAdminAPIUserCrudAndAccountViewsDoNotLeakSecrets(t *testing.T) {
	manager := &fakeAccountManager{items: []account.PublicAccount{{
		ID: 7, Available: true, LoggedIn: true, UINMasked: "2091****70",
		VipLevel: account.VipLevelVIP, VipLevelName: "VIP", LoginValid: true,
	}}}
	handler, initialUser := newAdminAPITestHandler(t, manager, &fakeQRService{})
	token, currentUser := loginAsTestAdmin(t, handler)

	users := performRequest(t, handler, http.MethodGet, "/api/admin/users", "", token, "")
	if users.Code != http.StatusOK || !strings.Contains(users.Body.String(), "admin") {
		t.Fatalf("unexpected users response: status=%d body=%s", users.Code, users.Body.String())
	}
	if strings.Contains(users.Body.String(), "pbkdf2") || strings.Contains(strings.ToLower(users.Body.String()), "password") {
		t.Fatalf("admin response leaked password data: %s", users.Body.String())
	}

	created := performRequest(t, handler, http.MethodPost, "/api/admin/users", `{"username":"operator","password":"operator-password"}`, token, "")
	if created.Code != http.StatusCreated {
		t.Fatalf("create admin status=%d body=%s", created.Code, created.Body.String())
	}
	var createdPayload struct {
		User admin.User `json:"user"`
	}
	if err := json.Unmarshal(created.Body.Bytes(), &createdPayload); err != nil {
		t.Fatal(err)
	}
	if createdPayload.User.ID <= 0 || createdPayload.User.Username != "operator" {
		t.Fatalf("unexpected created admin: %+v", createdPayload.User)
	}

	selfDelete := performRequest(t, handler, http.MethodDelete, "/api/admin/users/"+strconv.FormatInt(currentUser.ID, 10), "", token, "")
	if selfDelete.Code != http.StatusConflict {
		t.Fatalf("expected self-delete conflict, got %d: %s", selfDelete.Code, selfDelete.Body.String())
	}

	accounts := performRequest(t, handler, http.MethodGet, "/api/admin/accounts", "", token, "")
	if accounts.Code != http.StatusOK {
		t.Fatalf("list accounts status=%d body=%s", accounts.Code, accounts.Body.String())
	}
	if strings.Contains(accounts.Body.String(), "209192670") || strings.Contains(accounts.Body.String(), "qm_keyst") {
		t.Fatalf("account response leaked sensitive fields: %s", accounts.Body.String())
	}

	updateKey := performRequest(t, handler, http.MethodPatch, "/api/admin/accounts/7/credential", `{"credential":"new-secret-key"}`, token, "")
	if updateKey.Code != http.StatusOK {
		t.Fatalf("update key status=%d body=%s", updateKey.Code, updateKey.Body.String())
	}
	if strings.Contains(updateKey.Body.String(), "new-secret-key") {
		t.Fatalf("qm_keyst leaked in update response: %s", updateKey.Body.String())
	}
	if manager.lastKey != "new-secret-key" {
		t.Fatalf("manager did not receive new key: %q", manager.lastKey)
	}

	deletedUser := performRequest(t, handler, http.MethodDelete, "/api/admin/users/"+strconv.FormatInt(createdPayload.User.ID, 10), "", token, "")
	if deletedUser.Code != http.StatusNoContent {
		t.Fatalf("delete admin status=%d body=%s", deletedUser.Code, deletedUser.Body.String())
	}
	if currentUser.ID != initialUser.ID {
		t.Fatalf("login returned wrong current user: got=%d want=%d", currentUser.ID, initialUser.ID)
	}
}

func TestAdminAPIQRPollSavesAccountWithoutReturningCredentials(t *testing.T) {
	manager := &fakeAccountManager{}
	qr := &fakeQRService{pollResult: qqlogin.PollResult{
		Session: qqlogin.Session{ID: "opaque-session", Status: qqlogin.StatusCompleted, Message: "登录成功"},
		UIN:     "209192670",
		QMKeyst: "secret-qm-key",
	}}
	handler, _ := newAdminAPITestHandler(t, manager, qr)
	token, _ := loginAsTestAdmin(t, handler)

	started := performRequest(t, handler, http.MethodPost, "/api/admin/qr-sessions?type=qq", "", token, "")
	if started.Code != http.StatusCreated || strings.Contains(started.Body.String(), "qrsig") {
		t.Fatalf("unexpected QR start response: status=%d body=%s", started.Code, started.Body.String())
	}
	if !strings.Contains(started.Body.String(), `"imageUrl":"/qr-sessions/opaque-session/image"`) {
		t.Fatalf("unexpected QR image URL: %s", started.Body.String())
	}

	image := performRequest(t, handler, http.MethodGet, "/api/admin/qr-sessions/opaque-session/image", "", token, "")
	if image.Code != http.StatusOK || image.Header().Get("Content-Type") != "image/png" || image.Body.String() != "png-image" {
		t.Fatalf("unexpected QR image response: status=%d headers=%v body=%q", image.Code, image.Header(), image.Body.String())
	}

	polled := performRequest(t, handler, http.MethodGet, "/api/admin/qr-sessions/opaque-session", "", token, "")
	if polled.Code != http.StatusOK {
		t.Fatalf("poll status=%d body=%s", polled.Code, polled.Body.String())
	}
	responseBody := polled.Body.String()
	if strings.Contains(responseBody, "secret-qm-key") || strings.Contains(responseBody, "209192670") {
		t.Fatalf("QR poll response leaked credentials: %s", responseBody)
	}
	if manager.upsertCalls != 1 || manager.lastUIN != "209192670" || manager.lastKey != "secret-qm-key" {
		t.Fatalf("QR result was not saved exactly once: calls=%d uin=%q key=%q", manager.upsertCalls, manager.lastUIN, manager.lastKey)
	}
	if !strings.Contains(responseBody, "2091****70") {
		t.Fatalf("expected masked account in QR response: %s", responseBody)
	}

	canceled := performRequest(t, handler, http.MethodDelete, "/api/admin/qr-sessions/opaque-session", "", token, "")
	if canceled.Code != http.StatusNoContent || !qr.canceled {
		t.Fatalf("QR session was not canceled: status=%d canceled=%v", canceled.Code, qr.canceled)
	}
}

func TestAdminAPINeteaseQRPollSavesTypedAccountWithoutReturningCookie(t *testing.T) {
	manager := &fakeAccountManager{}
	now := time.Now().UTC()
	neteaseQR := &fakeNeteaseQRService{
		startResult: netease.QRStartResult{
			QRSession: netease.QRSession{ID: "netease-session", Status: netease.QRStatusWaiting, Message: "等待扫码", ExpiresAt: now.Add(time.Minute)},
			ImagePNG:  []byte("netease-png"),
		},
		pollResult: netease.QRPollResult{
			QRSession:     netease.QRSession{ID: "netease-session", Status: netease.QRStatusCompleted, Message: "登录成功", ExpiresAt: now.Add(time.Minute)},
			UID:           987654321,
			Nickname:      "网易云用户",
			Cookie:        "MUSIC_U=secret-netease-cookie",
			AuthExpiresAt: &now,
		},
	}
	handler, _ := newAdminAPITestHandlerWithNetease(t, manager, &fakeQRService{}, neteaseQR)
	token, _ := loginAsTestAdmin(t, handler)

	started := performRequest(t, handler, http.MethodPost, "/api/admin/qr-sessions?type=netease", "", token, "")
	if started.Code != http.StatusCreated || !strings.Contains(started.Body.String(), "netease-session") {
		t.Fatalf("unexpected NetEase QR start: status=%d body=%s", started.Code, started.Body.String())
	}
	image := performRequest(t, handler, http.MethodGet, "/api/admin/qr-sessions/netease-session/image", "", token, "")
	if image.Code != http.StatusOK || image.Body.String() != "netease-png" {
		t.Fatalf("unexpected NetEase QR image: status=%d body=%q", image.Code, image.Body.String())
	}
	polled := performRequest(t, handler, http.MethodGet, "/api/admin/qr-sessions/netease-session", "", token, "")
	body := polled.Body.String()
	if polled.Code != http.StatusOK {
		t.Fatalf("poll status=%d body=%s", polled.Code, body)
	}
	if strings.Contains(body, "secret-netease-cookie") || strings.Contains(body, "987654321") {
		t.Fatalf("NetEase QR response leaked credentials: %s", body)
	}
	if manager.upsertCalls != 1 || manager.lastType != account.AccountTypeNetease || manager.lastUIN != "987654321" {
		t.Fatalf("unexpected NetEase save: calls=%d type=%s uid=%s key=%s", manager.upsertCalls, manager.lastType, manager.lastUIN, manager.lastKey)
	}
	if !strings.Contains(body, "9876****21") || !strings.Contains(body, `"accountType":"netease"`) {
		t.Fatalf("missing typed masked account in response: %s", body)
	}
}

func TestAdminAPICreatesManualTypedAccount(t *testing.T) {
	manager := &fakeAccountManager{}
	handler, _ := newAdminAPITestHandler(t, manager, &fakeQRService{})
	token, _ := loginAsTestAdmin(t, handler)

	response := performRequest(t, handler, http.MethodPost, "/api/admin/accounts", `{"accountType":"netease","uid":"12345678","credential":"MUSIC_U=cookie"}`, token, "")
	if response.Code != http.StatusCreated {
		t.Fatalf("unexpected create response: status=%d body=%s", response.Code, response.Body.String())
	}
	if manager.lastType != account.AccountTypeNetease || manager.lastUIN != "12345678" || manager.lastKey != "MUSIC_U=cookie" {
		t.Fatalf("manual account payload was not forwarded: type=%s uid=%s key=%s", manager.lastType, manager.lastUIN, manager.lastKey)
	}
}

func TestAdminAPILoginRejectsWrongPassword(t *testing.T) {
	handler, _ := newAdminAPITestHandler(t, &fakeAccountManager{}, &fakeQRService{})
	response := performRequest(t, handler, http.MethodPost, "/api/admin/login", `{"username":"admin","password":"bad-password"}`, "", "")
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", response.Code, response.Body.String())
	}
	var payload map[string]any
	if err := json.NewDecoder(bytes.NewReader(response.Body.Bytes())).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	errorBody, _ := payload["error"].(map[string]any)
	if errorBody["code"] != "invalid_credentials" {
		t.Fatalf("unexpected error payload: %v", payload)
	}
}

func TestAdminAPIPublicAuthSettingRequiresLoginAndCanBeToggled(t *testing.T) {
	handler, _ := newAdminAPITestHandler(t, &fakeAccountManager{}, &fakeQRService{})

	unauthorized := performRequest(t, handler, http.MethodGet, "/api/admin/settings/public-api-auth", "", "", "")
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated setting request status=%d body=%s", unauthorized.Code, unauthorized.Body.String())
	}

	token, _ := loginAsTestAdmin(t, handler)
	initial := performRequest(t, handler, http.MethodGet, "/api/admin/settings/public-api-auth", "", token, "")
	if initial.Code != http.StatusOK || !strings.Contains(initial.Body.String(), `"required":false`) {
		t.Fatalf("unexpected initial setting: status=%d body=%s", initial.Code, initial.Body.String())
	}

	enabled := performRequest(t, handler, http.MethodPut, "/api/admin/settings/public-api-auth", `{"required":true}`, token, "")
	if enabled.Code != http.StatusOK || !strings.Contains(enabled.Body.String(), `"required":true`) {
		t.Fatalf("enable setting status=%d body=%s", enabled.Code, enabled.Body.String())
	}

	updated := performRequest(t, handler, http.MethodGet, "/api/admin/settings/public-api-auth", "", token, "")
	if updated.Code != http.StatusOK || !strings.Contains(updated.Body.String(), `"required":true`) {
		t.Fatalf("updated setting status=%d body=%s", updated.Code, updated.Body.String())
	}

	disabled := performRequest(t, handler, http.MethodPut, "/api/admin/settings/public-api-auth", `{"required":false}`, token, "")
	if disabled.Code != http.StatusOK || !strings.Contains(disabled.Body.String(), `"required":false`) {
		t.Fatalf("disable setting status=%d body=%s", disabled.Code, disabled.Body.String())
	}

	missing := performRequest(t, handler, http.MethodPut, "/api/admin/settings/public-api-auth", `{}`, token, "")
	if missing.Code != http.StatusBadRequest {
		t.Fatalf("missing required field status=%d body=%s", missing.Code, missing.Body.String())
	}
}
