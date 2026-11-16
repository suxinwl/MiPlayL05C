package netease

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func newTestClient(t *testing.T, server *httptest.Server) *Client {
	t.Helper()
	client, err := NewClient(WithBaseURL(server.URL))
	if err != nil {
		t.Fatal(err)
	}
	client.now = func() time.Time { return time.Date(2026, 11, 9, 10, 0, 0, 0, time.UTC) }
	return client
}

func TestClientCheckReturnsCanonicalCookieAndExpiry(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/weapi/w/nuser/account/get" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		if err := r.ParseForm(); err != nil {
			t.Error(err)
		}
		if r.Form.Get("params") == "" || r.Form.Get("encSecKey") == "" {
			t.Error("missing encrypted payload")
		}
		http.SetCookie(w, &http.Cookie{Name: "MUSIC_U", Value: "refreshed-cookie", Path: "/", MaxAge: 3600})
		http.SetCookie(w, &http.Cookie{Name: "__csrf", Value: "next-csrf", Path: "/"})
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"code":200,"account":{"id":12345},"profile":{"nickname":"网易云用户","avatarUrl":"https://example.com/a.png"}}`))
	}))
	defer server.Close()

	state, err := newTestClient(t, server).Check(context.Background(), "MUSIC_U=original", "12345")
	if err != nil {
		t.Fatal(err)
	}
	if state.UID != 12345 || state.Nickname != "网易云用户" || state.AvatarURL != "https://example.com/a.png" {
		t.Fatalf("unexpected account state: %+v", state)
	}
	if !strings.Contains(state.Cookie, "MUSIC_U=refreshed-cookie") || !strings.Contains(state.Cookie, "__csrf=next-csrf") {
		t.Fatalf("response cookies were not merged: %q", state.Cookie)
	}
	if state.ExpiresAt == nil || !state.ExpiresAt.Equal(time.Date(2026, 11, 9, 11, 0, 0, 0, time.UTC)) {
		t.Fatalf("unexpected cookie expiry: %v", state.ExpiresAt)
	}
}

func TestClientCheckRejectsUIDMismatch(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"code":200,"account":{"id":12345},"profile":{"nickname":"user"}}`))
	}))
	defer server.Close()

	_, err := newTestClient(t, server).Check(context.Background(), "MUSIC_U=original", "99999")
	if !errors.Is(err, ErrUIDMismatch) {
		t.Fatalf("expected UID mismatch, got %v", err)
	}
}

func TestClientCheckMapsUnauthorizedBusinessCode(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"code":301,"message":"需要登录"}`))
	}))
	defer server.Close()

	_, err := newTestClient(t, server).Check(context.Background(), "MUSIC_U=expired", "")
	if !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("expected unauthorized, got %v", err)
	}
}

func TestClientRefreshUsesRefreshedCookie(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/weapi/login/token/refresh":
			http.SetCookie(w, &http.Cookie{Name: "MUSIC_U", Value: "new-cookie", Path: "/", MaxAge: 7200})
			_, _ = w.Write([]byte(`{"code":200,"bizCode":"201"}`))
		case "/weapi/w/nuser/account/get":
			cookie, err := r.Cookie("MUSIC_U")
			if err != nil || cookie.Value != "new-cookie" {
				t.Errorf("refresh cookie was not used: cookie=%v err=%v", cookie, err)
			}
			_, _ = w.Write([]byte(`{"code":200,"account":{"id":12345},"profile":{"nickname":"refreshed"}}`))
		default:
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
	}))
	defer server.Close()

	state, err := newTestClient(t, server).Refresh(context.Background(), "MUSIC_U=old-cookie", "12345")
	if err != nil {
		t.Fatal(err)
	}
	if state.Cookie == "" || !strings.Contains(state.Cookie, "MUSIC_U=new-cookie") || state.Nickname != "refreshed" {
		t.Fatalf("unexpected refreshed state: %+v", state)
	}
}

func TestClientGetVIPStatusParsesActiveMembership(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/weapi/music-vip-membership/front/vip/info" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"code":200,
			"data":{
				"associator":{"vipCode":100,"expireTime":1795363199000},
				"musicPackage":{"expireTime":1795363199000},
				"redVipLevel":1
			}
		}`))
	}))
	defer server.Close()

	status, err := newTestClient(t, server).GetVIPStatus(context.Background(), "MUSIC_U=original", "12345")
	if err != nil {
		t.Fatal(err)
	}
	if !status.Active || status.Level != 1 || status.VipCode != 100 || status.RedVipLevel != 1 {
		t.Fatalf("unexpected VIP status: %+v", status)
	}
	want := time.Date(2026, 11, 22, 15, 59, 59, 0, time.UTC)
	if status.ExpiresAt == nil || !status.ExpiresAt.Equal(want) {
		t.Fatalf("unexpected VIP expiry: %v", status.ExpiresAt)
	}
}

func TestClientInvitationDetailAndAcceptUseOfficialFormFormat(t *testing.T) {
	accepted := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/vipactivity/app/vip/invitation/detail/info/get":
			if r.Method != http.MethodGet {
				t.Errorf("detail method = %s", r.Method)
			}
			if r.URL.Query().Get("token") != "invite-token" || r.URL.Query().Get("csrf_token") != "csrf-value" {
				t.Errorf("unexpected detail query: %s", r.URL.RawQuery)
			}
			_, _ = w.Write([]byte(`{"code":200,"data":{"recordId":0,"currentUserRecordId":0,"tokenExpireTime":1796054399999,"duration":0}}`))
		case "/api/vipactivity/app/vip/invitation/accept":
			if r.Method != http.MethodPost {
				t.Errorf("accept method = %s", r.Method)
			}
			if r.URL.Query().Get("csrf_token") != "csrf-value" {
				t.Errorf("accept query missing csrf: %s", r.URL.RawQuery)
			}
			if err := r.ParseForm(); err != nil {
				t.Error(err)
			}
			if r.Form.Get("token") != "invite-token" || r.Form.Get("csrf_token") != "csrf-value" {
				t.Errorf("unexpected accept form: %v", r.Form)
			}
			accepted = true
			_, _ = w.Write([]byte(`{"code":200,"message":"","data":{"duration":7}}`))
		default:
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
	}))
	defer server.Close()

	client, err := NewClient(WithAppBaseURL(server.URL))
	if err != nil {
		t.Fatal(err)
	}
	cookie := "MUSIC_U=account-token; __csrf=csrf-value"
	detail, err := client.GetInvitationDetail(context.Background(), cookie, "invite-token", "invite-cashier", "https://y.music.163.com/g/vip-invite-cashier/test")
	if err != nil {
		t.Fatal(err)
	}
	if detail.TokenExpireTime == nil || detail.CurrentUserRecordID != 0 {
		t.Fatalf("unexpected invitation detail: %+v", detail)
	}
	if _, err := client.AcceptInvitation(context.Background(), cookie, "invite-token", "invite-cashier", "https://y.music.163.com/g/vip-invite-cashier/test"); err != nil {
		t.Fatal(err)
	}
	if !accepted {
		t.Fatal("accept endpoint was not called")
	}
}

func TestClientAcceptInvitationMapsRiskCode(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"code":12208,"message":"活动太火爆了"}`))
	}))
	defer server.Close()

	client, err := NewClient(WithAppBaseURL(server.URL))
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.AcceptInvitation(context.Background(), "MUSIC_U=account-token; __csrf=csrf-value", "invite-token", "invite-cashier", "")
	if !errors.Is(err, ErrInvitationRisk) {
		t.Fatalf("expected risk error, got %v", err)
	}
}
