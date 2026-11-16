package account

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestNeteaseVIPFeedFetchesNewestUniqueInvitations(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Accept") != "application/json" {
			t.Errorf("unexpected Accept header: %q", r.Header.Get("Accept"))
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{
			"ok":true,
			"items":[
				{"id":"old","created_at":100},
				{"id":"new","created_at":300},
				{"id":"new","created_at":300},
				{"id":"middle","created_at":200}
			]
		}`)
	}))
	defer server.Close()

	feed := newNeteaseVIPFeedClient(server.URL, time.Second, 10)
	invitations, err := feed.fetch(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(invitations) != 3 || invitations[0].ID != "new" || invitations[1].ID != "middle" || invitations[2].ID != "old" {
		t.Fatalf("unexpected invitations: %+v", invitations)
	}
}

func TestNeteaseVIPClaimClientResolvesOfficialInvitation(t *testing.T) {
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/":
			http.SetCookie(w, &http.Cookie{Name: "wy_admin_sid", Value: "session", Path: "/"})
			w.Header().Set("Content-Type", "text/html")
			fmt.Fprint(w, "<html>home</html>")
		case "/index.php":
			if r.URL.Query().Get("action") != "claim" || r.Method != http.MethodPost {
				t.Errorf("unexpected claim request: %s %s", r.Method, r.URL.String())
			}
			if cookie, err := r.Cookie("wy_admin_sid"); err != nil || cookie.Value != "session" {
				t.Errorf("claim session cookie missing: cookie=%v err=%v", cookie, err)
			}
			var payload map[string]string
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Error(err)
			}
			if payload["id"] != "invite-id" {
				t.Errorf("unexpected claim payload: %v", payload)
			}
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"ok":true,"url":%q}`, server.URL+"/d/short-code")
		case "/d/short-code":
			http.SetCookie(w, &http.Cookie{Name: "feed_seed", Value: "test-seed", Path: "/"})
			w.Header().Set("Content-Type", "text/html")
			fmt.Fprint(w, "<html>redirect page</html>")
		case "/d/api.php":
			cookie, err := r.Cookie("feed_seed")
			if err != nil || cookie.Value != "test-seed" {
				t.Errorf("short-link cookie missing: cookie=%v err=%v", cookie, err)
			}
			var payload map[string]string
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Error(err)
			}
			if payload["code"] != "short-code" {
				t.Errorf("unexpected short code: %v", payload)
			}
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"ok":true,"url":"https://y.music.163.com/g/vip-invite-cashier/radsjl007?token=official-token"}`)
		default:
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
	}))
	defer server.Close()

	parsedServer, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	claimClient := &neteaseVIPClaimClient{
		httpClient:    &http.Client{Timeout: time.Second},
		claimEndpoint: server.URL + "/index.php?action=claim",
		shortBaseURL:  server.URL,
		shortHost:     parsedServer.Hostname(),
		userAgent:     "oo-music-test",
	}
	link, err := claimClient.claim(context.Background(), "invite-id")
	if err != nil {
		t.Fatal(err)
	}
	if link.Token != "official-token" || !strings.Contains(link.OfficialURL, "vip-invite-cashier/radsjl007") {
		t.Fatalf("unexpected official link: %+v", link)
	}
}
