package account

import (
	"context"
	"errors"
	"io"
	"log"
	"path/filepath"
	"testing"
	"time"

	"github.com/rankgice/oo-music/internal/netease"
)

type fakeNeteaseAccountClient struct {
	checkResult   netease.AccountState
	checkErr      error
	refreshResult netease.AccountState
	refreshErr    error
	vipResult     netease.VIPStatus
	vipErr        error
	checkCalls    int
	refreshCalls  int
	vipCalls      int
}

func (f *fakeNeteaseAccountClient) Check(context.Context, string, string) (netease.AccountState, error) {
	f.checkCalls++
	return f.checkResult, f.checkErr
}

func (f *fakeNeteaseAccountClient) Refresh(context.Context, string, string) (netease.AccountState, error) {
	f.refreshCalls++
	return f.refreshResult, f.refreshErr
}

func (f *fakeNeteaseAccountClient) GetVIPStatus(context.Context, string, string) (netease.VIPStatus, error) {
	f.vipCalls++
	return f.vipResult, f.vipErr
}

func (f *fakeNeteaseAccountClient) GetInvitationDetail(context.Context, string, string, string, string) (netease.InvitationDetail, error) {
	return netease.InvitationDetail{}, nil
}

func (f *fakeNeteaseAccountClient) AcceptInvitation(context.Context, string, string, string, string) (netease.InvitationAcceptResult, error) {
	return netease.InvitationAcceptResult{Code: 200}, nil
}

func newNeteasePoolTest(t *testing.T) (*Pool, *Store, *fakeNeteaseAccountClient) {
	t.Helper()
	store, err := Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	pool := NewPool(store, log.New(io.Discard, "", 0))
	fake := &fakeNeteaseAccountClient{}
	pool.netease = fake
	return pool, store, fake
}

func TestPoolRefreshesNeteaseSessionBeforeExpiry(t *testing.T) {
	pool, store, fake := newNeteasePoolTest(t)
	ctx := context.Background()
	now := time.Now().UTC()
	item, err := store.UpsertNeteaseCredentials(ctx, "12345678", "MUSIC_U=old", timePtr(now.Add(-time.Minute)))
	if err != nil {
		t.Fatal(err)
	}
	newExpiry := now.Add(48 * time.Hour).Truncate(time.Second)
	fake.refreshResult = netease.AccountState{
		UID:       12345678,
		Nickname:  "refreshed",
		AvatarURL: "https://example.com/n.png",
		Cookie:    "MUSIC_U=new; __csrf=next",
		ExpiresAt: &newExpiry,
	}
	fake.vipResult = netease.VIPStatus{Active: true, Level: 1, ExpiresAt: &newExpiry}

	public, err := pool.RefreshBoundAccount(ctx, item.ID)
	if err != nil {
		t.Fatal(err)
	}
	if fake.refreshCalls != 1 {
		t.Fatalf("expected one refresh call, got %d", fake.refreshCalls)
	}
	if public.AccountType != AccountTypeNetease || !public.LoginValid || public.LoginExpiresAt == nil {
		t.Fatalf("unexpected refreshed account: %+v", public)
	}
	saved, err := store.AccountByID(ctx, item.ID)
	if err != nil {
		t.Fatal(err)
	}
	if saved.Credential != "MUSIC_U=new; __csrf=next" || saved.Nickname != "refreshed" {
		t.Fatalf("refreshed session was not persisted: %+v", saved)
	}
	if saved.VipLevel != VipLevelVIP || saved.VipExpiresAt == nil || !saved.VipExpiresAt.Equal(newExpiry) {
		t.Fatalf("NetEase VIP status was not persisted: %+v", saved)
	}
}

