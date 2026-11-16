package account

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParseVipStatusSelectsHighestActiveTier(t *testing.T) {
	now := time.Date(2026, 10, 26, 10, 0, 0, 0, time.UTC)
	data := []byte(`{
		"infoMap": {
			"10001": {
				"iVipFlag": 1,
				"iNewVip": 1,
				"iSuperVip": 1,
				"iNewSuperVip": 1,
				"HugeVip": 1,
				"LMFlag": 1,
				"superEndTime": "2026-11-10 19:07:32",
				"HugeVipEnd": "2026-11-09 19:27:31",
				"sOverDateTime": "2026-11-10 19:07:32",
				"eightEndTime": "2026-11-10 19:07:33"
			}
		}
	}`)
	status, err := ParseVipStatus(data, "10001", now)
	if err != nil {
		t.Fatal(err)
	}
	if status.Level != VipLevelSuper {
		t.Fatalf("unexpected level: %d", status.Level)
	}
	if status.ExpiresAt == nil {
		t.Fatal("expected expiry")
	}
	want := time.Date(2026, 11, 10, 19, 7, 32, 0, qqMusicLocation).UTC()
	if !status.ExpiresAt.Equal(want) {
		t.Fatalf("unexpected expiry: %s", status.ExpiresAt)
	}
}

func TestParseVipStatusFallsBackWhenHigherTierExpired(t *testing.T) {
	now := time.Date(2026, 10, 26, 10, 0, 0, 0, time.UTC)
	data := []byte(`{
		"infoMap": {
			"10001": {
				"iVipFlag": 1,
				"iSuperVip": 1,
				"HugeVip": 1,
				"superEndTime": "2026-10-01 00:00:00",
				"sOverDateTime": "2026-10-01 00:00:00",
				"HugeVipEnd": "2026-12-01 00:00:00"
			}
		}
	}`)
	status, err := ParseVipStatus(data, "10001", now)
	if err != nil {
		t.Fatal(err)
	}
	if status.Level != VipLevelHuge {
		t.Fatalf("unexpected level: %d", status.Level)
	}
	want := time.Date(2026, 12, 1, 0, 0, 0, 0, qqMusicLocation).UTC()
	if status.ExpiresAt == nil || !status.ExpiresAt.Equal(want) {
		t.Fatalf("unexpected expiry: %v", status.ExpiresAt)
	}
}

