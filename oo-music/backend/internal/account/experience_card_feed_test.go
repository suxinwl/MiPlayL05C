package account

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	oomusic "github.com/rankgice/oo-music"
)

func TestExperienceCardFeedFetchesNewestCandidatesAndDeduplicates(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Accept") != "application/json" {
			t.Errorf("unexpected Accept header: %q", r.Header.Get("Accept"))
		}
		if r.URL.Query().Get("action") != "qqmusic_list" {
			t.Errorf("unexpected action: %q", r.URL.Query().Get("action"))
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{
			"ok": true,
			"items": [
				{"id":"feed-old", "source":"qqmusic", "created_at":100},
				{"url":"https://y.qq.com/card?cardid=direct-new", "source":"qqmusic", "created_at":300},
				{"id":"feed-old", "source":"qqmusic", "created_at":100},
				{"id":"feed-middle", "source":"qqmusic", "created_at":200},
				{"url":"https://example.com/card?cardid=bad", "created_at":500},
				{"id":"netease-card", "source":"netease", "created_at":600}
			]
		}`)
	}))
	defer server.Close()

	feed := newExperienceCardFeedClient(server.URL+"/index.php?action=qqmusic_list&page=1", time.Second, 10)
	candidates, err := feed.fetch(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(candidates) != 3 {
		t.Fatalf("expected 3 valid deduplicated candidates, got %d: %+v", len(candidates), candidates)
	}
	if candidates[0].Request.CardID != "direct-new" {
		t.Fatalf("first candidate card ID = %q, want direct-new", candidates[0].Request.CardID)
	}
	if candidates[1].FeedID != "feed-middle" || candidates[2].FeedID != "feed-old" {
		t.Fatalf("unexpected feed candidate order: %+v", candidates)
	}
}

func TestExperienceCardFeedResolvesShortLinkToOfficialCard(t *testing.T) {
	var sawFeedCookie bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/index.php" && r.URL.Query().Get("action") == "qqmusic_claim":
			if r.Header.Get("Content-Type") != "application/json" {
				t.Errorf("unexpected content type: %q", r.Header.Get("Content-Type"))
			}
			var payload map[string]string
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Errorf("decode claim request: %v", err)
			}
			if payload["id"] != "feed-card" {
				t.Errorf("unexpected feed ID: %q", payload["id"])
			}
			http.SetCookie(w, &http.Cookie{Name: "wy_admin_sid", Value: "session", Path: "/", HttpOnly: true})
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"ok":true,"url":%q,"removed":false,"added":true}`, serverURL(r)+"/d/CODE123")
		case r.Method == http.MethodGet && r.URL.Path == "/d/CODE123":
			http.SetCookie(w, &http.Cookie{Name: "feed_seed", Value: "seed", Path: "/", HttpOnly: true})
			w.Header().Set("Content-Type", "text/html")
			fmt.Fprint(w, "<html>experience card</html>")
		case r.Method == http.MethodPost && r.URL.Path == "/d/api.php":
			cookie, err := r.Cookie("feed_seed")
			sawFeedCookie = err == nil && cookie.Value == "seed"
			var payload map[string]string
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Errorf("decode short-link exchange: %v", err)
			}
			if payload["code"] != "CODE123" {
				t.Errorf("unexpected short-link code: %q", payload["code"])
			}
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"ok":true,"url":"https://y.qq.com/m/basic/client/experience_card/index.html?ADTAG=yy_gnyy_hytyk&from=share&cardid=official-card"}`)
		default:
			http.Error(w, "unexpected request", http.StatusNotFound)
		}
	}))
	defer server.Close()

	feed := newExperienceCardFeedClient(server.URL+"/index.php?action=qqmusic_list&page=1", time.Second, 10)
	request, err := feed.resolve(context.Background(), "feed-card")
	if err != nil {
		t.Fatal(err)
	}
	if request.CardID != "official-card" || request.Source != oomusic.ExperienceCardSourceDefault {
		t.Fatalf("unexpected resolved request: %+v", request)
	}
	if !sawFeedCookie {
		t.Fatal("short-link exchange did not reuse the feed session cookie")
	}
}

func serverURL(r *http.Request) string {
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	return scheme + "://" + r.Host
}

func TestExperienceCardFeedRejectsInvalidResponses(t *testing.T) {
	tests := []struct {
		name       string
		statusCode int
		body       string
	}{
		{name: "http error", statusCode: http.StatusBadGateway, body: `{}`},
		{name: "business error", statusCode: http.StatusOK, body: `{"ok":false,"message":"busy"}`},
		{name: "no valid candidates", statusCode: http.StatusOK, body: `{"ok":true,"items":[{"url":"https://example.com/card?cardid=bad"}]}`},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(test.statusCode)
				fmt.Fprint(w, test.body)
			}))
			defer server.Close()

			feed := newExperienceCardFeedClient(server.URL, time.Second, 10)
			if _, err := feed.fetch(context.Background()); err == nil {
				t.Fatal("expected feed error")
			}
		})
	}
}

func TestPoolUsesLiveExperienceCardFeedWhenAllAccountsAreNonVIP(t *testing.T) {
	store, pool := openPoolTestStore(t)
	ctx := context.Background()
	now := time.Date(2026, 10, 27, 3, 0, 0, 0, time.UTC)
	pool.now = func() time.Time { return now }

	item, err := pool.Upsert(ctx, "10001", "key-1")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateVipStatus(ctx, item.ID, VipLevelNone, time.Time{}, now); err != nil {
		t.Fatal(err)
	}

	feedCalls := 0
	pool.experienceFeed = func(context.Context) ([]experienceCardCandidate, error) {
		feedCalls++
		return []experienceCardCandidate{{FeedID: "feed-card"}}, nil
	}
	resolveCalls := 0
	pool.resolveExperienceCard = func(_ context.Context, feedID string) (oomusic.ExperienceCardRequest, error) {
		resolveCalls++
		if feedID != "feed-card" {
			t.Fatalf("unexpected feed ID: %q", feedID)
		}
		return oomusic.ExperienceCardRequest{CardID: "live-card"}, nil
	}
	claimCalls := 0
	pool.claimExperienceCard = func(_ context.Context, _ *oomusic.Client, request oomusic.ExperienceCardRequest) (*oomusic.ExperienceCardClaimResult, error) {
		claimCalls++
		if request.CardID != "live-card" {
			t.Fatalf("unexpected card ID: %q", request.CardID)
		}
		return &oomusic.ExperienceCardClaimResult{}, nil
	}
	pool.readVipStatus = func(context.Context, *oomusic.Client, string) (*oomusic.CallResult, error) {
		return &oomusic.CallResult{
			Code: 0,
			Data: []byte(`{"infoMap":{"10001":{"iVipFlag":1,"sOverDateTime":"2027-01-01 00:00:00"}}}`),
		}, nil
	}

	selected, err := pool.SelectedStatus(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if feedCalls != 1 || resolveCalls != 1 || claimCalls != 1 {
		t.Fatalf("unexpected live claim calls: feed=%d resolve=%d claim=%d", feedCalls, resolveCalls, claimCalls)
	}
	if selected.ID != item.ID || selected.VipLevel == VipLevelNone {
		t.Fatalf("live claimed account was not selected: %+v", selected)
	}
}

func TestPoolLimitsFeedCandidateResolutionAttempts(t *testing.T) {
	store, pool := openPoolTestStore(t)
	ctx := context.Background()
	now := time.Date(2026, 10, 27, 3, 0, 0, 0, time.UTC)
	pool.now = func() time.Time { return now }
	item, err := pool.Upsert(ctx, "10001", "key-1")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateVipStatus(ctx, item.ID, VipLevelNone, time.Time{}, now); err != nil {
		t.Fatal(err)
	}

	pool.experienceFeed = func(context.Context) ([]experienceCardCandidate, error) {
		return []experienceCardCandidate{
			{FeedID: "one"},
			{FeedID: "two"},
			{FeedID: "three"},
			{FeedID: "four"},
			{FeedID: "five"},
		}, nil
	}
	resolveCalls := 0
	pool.resolveExperienceCard = func(context.Context, string) (oomusic.ExperienceCardRequest, error) {
		resolveCalls++
		return oomusic.ExperienceCardRequest{}, errors.New("feed resolution failed")
	}
	claimCalls := 0
	pool.claimExperienceCard = func(context.Context, *oomusic.Client, oomusic.ExperienceCardRequest) (*oomusic.ExperienceCardClaimResult, error) {
		claimCalls++
		return &oomusic.ExperienceCardClaimResult{}, nil
	}

	if _, err := pool.SelectedStatus(ctx); err != nil {
		t.Fatal(err)
	}
	if resolveCalls != experienceCardResolveLimit {
		t.Fatalf("resolved %d candidates, want %d", resolveCalls, experienceCardResolveLimit)
	}
	if claimCalls != 0 {
		t.Fatalf("claim should not run after resolution failures, calls=%d", claimCalls)
	}
}
