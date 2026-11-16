package account

import (
	"context"
	"errors"
	"io"
	"log"
	"path/filepath"
	"testing"
	"time"

	oomusic "github.com/rankgice/oo-music"
)

func openPoolTestStore(t *testing.T) (*Store, *Pool) {
	t.Helper()
	store, err := Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := store.Close(); err != nil {
			t.Errorf("close store: %v", err)
		}
	})
	pool := NewPool(store, log.New(io.Discard, "", 0))
	pool.newClient = func(Account) (*oomusic.Client, error) {
		return &oomusic.Client{}, nil
	}
	pool.experienceFeed = nil
	return store, pool
}

func TestPoolReusesClientAndInvalidatesOnlyChangedCredentials(t *testing.T) {
	store, pool := openPoolTestStore(t)
	ctx := context.Background()
	item, err := pool.Upsert(ctx, "10001", "key-1")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	if err := store.UpdateVipStatus(ctx, item.ID, VipLevelVIP, now.Add(time.Hour), now); err != nil {
		t.Fatal(err)
	}

	creationCount := 0
	pool.newClient = func(Account) (*oomusic.Client, error) {
		creationCount++
		return &oomusic.Client{}, nil
	}
	first, err := pool.Client(ctx)
	if err != nil {
		t.Fatal(err)
	}
	second, err := pool.Client(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if first != second || creationCount != 1 {
		t.Fatalf("client was not reused: equal=%v creations=%d", first == second, creationCount)
	}

	if _, err := pool.Upsert(ctx, "10001", "key-1"); err != nil {
		t.Fatal(err)
	}
	unchangedCredentials, err := pool.Client(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if unchangedCredentials != second || creationCount != 1 {
		t.Fatalf("unchanged credentials rebuilt client: equal=%v creations=%d", unchangedCredentials == second, creationCount)
	}

	if _, err := pool.Upsert(ctx, "10001", "key-2"); err != nil {
		t.Fatal(err)
	}
	third, err := pool.Client(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if third == second || creationCount != 2 {
		t.Fatalf("changed credentials did not rebuild client: equal=%v creations=%d", third == second, creationCount)
	}
	unchanged, err := pool.Client(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if unchanged != third || creationCount != 2 {
		t.Fatalf("new client was not cached: equal=%v creations=%d", unchanged == third, creationCount)
	}
}

func TestPoolExpiresVIPAndSwitchesToBestRemainingAccount(t *testing.T) {
	store, pool := openPoolTestStore(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	pool.now = func() time.Time { return now }

	expired, err := pool.Upsert(ctx, "10001", "key-1")
	if err != nil {
		t.Fatal(err)
	}
	active, err := pool.Upsert(ctx, "10002", "key-2")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateVipStatus(ctx, expired.ID, VipLevelSuper, now.Add(-time.Minute), now); err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateVipStatus(ctx, active.ID, VipLevelHuge, now.Add(24*time.Hour), now); err != nil {
		t.Fatal(err)
	}

	client, err := pool.Client(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if client == nil {
		t.Fatal("expected a cached client")
	}
	accounts, err := store.ListAccounts(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if accounts[0].VipLevel != VipLevelNone {
		t.Fatalf("expired account was not downgraded: %+v", accounts[0])
	}
	selected, err := store.SelectAccount(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if selected.ID != active.ID || selected.VipLevel != VipLevelHuge {
		t.Fatalf("selected wrong account: %+v", selected)
	}
}

func TestPoolClaimsVIPAcrossAccountsAndStopsAfterSuccess(t *testing.T) {
	store, pool := openPoolTestStore(t)
	ctx := context.Background()
	now := time.Date(2026, 10, 27, 3, 0, 0, 0, time.UTC)
	pool.now = func() time.Time { return now }

	first, err := pool.Upsert(ctx, "10001", "key-1")
	if err != nil {
		t.Fatal(err)
	}
	second, err := pool.Upsert(ctx, "10002", "key-2")
	if err != nil {
		t.Fatal(err)
	}
	third, err := pool.Upsert(ctx, "10003", "key-3")
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range []Account{first, second, third} {
		if err := store.UpdateVipStatus(ctx, item.ID, VipLevelNone, time.Time{}, now); err != nil {
			t.Fatal(err)
		}
	}
	if err := pool.SetExperienceCardURLs([]string{
		"https://y.qq.com/example?ADTAG=yy_gnyy_hytyk&cardid=card-1",
	}); err != nil {
		t.Fatal(err)
	}
	pool.experienceFeed = nil

	claimCalls := 0
	pool.claimExperienceCard = func(context.Context, *oomusic.Client, oomusic.ExperienceCardRequest) (*oomusic.ExperienceCardClaimResult, error) {
		claimCalls++
		if claimCalls == 1 {
			return nil, errors.New("first account rejected")
		}
		return &oomusic.ExperienceCardClaimResult{}, nil
	}
	pool.readVipStatus = func(context.Context, *oomusic.Client, string) (*oomusic.CallResult, error) {
		return &oomusic.CallResult{
			Code: 0,
			Data: []byte(`{"infoMap":{"10002":{"iVipFlag":1,"sOverDateTime":"2027-01-01 00:00:00"}}}`),
		}, nil
	}

	selected, err := pool.SelectedStatus(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if claimCalls != 2 {
		t.Fatalf("expected claims to stop after second account success, got %d calls", claimCalls)
	}
	if selected.ID != second.ID || selected.VipLevel != VipLevelVIP {
		t.Fatalf("did not switch to newly claimed VIP account: %+v", selected)
	}
	accounts, err := store.ListAccounts(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if accounts[1].VipLevel != VipLevelVIP {
		t.Fatalf("second account VIP status was not persisted: %+v", accounts[1])
	}
	if accounts[2].VipLevel != VipLevelNone {
		t.Fatalf("third account should not have been changed: %+v", accounts[2])
	}
}

func TestClientForMediaOnlyClaimsVIPWhenRequired(t *testing.T) {
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
	if err := pool.SetExperienceCardURLs([]string{
		"https://y.qq.com/example?ADTAG=yy_gnyy_hytyk&cardid=card-1",
	}); err != nil {
		t.Fatal(err)
	}
	pool.experienceFeed = nil

	claimCalls := 0
	claimedVIP := false
	pool.claimExperienceCard = func(context.Context, *oomusic.Client, oomusic.ExperienceCardRequest) (*oomusic.ExperienceCardClaimResult, error) {
		claimCalls++
		claimedVIP = true
		return &oomusic.ExperienceCardClaimResult{}, nil
	}
	pool.readVipStatus = func(context.Context, *oomusic.Client, string) (*oomusic.CallResult, error) {
		if claimedVIP {
			return &oomusic.CallResult{
				Code: 0,
				Data: []byte(`{"infoMap":{"10001":{"iVipFlag":1,"sOverDateTime":"2027-01-01 00:00:00"}}}`),
			}, nil
		}
		return &oomusic.CallResult{Code: 0, Data: []byte(`{"infoMap":{"10001":{}}}`)}, nil
	}

	if _, err := pool.ClientForMedia(ctx, MediaAccountAny); err != nil {
		t.Fatal(err)
	}
	if claimCalls != 0 {
		t.Fatalf("non-VIP media request unexpectedly claimed a card: %d", claimCalls)
	}
	if _, err := pool.ClientForMedia(ctx, MediaAccountVIP); err != nil {
		t.Fatal(err)
	}
	if claimCalls != 1 {
		t.Fatalf("VIP-required media request did not claim a card: %d", claimCalls)
	}
}

func TestPoolClaimFailureRespectsCooldown(t *testing.T) {
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
	if err := pool.SetExperienceCardURLs([]string{
		"https://y.qq.com/example?ADTAG=yy_gnyy_hytyk&cardid=card-1",
	}); err != nil {
		t.Fatal(err)
	}
	pool.experienceFeed = nil
	claimCalls := 0
	pool.claimExperienceCard = func(context.Context, *oomusic.Client, oomusic.ExperienceCardRequest) (*oomusic.ExperienceCardClaimResult, error) {
		claimCalls++
		return nil, oomusic.ErrExperienceCardExhausted
	}

	for index := 0; index < 2; index++ {
		if _, err := pool.SelectedStatus(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if claimCalls != 1 {
		t.Fatalf("claim cooldown did not prevent retry, calls=%d", claimCalls)
	}
}

func TestCheckAllLoginsMarksBusinessCode1000Invalid(t *testing.T) {
	store, pool := openPoolTestStore(t)
	ctx := context.Background()
	item, err := pool.Upsert(ctx, "10001", "key-1")
	if err != nil {
		t.Fatal(err)
	}
	pool.readVipStatus = func(context.Context, *oomusic.Client, string) (*oomusic.CallResult, error) {
		return &oomusic.CallResult{Code: 1000}, nil
	}
	report, err := pool.CheckAllLogins(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(report.Expired) != 1 || report.Expired[0].AccountID != item.ID || !report.Expired[0].Expired {
		t.Fatalf("unexpected report: %+v", report)
	}
	accounts, err := store.ListAccounts(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if accounts[0].LoginValid {
		t.Fatal("expired login was not marked invalid")
	}
	if accounts[0].AccessKey != "" {
		t.Fatalf("expired login did not clear access key: %q", accounts[0].AccessKey)
	}
	if _, err := store.SelectAccount(ctx); !errors.Is(err, ErrNoAccount) {
		t.Fatalf("invalid account remained selectable: %v", err)
	}
}

func TestPoolAuthorizeSourceValidatesAccountIDAndAccessKey(t *testing.T) {
	store, pool := openPoolTestStore(t)
	ctx := context.Background()
	item, err := pool.Upsert(ctx, "10001", "qm-key")
	if err != nil {
		t.Fatal(err)
	}
	authorized, err := pool.AuthorizeSource(ctx, AccountTypeQQ, item.AccountID, item.AccessKey)
	if err != nil {
		t.Fatal(err)
	}
	if authorized.ID != item.ID || authorized.AccountID != item.AccountID || authorized.Type != AccountTypeQQ {
		t.Fatalf("unexpected authorized account: %+v", authorized)
	}
	for _, testCase := range []struct {
		uin       string
		accessKey string
	}{
		{uin: "", accessKey: item.AccessKey},
		{uin: item.AccountID, accessKey: ""},
		{uin: item.AccountID, accessKey: "wrong-key"},
		{uin: "missing", accessKey: item.AccessKey},
	} {
		if _, err := pool.AuthorizeSource(ctx, AccountTypeQQ, testCase.uin, testCase.accessKey); !errors.Is(err, ErrInvalidClientAuthorization) {
			t.Fatalf("authorization should fail for %+v: %v", testCase, err)
		}
	}
	if err := store.UpdateLoginStatus(ctx, item.ID, false, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.AuthorizeSource(ctx, AccountTypeQQ, item.AccountID, item.AccessKey); !errors.Is(err, ErrInvalidClientAuthorization) {
		t.Fatalf("invalidated account should not authorize: %v", err)
	}
}

func TestPoolAuthorizeSourceSeparatesSameAccountIDAcrossPlatforms(t *testing.T) {
	store, pool := openPoolTestStore(t)
	ctx := context.Background()
	qqAccount, err := pool.Upsert(ctx, "12345678", "qq-key")
	if err != nil {
		t.Fatal(err)
	}
	neteaseAccount, err := store.UpsertNeteaseCredentials(ctx, "12345678", "MUSIC_U=netease-cookie", nil)
	if err != nil {
		t.Fatal(err)
	}

	authorized, err := pool.AuthorizeSource(ctx, AccountTypeNetease, neteaseAccount.AccountID, neteaseAccount.AccessKey)
	if err != nil {
		t.Fatal(err)
	}
	if authorized.Type != AccountTypeNetease || authorized.ID != neteaseAccount.ID || authorized.AccountID != neteaseAccount.AccountID {
		t.Fatalf("unexpected authorized NetEase account: %+v", authorized)
	}
	if qqAccount.AccessKey == "" || qqAccount.AccessKey == neteaseAccount.AccessKey {
		t.Fatal("platform accounts must keep independent access keys")
	}
	if _, err := pool.AuthorizeSource(ctx, AccountTypeQQ, neteaseAccount.AccountID, neteaseAccount.AccessKey); !errors.Is(err, ErrInvalidClientAuthorization) {
		t.Fatalf("legacy QQ authorization must not accept NetEase credentials: %v", err)
	}
}

func TestPoolRefreshProfilePreservesAccessKeyAndCachesClient(t *testing.T) {
	store, pool := openPoolTestStore(t)
	ctx := context.Background()
	item, err := pool.Upsert(ctx, "209192670", "qm-key")
	if err != nil {
		t.Fatal(err)
	}
	creationCount := 0
	pool.newClient = func(Account) (*oomusic.Client, error) {
		creationCount++
		return &oomusic.Client{}, nil
	}
	profileCalls := 0
	pool.readUserProfile = func(context.Context, *oomusic.Client, string) (*oomusic.CallResult, error) {
		profileCalls++
		return &oomusic.CallResult{
			Code: 0,
			Data: []byte(`{"map_userinfo":{"209192670":{"uin":209192670,"nick":"刷新昵称","headurl":"https://example.com/avatar.png"}}}`),
		}, nil
	}

	refreshed, err := pool.RefreshProfile(ctx, item.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	if refreshed.Nickname != "刷新昵称" || refreshed.AvatarURL != "https://example.com/avatar.png" {
		t.Fatalf("profile was not refreshed: %+v", refreshed)
	}
	if refreshed.AccessKey != item.AccessKey {
		t.Fatalf("access key rotated during profile refresh: before=%q after=%q", item.AccessKey, refreshed.AccessKey)
	}
	saved, err := store.AccountByID(ctx, item.ID)
	if err != nil {
		t.Fatal(err)
	}
	if saved.Nickname != "刷新昵称" || saved.AvatarURL != "https://example.com/avatar.png" || saved.AccessKey != item.AccessKey {
		t.Fatalf("refreshed profile was not persisted: %+v", saved)
	}

	if _, err := pool.RefreshProfile(ctx, item.AccountID); err != nil {
		t.Fatal(err)
	}
	if creationCount != 1 || profileCalls != 2 {
		t.Fatalf("profile refresh did not reuse client: creations=%d calls=%d", creationCount, profileCalls)
	}
}

func TestPoolRefreshProfileBusinessCode1000ExpiresLogin(t *testing.T) {
	store, pool := openPoolTestStore(t)
	ctx := context.Background()
	item, err := pool.Upsert(ctx, "209192670", "qm-key")
	if err != nil {
		t.Fatal(err)
	}
	pool.readUserProfile = func(context.Context, *oomusic.Client, string) (*oomusic.CallResult, error) {
		return &oomusic.CallResult{Code: 1000}, nil
	}

	_, err = pool.RefreshProfile(ctx, item.AccountID)
	if !errors.Is(err, ErrAccountLoginExpired) {
		t.Fatalf("expected expired login error, got %v", err)
	}
	saved, err := store.AccountByID(ctx, item.ID)
	if err != nil {
		t.Fatal(err)
	}
	if saved.LoginValid || saved.AccessKey != "" {
		t.Fatalf("expired login was not invalidated: %+v", saved)
	}
}

func TestPoolReadAccountPlaylistsDoesNotChangeActiveClient(t *testing.T) {
	store, pool := openPoolTestStore(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	pool.now = func() time.Time { return now }

	target, err := pool.Upsert(ctx, "10001", "key-1")
	if err != nil {
		t.Fatal(err)
	}
	active, err := pool.Upsert(ctx, "10002", "key-2")
	if err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateVipStatus(ctx, target.ID, VipLevelNone, time.Time{}, now); err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateVipStatus(ctx, active.ID, VipLevelHuge, now.Add(24*time.Hour), now); err != nil {
		t.Fatal(err)
	}

	clientBefore, err := pool.Client(ctx)
	if err != nil {
		t.Fatal(err)
	}
	requestedUIN := ""
	var requestedClient *oomusic.Client
	pool.SetUserPlaylistReader(func(_ context.Context, client *oomusic.Client, uin string) ([]oomusic.UserPlaylist, error) {
		requestedClient = client
		requestedUIN = uin
		return []oomusic.UserPlaylist{{ID: "101", Name: "测试歌单", SongCount: 1, SongIDs: []int64{42}}}, nil
	})

	playlists, err := pool.ReadAccountPlaylists(ctx, target.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	if requestedUIN != target.AccountID || requestedClient == nil || requestedClient == clientBefore || len(playlists) != 1 || playlists[0].ID != "101" {
		t.Fatalf("unexpected playlist result: uin=%s playlists=%+v", requestedUIN, playlists)
	}
	clientAfter, err := pool.Client(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if clientAfter != clientBefore {
		t.Fatal("reading a non-active account's playlists changed the active client")
	}
}

func TestPoolReadAccountPlaylistsBusinessCode1000ExpiresLogin(t *testing.T) {
	store, pool := openPoolTestStore(t)
	ctx := context.Background()
	item, err := pool.Upsert(ctx, "10001", "key-1")
	if err != nil {
		t.Fatal(err)
	}
	pool.SetUserPlaylistReader(func(context.Context, *oomusic.Client, string) ([]oomusic.UserPlaylist, error) {
		return nil, &oomusic.APIError{Code: 1000}
	})

	_, err = pool.ReadAccountPlaylists(ctx, item.AccountID)
	if !errors.Is(err, ErrAccountLoginExpired) {
		t.Fatalf("expected expired login error, got %v", err)
	}
	saved, err := store.AccountByID(ctx, item.ID)
	if err != nil {
		t.Fatal(err)
	}
	if saved.LoginValid || saved.AccessKey != "" {
		t.Fatalf("expired login was not invalidated: %+v", saved)
	}
}