func TestPoolMarksExpiredNeteaseAndSkipsItOnNextCheck(t *testing.T) {
	pool, store, fake := newNeteasePoolTest(t)
	ctx := context.Background()
	now := time.Now().UTC()
	item, err := store.UpsertNeteaseCredentials(ctx, "12345678", "MUSIC_U=expired", timePtr(now.Add(-time.Minute)))
	if err != nil {
		t.Fatal(err)
	}
	fake.refreshErr = netease.ErrUnauthorized

	if _, err := pool.RefreshBoundAccount(ctx, item.ID); !errors.Is(err, ErrAccountLoginExpired) {
		t.Fatalf("expected expired error, got %v", err)
	}
	if fake.refreshCalls != 1 {
		t.Fatalf("expected one refresh attempt, got %d", fake.refreshCalls)
	}
	expired, err := store.AccountByID(ctx, item.ID)
	if err != nil {
		t.Fatal(err)
	}
	if expired.LoginValid {
		t.Fatalf("NetEase account should be invalid: %+v", expired)
	}

	report, err := pool.CheckAllLogins(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if fake.refreshCalls != 1 || fake.checkCalls != 0 {
		t.Fatalf("expired NetEase account was not skipped: refresh=%d check=%d", fake.refreshCalls, fake.checkCalls)
	}
	if len(report.Expired) != 0 {
		t.Fatalf("skipped account should not be reported expired again: %+v", report.Expired)
	}
	if len(report.Accounts) != 1 || report.Accounts[0].Error == "" {
		t.Fatalf("expected skipped account marker: %+v", report.Accounts)
	}
}

func TestCheckAllLoginsRefreshesNeteaseWhenAuthorizationIsNearExpiry(t *testing.T) {
	pool, store, fake := newNeteasePoolTest(t)
	ctx := context.Background()
	now := time.Now().UTC()
	item, err := store.UpsertNeteaseCredentials(ctx, "12345678", "MUSIC_U=old", timePtr(now.Add(time.Hour)))
	if err != nil {
		t.Fatal(err)
	}
	newExpiry := now.Add(24 * time.Hour).Truncate(time.Second)
	fake.refreshResult = netease.AccountState{
		UID:       12345678,
		Cookie:    "MUSIC_U=renewed",
		ExpiresAt: &newExpiry,
	}
	report, err := pool.CheckAllLogins(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if fake.refreshCalls != 1 || fake.checkCalls != 0 {
		t.Fatalf("near-expiry account was not refreshed: refresh=%d check=%d", fake.refreshCalls, fake.checkCalls)
	}
	if len(report.Accounts) != 1 || !report.Accounts[0].Valid || report.Accounts[0].AccountType != AccountTypeNetease {
		t.Fatalf("unexpected login check report: %+v", report)
	}
	refreshed, err := store.AccountByID(ctx, item.ID)
	if err != nil {
		t.Fatal(err)
	}
	if refreshed.Credential != "MUSIC_U=renewed" || refreshed.LoginExpiresAt == nil {
		t.Fatalf("scheduled refresh was not persisted: %+v", refreshed)
	}
}

func TestEnsureNeteaseMembershipSkipsClaimWhenMembershipAlreadyExists(t *testing.T) {
	pool, store, fake := newNeteasePoolTest(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	pool.now = func() time.Time { return now }
	item, err := store.UpsertNeteaseCredentials(ctx, "12345678", "MUSIC_U=account", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateVipStatus(ctx, item.ID, VipLevelVIP, now.Add(24*time.Hour), now); err != nil {
		t.Fatal(err)
	}
	feedCalls := 0
	claimCalls := 0
	pool.neteaseVIPFeed = func(context.Context) ([]neteaseVIPInvitation, error) {
		feedCalls++
		return []neteaseVIPInvitation{{ID: "invite"}}, nil
	}
	pool.claimNeteaseVIP = func(context.Context, Account, neteaseVIPInvitation) (netease.InvitationAcceptResult, error) {
		claimCalls++
		return netease.InvitationAcceptResult{}, nil
	}
	_ = fake

	if err := pool.EnsureMemberships(ctx); err != nil {
		t.Fatal(err)
	}
	if feedCalls != 0 || claimCalls != 0 {
		t.Fatalf("active membership should skip claiming: feed=%d claim=%d", feedCalls, claimCalls)
	}
}

func TestEnsureNeteaseMembershipClaimsOnlyUntilFirstSuccess(t *testing.T) {
	pool, store, fake := newNeteasePoolTest(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	pool.now = func() time.Time { return now }
	first, err := store.UpsertNeteaseCredentials(ctx, "12345678", "MUSIC_U=first", nil)
	if err != nil {
		t.Fatal(err)
	}
	second, err := store.UpsertNeteaseCredentials(ctx, "87654321", "MUSIC_U=second", nil)
	if err != nil {
		t.Fatal(err)
	}
	pool.neteaseVIPFeed = func(context.Context) ([]neteaseVIPInvitation, error) {
		return []neteaseVIPInvitation{{ID: "invite-1"}, {ID: "invite-2"}}, nil
	}
	claimCalls := 0
	pool.claimNeteaseVIP = func(_ context.Context, item Account, invitation neteaseVIPInvitation) (netease.InvitationAcceptResult, error) {
		claimCalls++
		if item.ID != first.ID || invitation.ID != "invite-1" {
			t.Fatalf("unexpected claim target: item=%d invite=%s", item.ID, invitation.ID)
		}
		fake.vipResult = netease.VIPStatus{Active: true, Level: 1, ExpiresAt: timePtr(now.Add(7 * 24 * time.Hour))}
		return netease.InvitationAcceptResult{Code: 200}, nil
	}

	if err := pool.EnsureMemberships(ctx); err != nil {
		t.Fatal(err)
	}
	if claimCalls != 1 {
		t.Fatalf("expected claim to stop after first success, got %d calls", claimCalls)
	}
	firstSaved, err := store.AccountByID(ctx, first.ID)
	if err != nil {
		t.Fatal(err)
	}
	secondSaved, err := store.AccountByID(ctx, second.ID)
	if err != nil {
		t.Fatal(err)
	}
	if firstSaved.VipLevel != VipLevelVIP || secondSaved.VipLevel != VipLevelNone {
		t.Fatalf("unexpected membership state after claim: first=%+v second=%+v", firstSaved, secondSaved)
	}
}

func TestSelectedCredentialForMediaClaimsNeteaseVIPOnlyWhenRequired(t *testing.T) {
	pool, store, fake := newNeteasePoolTest(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	pool.now = func() time.Time { return now }
	item, err := store.UpsertNeteaseCredentials(ctx, "12345678", "MUSIC_U=account", nil)
	if err != nil {
		t.Fatal(err)
	}
	pool.neteaseVIPFeed = func(context.Context) ([]neteaseVIPInvitation, error) {
		return []neteaseVIPInvitation{{ID: "invite"}}, nil
	}
	claimCalls := 0
	pool.claimNeteaseVIP = func(context.Context, Account, neteaseVIPInvitation) (netease.InvitationAcceptResult, error) {
		claimCalls++
		fake.vipResult = netease.VIPStatus{Active: true, Level: VipLevelVIP, ExpiresAt: timePtr(now.Add(7 * 24 * time.Hour))}
		return netease.InvitationAcceptResult{Code: 200}, nil
	}

	selected, ok, err := pool.SelectedCredentialForMedia(ctx, AccountTypeNetease, MediaAccountAny)
	if err != nil || !ok || selected.ID != item.ID {
		t.Fatalf("unexpected non-VIP media selection: item=%+v ok=%t err=%v", selected, ok, err)
	}
	if claimCalls != 0 {
		t.Fatalf("ordinary media request unexpectedly claimed VIP: %d", claimCalls)
	}

	selected, ok, err = pool.SelectedCredentialForMedia(ctx, AccountTypeNetease, MediaAccountVIP)
	if err != nil || !ok || selected.ID != item.ID || selected.VipLevel == VipLevelNone {
		t.Fatalf("VIP media selection did not use claimed account: item=%+v ok=%t err=%v", selected, ok, err)
	}
	if claimCalls != 1 {
		t.Fatalf("VIP media request did not claim once: %d", claimCalls)
	}
}

func TestEnsureNeteaseMembershipCooldownPreventsRetry(t *testing.T) {
	pool, store, fake := newNeteasePoolTest(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	pool.now = func() time.Time { return now }
	if _, err := store.UpsertNeteaseCredentials(ctx, "12345678", "MUSIC_U=account", nil); err != nil {
		t.Fatal(err)
	}
	pool.neteaseVIPFeed = func(context.Context) ([]neteaseVIPInvitation, error) {
		return []neteaseVIPInvitation{{ID: "invite"}}, nil
	}
	claimCalls := 0
	pool.claimNeteaseVIP = func(context.Context, Account, neteaseVIPInvitation) (netease.InvitationAcceptResult, error) {
		claimCalls++
		return netease.InvitationAcceptResult{}, netease.ErrInvitationRisk
	}
	fake.vipResult = netease.VIPStatus{}

	if err := pool.EnsureMemberships(ctx); err == nil {
		t.Fatal("expected risk error")
	}
	if err := pool.EnsureMemberships(ctx); err != nil {
		t.Fatalf("cooldown run should not fail on a new claim: %v", err)
	}
	if claimCalls != 1 {
		t.Fatalf("cooldown did not prevent retry, calls=%d", claimCalls)
	}
}