func TestStoreSelectsHighestLevelThenLatestExpiry(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	ctx := context.Background()
	first, err := store.UpsertCredentials(ctx, "10001", "key-1")
	if err != nil {
		t.Fatal(err)
	}
	second, err := store.UpsertCredentials(ctx, "10002", "key-2")
	if err != nil {
		t.Fatal(err)
	}
	third, err := store.UpsertCredentials(ctx, "10003", "key-3")
	if err != nil {
		t.Fatal(err)
	}
	checkedAt := time.Now().UTC()
	if err := store.UpdateVipStatus(ctx, first.ID, VipLevelHuge, checkedAt.Add(48*time.Hour), checkedAt); err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateVipStatus(ctx, second.ID, VipLevelSuper, checkedAt.Add(24*time.Hour), checkedAt); err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateVipStatus(ctx, third.ID, VipLevelSuper, checkedAt.Add(72*time.Hour), checkedAt); err != nil {
		t.Fatal(err)
	}

	selected, err := store.SelectAccount(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if selected.AccountID != "10003" {
		t.Fatalf("expected latest super VIP account 10003, got %s", selected.AccountID)
	}
}

func TestStoreUpsertDoesNotDuplicateAccount(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	ctx := context.Background()
	if _, err := store.UpsertCredentials(ctx, "10001", "old-key"); err != nil {
		t.Fatal(err)
	}
	updated, err := store.UpsertCredentials(ctx, "10001", "new-key")
	if err != nil {
		t.Fatal(err)
	}
	accounts, err := store.ListAccounts(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(accounts) != 1 {
		t.Fatalf("unexpected account count: %d", len(accounts))
	}
	if accounts[0].Credential != "new-key" || accounts[0].ID != updated.ID {
		t.Fatalf("credentials were not updated: %+v", accounts[0])
	}
	if accounts[0].AccessKey == "" || accounts[0].AccessKey != updated.AccessKey {
		t.Fatalf("access key was not preserved: before=%q after=%q", accounts[0].AccessKey, updated.AccessKey)
	}
}

func TestStoreUpsertResetsQQVipWhenCredentialChanges(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	ctx := context.Background()
	item, err := store.UpsertCredentials(ctx, "10001", "old-key")
	if err != nil {
		t.Fatal(err)
	}
	checkedAt := time.Now().UTC().Truncate(time.Second)
	expiresAt := checkedAt.Add(48 * time.Hour)
	if err := store.UpdateVipStatus(ctx, item.ID, VipLevelSuper, expiresAt, checkedAt); err != nil {
		t.Fatal(err)
	}

	preserved, err := store.UpsertCredentials(ctx, "10001", "old-key")
	if err != nil {
		t.Fatal(err)
	}
	if preserved.VipLevel != VipLevelSuper || preserved.VipExpiresAt == nil {
		t.Fatalf("unchanged credential should preserve VIP state: %+v", preserved)
	}

	reauthorized, err := store.UpsertCredentials(ctx, "10001", "new-key")
	if err != nil {
		t.Fatal(err)
	}
	if reauthorized.VipLevel != VipLevelNone || reauthorized.VipExpiresAt != nil || reauthorized.VipCheckedAt != nil {
		t.Fatalf("credential change did not clear stale VIP state: %+v", reauthorized)
	}
}

func TestStoreUpdateQQCredentialClearsVipState(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	ctx := context.Background()
	item, err := store.UpsertCredentials(ctx, "10001", "old-key")
	if err != nil {
		t.Fatal(err)
	}
	checkedAt := time.Now().UTC().Truncate(time.Second)
	if err := store.UpdateVipStatus(ctx, item.ID, VipLevelSuper, checkedAt.Add(48*time.Hour), checkedAt); err != nil {
		t.Fatal(err)
	}
	updated, err := store.UpdateCredentialsByID(ctx, item.ID, "new-key")
	if err != nil {
		t.Fatal(err)
	}
	if updated.VipLevel != VipLevelNone || updated.VipExpiresAt != nil || updated.VipCheckedAt != nil {
		t.Fatalf("manual credential update did not clear stale VIP state: %+v", updated)
	}
}

func TestStoreGeneratesAndPreservesAccessKeyUntilLoginExpires(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	ctx := context.Background()
	first, err := store.UpsertCredentials(ctx, "10001", "key-1")
	if err != nil {
		t.Fatal(err)
	}
	if first.AccessKey == "" {
		t.Fatal("expected a generated access key")
	}
	second, err := store.UpsertCredentials(ctx, "10001", "key-2")
	if err != nil {
		t.Fatal(err)
	}
	if second.AccessKey != first.AccessKey {
		t.Fatalf("access key rotated unexpectedly: before=%q after=%q", first.AccessKey, second.AccessKey)
	}
	if err := store.UpdateLoginStatus(ctx, first.ID, true, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	valid, err := store.AccountByID(ctx, first.ID)
	if err != nil {
		t.Fatal(err)
	}
	if valid.AccessKey != first.AccessKey {
		t.Fatalf("valid login check cleared access key: %q", valid.AccessKey)
	}
	if err := store.UpdateLoginStatus(ctx, first.ID, false, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	expired, err := store.AccountByID(ctx, first.ID)
	if err != nil {
		t.Fatal(err)
	}
	if expired.AccessKey != "" {
		t.Fatalf("expired login did not clear access key: %q", expired.AccessKey)
	}
	renewed, err := store.UpsertCredentials(ctx, "10001", "key-3")
	if err != nil {
		t.Fatal(err)
	}
	if renewed.AccessKey == "" || renewed.AccessKey == first.AccessKey {
		t.Fatalf("renewed login should generate a new access key: old=%q new=%q", first.AccessKey, renewed.AccessKey)
	}
}

func TestStoreFileIsPrivateAndPublicViewMasksUIN(t *testing.T) {
	path := filepath.Join(t.TempDir(), "accounts.db")
	store, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	assertPrivateDatabasePermissions(t, path)

	item, err := store.UpsertCredentials(context.Background(), "209192670", "secret-key")
	if err != nil {
		t.Fatal(err)
	}
	public := item.Public()
	if public.UINMasked == item.AccountID || strings.Contains(public.UINMasked, "secret-key") {
		t.Fatalf("sensitive account data leaked: %+v", public)
	}
	encoded, err := json.Marshal(public)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "secret-key") || strings.Contains(string(encoded), item.AccountID) {
		t.Fatalf("public JSON contains credentials: %s", encoded)
	}
}

func TestStoreExpiresVIPAndExcludesInvalidLogin(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	ctx := context.Background()
	first, err := store.UpsertCredentials(ctx, "10001", "key-1")
	if err != nil {
		t.Fatal(err)
	}
	second, err := store.UpsertCredentials(ctx, "10002", "key-2")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	if err := store.UpdateVipStatus(ctx, first.ID, VipLevelSuper, now.Add(-time.Minute), now); err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateVipStatus(ctx, second.ID, VipLevelVIP, now.Add(time.Hour), now); err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateLoginStatus(ctx, first.ID, false, now); err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateLoginStatus(ctx, second.ID, false, now); err != nil {
		t.Fatal(err)
	}
	if err := store.ExpireVIPAccounts(ctx, now); err != nil {
		t.Fatal(err)
	}
	accounts, err := store.ListAccounts(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if accounts[0].VipLevel != VipLevelNone {
		t.Fatalf("expired VIP was not downgraded: %+v", accounts[0])
	}
	if _, err := store.SelectAccount(ctx); !errors.Is(err, ErrNoAccount) {
		t.Fatalf("invalid-login account remained selectable: %v", err)
	}
	updated, err := store.UpsertCredentials(ctx, "10002", "key-2-new")
	if err != nil {
		t.Fatal(err)
	}
	if !updated.LoginValid {
		t.Fatal("updated credentials should reset login validity")
	}
}

func TestOpenClearsLegacyAccountDatabase(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`
		CREATE TABLE accounts (
			id             INTEGER PRIMARY KEY AUTOINCREMENT,
			uin            TEXT NOT NULL UNIQUE,
			qm_keyst       TEXT NOT NULL,
			vip_level      INTEGER NOT NULL DEFAULT 0,
			vip_expires_at INTEGER,
			vip_checked_at INTEGER,
			created_at     INTEGER NOT NULL,
			updated_at     INTEGER NOT NULL
		);
		INSERT INTO accounts (uin, qm_keyst, vip_level, created_at, updated_at)
		VALUES ('10001', 'legacy-key', 0, 1, 1);
	`)
	if err != nil {
		_ = db.Close()
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	store, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	accounts, err := store.ListAccounts(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(accounts) != 0 {
		t.Fatalf("legacy accounts were retained: %+v", accounts)
	}
	if version := schemaVersion(t, store.db); version != accountSchemaVersion {
		t.Fatalf("legacy schema user_version=%d want=%d", version, accountSchemaVersion)
	}
	columns := accountTableColumns(t, store.db)
	for _, added := range []string{"account_type", "account_id", "credential", "login_valid", "access_key", "nickname", "avatar_url"} {
		if _, ok := columns[added]; !ok {
			t.Fatalf("legacy partial schema was not completed with %q: %v", added, columns)
		}
	}
}

func TestStoreUpsertsNeteaseAccountAndKeepsQQSelectionSeparate(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	ctx := context.Background()
	expiresAt := time.Now().UTC().Add(72 * time.Hour).Truncate(time.Second)
	item, err := store.UpsertNeteaseCredentials(ctx, "12345678", "MUSIC_U=secret-cookie; __csrf=csrf", &expiresAt)
	if err != nil {
		t.Fatal(err)
	}
	if item.Type != AccountTypeNetease || item.AccountID != "12345678" {
		t.Fatalf("unexpected NetEase account: %+v", item)
	}
	if item.LoginExpiresAt == nil || !item.LoginExpiresAt.Equal(expiresAt) {
		t.Fatalf("NetEase login expiry was not stored: %+v", item.LoginExpiresAt)
	}
	public := item.Public()
	if public.AccountType != AccountTypeNetease || public.AccountTypeName != "网易云音乐" {
		t.Fatalf("unexpected public account type: %+v", public)
	}
	if public.UINMasked == "12345678" || strings.Contains(public.UINMasked, "netease:") {
		t.Fatalf("NetEase account ID was not masked correctly: %q", public.UINMasked)
	}
	encoded, err := json.Marshal(public)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "secret-cookie") || strings.Contains(string(encoded), "csrf") {
		t.Fatalf("public NetEase account leaked cookie: %s", encoded)
	}
	if _, err := store.SelectAccount(ctx); !errors.Is(err, ErrNoAccount) {
		t.Fatalf("NetEase account must not be selected for QQ Music playback: %v", err)
	}
}

func TestStoreUpdatesNeteaseSessionAndInvalidation(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	ctx := context.Background()
	item, err := store.UpsertNeteaseCredentials(ctx, "12345678", "MUSIC_U=old", nil)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	expiresAt := now.Add(24 * time.Hour)
	if err := store.UpdateNeteaseSession(ctx, item.ID, "MUSIC_U=new; __csrf=next", true, expiresAt, now); err != nil {
		t.Fatal(err)
	}
	updated, err := store.AccountByID(ctx, item.ID)
	if err != nil {
		t.Fatal(err)
	}
	if updated.Credential != "MUSIC_U=new; __csrf=next" || !updated.LoginValid || updated.LoginExpiresAt == nil {
		t.Fatalf("NetEase session was not updated: %+v", updated)
	}
	if err := store.UpdateNeteaseSession(ctx, item.ID, updated.Credential, false, time.Time{}, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	expired, err := store.AccountByID(ctx, item.ID)
	if err != nil {
		t.Fatal(err)
	}
	if expired.LoginValid || expired.AccessKey != "" || expired.LoginExpiresAt != nil {
		t.Fatalf("NetEase expiration was not persisted: %+v", expired)
	}
}

func TestStoreUpdateProfilePreservesExistingValuesOnEmptyInput(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "profiles.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()
	item, err := store.UpsertCredentials(ctx, "209192670", "qm-key")
	if err != nil {
		t.Fatal(err)
	}

	if err := store.UpdateProfile(ctx, item.ID, " 新昵称 ", " https://example.com/avatar.png "); err != nil {
		t.Fatal(err)
	}
	updated, err := store.AccountByID(ctx, item.ID)
	if err != nil {
		t.Fatal(err)
	}
	if updated.Nickname != "新昵称" || updated.AvatarURL != "https://example.com/avatar.png" {
		t.Fatalf("profile was not saved: %+v", updated)
	}

	if err := store.UpdateProfile(ctx, item.ID, "", ""); err != nil {
		t.Fatal(err)
	}
	preserved, err := store.AccountByID(ctx, item.ID)
	if err != nil {
		t.Fatal(err)
	}
	if preserved.Nickname != updated.Nickname || preserved.AvatarURL != updated.AvatarURL {
		t.Fatalf("empty profile overwrote existing values: %+v", preserved)
	}
}
