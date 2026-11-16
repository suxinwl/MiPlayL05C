package qqlogin

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

type rewriteTransport struct {
	target *url.URL
}

type testLogWriter struct {
	t *testing.T
}

func (writer testLogWriter) Write(data []byte) (int, error) {
	writer.t.Log(strings.TrimSpace(string(data)))
	return len(data), nil
}

func (transport rewriteTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	copied := request.Clone(request.Context())
	copied.URL.Scheme = transport.target.Scheme
	copied.URL.Host = transport.target.Host
	return http.DefaultTransport.RoundTrip(copied)
}

func TestHash33KnownValues(t *testing.T) {
	tests := map[string]int64{
		"test":   4282592,
		"qrsig":  138234694,
		"abc123": 1768482556,
	}
	for input, want := range tests {
		if got := hash33(input); got != want {
			t.Errorf("hash33(%q)=%d, want %d", input, got, want)
		}
	}
}

func TestNormalizeUIN(t *testing.T) {
	tests := map[string]string{
		"o00209192670": "209192670",
		"00209192670":  "209192670",
		"209192670":    "209192670",
		"":             "",
		"000":          "000",
	}
	for input, want := range tests {
		if got := normalizeUIN(input); got != want {
			t.Errorf("normalizeUIN(%q)=%q, want %q", input, got, want)
		}
	}
}

func TestParsePTUICB(t *testing.T) {
	body := `ptuiCB('67','0','','0','已扫描，等待确认','');`
	code, message, redirect, err := parsePTUICB(body)
	if err != nil {
		t.Fatal(err)
	}
	if code != 67 || message != "已扫描，等待确认" || redirect != "" {
		t.Fatalf("unexpected parse result: code=%d message=%q redirect=%q", code, message, redirect)
	}
}

func TestUnescapePTURL(t *testing.T) {
	raw := `https:\/\/ptlogin2.qq.com\/check_sig?uin=o00209192670\x26pttype=1&amp;x=1`
	want := `https://ptlogin2.qq.com/check_sig?uin=o00209192670&pttype=1&x=1`
	if got := unescapePTURL(raw); got != want {
		t.Fatalf("unescapePTURL(%q)=%q, want %q", raw, got, want)
	}
}

