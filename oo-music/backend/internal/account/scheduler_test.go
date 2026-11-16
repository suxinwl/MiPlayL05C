package account

import (
	"context"
	"io"
	"log"
	"path/filepath"
	"testing"
	"time"

	oomusic "github.com/rankgice/oo-music"
)

func TestNextDailyRunUsesConfiguredTimezone(t *testing.T) {
	location, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 27, 2, 30, 0, 0, time.UTC)
	got := nextDailyRun(now, location, 11, 0)
	want := time.Date(2026, 10, 27, 11, 0, 0, 0, location)
	if !got.Equal(want) {
		t.Fatalf("unexpected next run: got %s want %s", got, want)
	}

	after := time.Date(2026, 10, 27, 3, 30, 0, 0, time.UTC)
	got = nextDailyRun(after, location, 11, 0)
	want = time.Date(2026, 10, 28, 11, 0, 0, 0, location)
	if !got.Equal(want) {
		t.Fatalf("unexpected next run after schedule: got %s want %s", got, want)
	}
}

func TestLoginCheckSchedulerNotifiesOnlyExplicitExpiry(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, err := store.UpsertCredentials(context.Background(), "10001", "key-1"); err != nil {
		t.Fatal(err)
	}

	pool := NewPool(store, log.New(io.Discard, "", 0))
	pool.experienceFeed = nil
	pool.newClient = func(Account) (*oomusic.Client, error) {
		return &oomusic.Client{}, nil
	}
	pool.readVipStatus = func(context.Context, *oomusic.Client, string) (*oomusic.CallResult, error) {
		return &oomusic.CallResult{Code: 1000}, nil
	}
	notified := 0
	scheduler := &LoginCheckScheduler{
		pool:    pool,
		logger:  log.New(io.Discard, "", 0),
		notify:  func(context.Context, LoginCheckReport) error { notified++; return nil },
		timeout: time.Second,
		now:     time.Now,
	}
	scheduler.RunOnce(context.Background())
	if notified != 1 {
		t.Fatalf("expected one expiry notification, got %d", notified)
	}
}

func TestLoginCheckSchedulerDoesNotNotifyForNetworkError(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, err := store.UpsertCredentials(context.Background(), "10001", "key-1"); err != nil {
		t.Fatal(err)
	}

	pool := NewPool(store, log.New(io.Discard, "", 0))
	pool.experienceFeed = nil
	pool.newClient = func(Account) (*oomusic.Client, error) {
		return &oomusic.Client{}, nil
	}
	pool.readVipStatus = func(context.Context, *oomusic.Client, string) (*oomusic.CallResult, error) {
		return nil, context.DeadlineExceeded
	}
	notified := 0
	scheduler := &LoginCheckScheduler{
		pool:    pool,
		logger:  log.New(io.Discard, "", 0),
		notify:  func(context.Context, LoginCheckReport) error { notified++; return nil },
		timeout: time.Second,
		now:     time.Now,
	}
	scheduler.RunOnce(context.Background())
	if notified != 0 {
		t.Fatalf("network error must not be reported as expired login, got %d notifications", notified)
	}
}

func TestLoginCheckSchedulerUsesIndependentMembershipTimeout(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, err := store.UpsertCredentials(context.Background(), "10001", "key-1"); err != nil {
		t.Fatal(err)
	}

	pool := NewPool(store, log.New(io.Discard, "", 0))
	pool.experienceFeed = nil
	pool.newClient = func(Account) (*oomusic.Client, error) {
		return &oomusic.Client{}, nil
	}
	vipCalls := 0
	pool.readVipStatus = func(ctx context.Context, _ *oomusic.Client, _ string) (*oomusic.CallResult, error) {
		vipCalls++
		if vipCalls == 1 {
			<-ctx.Done()
			return nil, ctx.Err()
		}
		if err := ctx.Err(); err != nil {
			t.Errorf("membership maintenance inherited canceled login context: %v", err)
		}
		return &oomusic.CallResult{
			Code: 0,
			Data: []byte(`{"infoMap":{"10001":{"iVipFlag":1,"sOverDateTime":"2027-01-01 00:00:00"}}}`),
		}, nil
	}

	scheduler := &LoginCheckScheduler{
		pool:              pool,
		logger:            log.New(io.Discard, "", 0),
		timeout:           10 * time.Millisecond,
		membershipTimeout: time.Second,
		now:               time.Now,
	}
	scheduler.RunOnce(context.Background())
	if vipCalls < 2 {
		t.Fatalf("membership maintenance did not run with a fresh context: vip_calls=%d", vipCalls)
	}
}

func TestNewLoginCheckSchedulerRejectsInvalidConfiguration(t *testing.T) {
	if _, err := NewLoginCheckScheduler(nil, nil, "", "", nil); err == nil {
		t.Fatal("expected nil pool error")
	}
	scheduler, err := NewLoginCheckScheduler(&Pool{}, nil, "11:00", "Asia/Shanghai", nil)
	if err != nil {
		t.Fatal(err)
	}
	if scheduler.hour != 11 || scheduler.minute != 0 || scheduler.location.String() != "Asia/Shanghai" {
		t.Fatalf("unexpected scheduler: %+v", scheduler)
	}
	if scheduler.timeout != defaultLoginCheckTimeout || scheduler.membershipTimeout != defaultMembershipTimeout {
		t.Fatalf("unexpected scheduler timeouts: login=%s membership=%s", scheduler.timeout, scheduler.membershipTimeout)
	}
	if _, err := NewLoginCheckScheduler(&Pool{}, nil, "25:00", "Asia/Shanghai", nil); err == nil {
		t.Fatal("expected invalid clock error")
	}
	if _, err := NewLoginCheckScheduler(&Pool{}, nil, "11:00", "Not/AZone", nil); err == nil {
		t.Fatal("expected invalid timezone error")
	}
}