func TestQRLoginFlowWithMockedQQEndpoints(t *testing.T) {
	var server *httptest.Server
	handler := http.NewServeMux()
	handler.HandleFunc("/xlogin", func(w http.ResponseWriter, r *http.Request) {
		http.SetCookie(w, &http.Cookie{Name: "pt_login_sig", Value: "mock-login-sig", Path: "/"})
		_, _ = w.Write([]byte("login page"))
	})
	handler.HandleFunc("/ptqrshow", func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.Header.Get("Cookie"), "pt_login_sig=mock-login-sig") {
			t.Errorf("pt_login_sig cookie missing from QR request: %s", r.Header.Get("Cookie"))
		}
		http.SetCookie(w, &http.Cookie{Name: "qrsig", Value: "mock-qrsig", Path: "/"})
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write([]byte("mock-png"))
	})
	handler.HandleFunc("/ptqrlogin", func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("ptqrtoken"); got != fmt.Sprint(hash33("mock-qrsig")) {
			t.Errorf("unexpected ptqrtoken: %s", got)
		}
		if !strings.Contains(r.Header.Get("Cookie"), "qrsig=mock-qrsig") {
			t.Errorf("qrsig cookie missing: %s", r.Header.Get("Cookie"))
		}
		if got := r.URL.Query().Get("login_sig"); got != "mock-login-sig" {
			t.Errorf("unexpected login_sig: %s", got)
		}
		checkURL := server.URL + "/check_sig?uin=o00209192670&ptsigx=mock-sigx"
		_, _ = fmt.Fprintf(w, `ptuiCB('0','0','%s','0','登录成功','');`, checkURL)
	})
	handler.HandleFunc("/check_sig", func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Cookie"); got != "" {
			t.Errorf("standard check_sig must not carry cookies, got %q", got)
		}
		http.SetCookie(w, &http.Cookie{Name: "p_skey", Value: "mock-p-skey", Path: "/"})
		http.SetCookie(w, &http.Cookie{Name: "pt_oauth_token", Value: "mock-oauth-token", Path: "/"})
		http.SetCookie(w, &http.Cookie{Name: "superkey", Value: "must-not-be-used-for-gtk", Path: "/"})
		http.Redirect(w, r, server.URL+"/check_sig_landing", http.StatusFound)
	})
	handler.HandleFunc("/oauth2.0/authorize", func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Errorf("parse authorize form: %v", err)
		}
		if r.Form.Get("client_id") != pt3rdAID || r.Form.Get("response_type") != "code" {
			t.Errorf("unexpected authorize form: %v", r.Form)
		}
		if got, want := r.Form.Get("g_tk"), fmt.Sprint(gtkFromPSkey("mock-p-skey")); got != want {
			t.Errorf("g_tk=%q, want %q for p_skey", got, want)
		}
		if got := r.Form.Get("ui"); got == "" {
			t.Error("ui must be generated when the ui cookie is absent")
		}
		if cookie, err := r.Cookie("p_skey"); err != nil || cookie.Value != "mock-p-skey" {
			t.Errorf("p_skey cookie missing from authorize request: cookie=%v err=%v", cookie, err)
		}
		http.Redirect(w, r, server.URL+"/callback?code=mock-oauth-code", http.StatusFound)
	})
	handler.HandleFunc("/callback", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("?code=" + r.URL.Query().Get("code")))
	})
	handler.HandleFunc("/musicu", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(body), `"code":"mock-oauth-code"`) {
			t.Errorf("OAuth code missing from music login body: %s", body)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"code":0,"req":{"code":0,"data":{"musickey":"mock-qm-key","uin":209192670}}}`))
	})
	server = httptest.NewServer(handler)
	defer server.Close()
	target, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Transport: rewriteTransport{target: target}}
	service, err := NewService(
		log.New(testLogWriter{t: t}, "", 0),
		WithHTTPClient(client),
		WithEndpoints(server.URL+"/xlogin", server.URL+"/ptqrshow", server.URL+"/ptqrlogin", server.URL+"/musicu"),
	)
	if err != nil {
		t.Fatal(err)
	}
	started, err := service.Start(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if started.ID == "" || started.Status != StatusWaiting || string(started.ImagePNG) != "mock-png" {
		t.Fatalf("unexpected start result: %+v", started)
	}
	polled, err := service.Poll(context.Background(), started.ID)
	if err != nil {
		t.Fatal(err)
	}
	if polled.Status != StatusCompleted || polled.UIN != "209192670" || polled.QMKeyst != "mock-qm-key" {
		t.Fatalf("unexpected poll result: %+v", polled)
	}
	encodedSession, err := json.Marshal(polled.Session)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encodedSession), "mock-qrsig") || strings.Contains(string(encodedSession), "mock-qm-key") {
		t.Fatalf("session JSON leaked credentials: %s", encodedSession)
	}
	encodedPoll, err := json.Marshal(polled)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encodedPoll), "209192670") || strings.Contains(string(encodedPoll), "mock-qm-key") {
		t.Fatalf("poll JSON leaked credentials: %s", encodedPoll)
	}
}

func TestCookiesForURLUsesBrowserDomainRules(t *testing.T) {
	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatal(err)
	}
	jar.SetCookies(mustURL("https://ptlogin2.qq.com/"), []*http.Cookie{
		{Name: "pt2gguin", Value: "o0123456", Domain: ".qq.com", Path: "/"},
		{Name: "host_only", Value: "secret", Path: "/"},
	})
	got := cookiesForURL(jar, mustURL("https://ssl.ptlogin2.graph.qq.com/check_sig"))
	if got["pt2gguin"] != "o0123456" {
		t.Fatalf("qq.com cookie was not sent to check_sig host: %#v", got)
	}
	if _, ok := got["host_only"]; ok {
		t.Fatalf("host-only cookie leaked to another host: %#v", got)
	}
}

func TestExchangeRetriesCheckSigWithHostCookies(t *testing.T) {
	var server *httptest.Server
	handler := http.NewServeMux()
	handler.HandleFunc("/check_sig", func(w http.ResponseWriter, r *http.Request) {
		cookie := r.Header.Get("Cookie")
		if cookie == "" {
			http.SetCookie(w, &http.Cookie{Name: "pt_oauth_token", Value: "first-hop-token", Path: "/"})
			http.Redirect(w, r, server.URL+"/oauth2.0/show", http.StatusFound)
			return
		}
		if cookie != "pt2gguin=o0123456" {
			t.Errorf("browser retry carried unexpected cookies: %q", cookie)
		}
		http.SetCookie(w, &http.Cookie{Name: "p_skey", Value: "retry-p-skey", Path: "/"})
		http.SetCookie(w, &http.Cookie{Name: "pt4_token", Value: "retry-token", Path: "/"})
		http.Redirect(w, r, server.URL+"/oauth2.0/show", http.StatusFound)
	})
	handler.HandleFunc("/oauth2.0/authorize", func(w http.ResponseWriter, r *http.Request) {
		if cookie, err := r.Cookie("p_skey"); err != nil || cookie.Value != "retry-p-skey" {
			t.Errorf("authorize missing retry p_skey: cookie=%v err=%v", cookie, err)
		}
		http.Redirect(w, r, server.URL+"/callback?code=mock-code", http.StatusFound)
	})
	handler.HandleFunc("/musicu", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(body), `"tmeLoginType":2`) {
			t.Errorf("music login must use QQ login type 2: %s", body)
		}
		_, _ = w.Write([]byte(`{"code":0,"req":{"code":0,"data":{"musickey":"mock-key","musicid":123456}}}`))
	})
	server = httptest.NewServer(handler)
	defer server.Close()
	target, _ := url.Parse(server.URL)
	service, err := NewService(
		log.New(testLogWriter{t: t}, "", 0),
		WithHTTPClient(&http.Client{Transport: rewriteTransport{target: target}}),
		WithEndpoints(server.URL, server.URL, server.URL, server.URL+"/musicu"),
	)
	if err != nil {
		t.Fatal(err)
	}
	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatal(err)
	}
	jar.SetCookies(mustURL("https://ptlogin2.qq.com/"), []*http.Cookie{
		{Name: "pt2gguin", Value: "o0123456", Domain: ".qq.com", Path: "/"},
		{Name: "qrsig", Value: "must-not-leak", Path: "/"},
	})
	uin, key, err := service.exchange(
		context.Background(),
		"https://ssl.ptlogin2.graph.qq.com/check_sig?uin=o0123456&ptsigx=SIGX&s_url=https%3A%2F%2Fgraph.qq.com%2Foauth2.0%2Flogin_jump",
		jar,
	)
	if err != nil {
		t.Fatal(err)
	}
	if uin != "123456" || key != "mock-key" {
		t.Fatalf("unexpected credentials: uin=%q key=%q", uin, key)
	}
}

func TestSafeURLForLogDoesNotExposeSecrets(t *testing.T) {
	raw := "https://graph.qq.com/oauth2.0/callback?code=secret-code&access_token=secret-token&state=unique-state-value#fragment"
	got := safeURLForLog(raw)
	for _, secret := range []string{"secret-code", "secret-token", "unique-state-value", "fragment"} {
		if strings.Contains(got, secret) {
			t.Fatalf("safeURLForLog leaked %q: %s", secret, got)
		}
	}
	if !strings.Contains(got, "graph.qq.com") || !strings.Contains(got, "code") {
		t.Fatalf("safeURLForLog lost safe diagnostics: %s", got)
	}
}

func TestQRLoginStartDoesNotLeakQRSIGThroughPublicView(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.SetCookie(w, &http.Cookie{Name: "pt_login_sig", Value: "mock-login-sig", Path: "/"})
		http.SetCookie(w, &http.Cookie{Name: "qrsig", Value: "super-secret-qrsig", Path: "/"})
		_, _ = w.Write([]byte("png"))
	}))
	defer server.Close()
	target, _ := url.Parse(server.URL)
	service, err := NewService(
		log.New(io.Discard, "", 0),
		WithHTTPClient(&http.Client{Transport: rewriteTransport{target: target}}),
		WithEndpoints(server.URL, server.URL, server.URL, server.URL),
	)
	if err != nil {
		t.Fatal(err)
	}
	started, err := service.Start(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(started)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "super-secret-qrsig") || strings.Contains(string(encoded), "png") {
		t.Fatalf("start result JSON leaked internal data: %s", encoded)
	}
}

func TestQRLoginRejectsExpiredAndInvalidSessions(t *testing.T) {
	service, err := NewService(log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := service.Poll(context.Background(), "missing"); err != ErrSessionNotFound {
		t.Fatalf("expected ErrSessionNotFound, got %v", err)
	}
	if err := service.Cancel("missing"); err != ErrSessionNotFound {
		t.Fatalf("expected ErrSessionNotFound from cancel, got %v", err)
	}
}
