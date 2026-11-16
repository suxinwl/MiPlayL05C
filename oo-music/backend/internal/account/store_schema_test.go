package account

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
)

func TestFreshDatabaseCreatesCurrentSchema(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "fresh.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	assertCurrentAccountSchema(t, store.db)
}

func TestOpeningLegacyDatabaseClearsAccounts(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.db")
	createDatabase(t, path, `
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
		INSERT INTO accounts (uin, qm_keyst, created_at, updated_at)
		VALUES ('10001', 'legacy-key', 1, 2);
		CREATE TABLE admin_users (username TEXT PRIMARY KEY);
		INSERT INTO admin_users (username) VALUES ('operator');
		CREATE TABLE system_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
		INSERT INTO system_settings (key, value) VALUES ('public_api_auth_required', 'false');
	`)

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
	var username string
	if err := store.db.QueryRow("SELECT username FROM admin_users").Scan(&username); err != nil || username != "operator" {
		t.Fatalf("administrator data was changed: username=%q err=%v", username, err)
	}
	var setting string
	if err := store.db.QueryRow("SELECT value FROM system_settings WHERE key = 'public_api_auth_required'").Scan(&setting); err != nil || setting != "false" {
		t.Fatalf("system settings were changed: value=%q err=%v", setting, err)
	}
	assertCurrentAccountSchema(t, store.db)
}

func TestOpeningPartialSchemaClearsAccounts(t *testing.T) {
	path := filepath.Join(t.TempDir(), "partial.db")
	createDatabase(t, path, `
		PRAGMA user_version = 1;
		CREATE TABLE accounts (
			id         INTEGER PRIMARY KEY AUTOINCREMENT,
			account_id TEXT NOT NULL,
			credential TEXT NOT NULL,
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL
		);
		INSERT INTO accounts (account_id, credential, created_at, updated_at)
		VALUES ('10001', 'partial-key', 1, 1);
	`)

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
		t.Fatalf("partial-schema accounts were retained: %+v", accounts)
	}
	assertCurrentAccountSchema(t, store.db)
}

func TestReopeningCurrentSchemaPreservesAccounts(t *testing.T) {
	path := filepath.Join(t.TempDir(), "current.db")
	first, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	created, err := first.UpsertCredentials(context.Background(), "10001", "current-key")
	if err != nil {
		_ = first.Close()
		t.Fatal(err)
	}
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}

	second, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()

	accounts, err := second.ListAccounts(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(accounts) != 1 {
		t.Fatalf("account count=%d want=1: %+v", len(accounts), accounts)
	}
	if accounts[0].AccountID != created.AccountID || accounts[0].Credential != created.Credential || accounts[0].AccessKey != created.AccessKey {
		t.Fatalf("reopen changed current account: before=%+v after=%+v", created, accounts[0])
	}
	assertCurrentAccountSchema(t, second.db)
}

func TestAccountIdentityIsUniquePerPlatform(t *testing.T) {
	store, err := Open(filepath.Join(t.TempDir(), "platform-identity.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	ctx := context.Background()
	if _, err := store.UpsertCredentials(ctx, "12345678", "qq-key"); err != nil {
		t.Fatal(err)
	}
	if _, err := store.UpsertNeteaseCredentials(ctx, "12345678", "MUSIC_U=cookie", nil); err != nil {
		t.Fatal(err)
	}
	accounts, err := store.ListAccounts(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(accounts) != 2 {
		t.Fatalf("same platform-independent ID should create two accounts: %+v", accounts)
	}
	if accounts[0].Type != AccountTypeQQ || accounts[1].Type != AccountTypeNetease {
		t.Fatalf("unexpected account types: %+v", accounts)
	}
}

func assertCurrentAccountSchema(t *testing.T, db *sql.DB) {
	t.Helper()
	if version := schemaVersion(t, db); version != accountSchemaVersion {
		t.Fatalf("user_version=%d want=%d", version, accountSchemaVersion)
	}
	columns := accountTableColumns(t, db)
	if len(columns) != 16 {
		t.Fatalf("account columns=%d want=16: %v", len(columns), columns)
	}
	for _, required := range []string{
		"id", "account_type", "account_id", "credential", "credential_updated_at",
		"access_key", "nickname", "avatar_url", "vip_level", "vip_expires_at",
		"vip_checked_at", "login_valid", "login_checked_at", "login_expires_at",
		"created_at", "updated_at",
	} {
		if _, ok := columns[required]; !ok {
			t.Fatalf("current schema missing column %q: %v", required, columns)
		}
	}
	for _, legacy := range []string{"uin", "qm_keyst", "netease_cookie"} {
		if _, ok := columns[legacy]; ok {
			t.Fatalf("current schema retained legacy column %q: %v", legacy, columns)
		}
	}
}

func createDatabase(t *testing.T, path, statements string) {
	t.Helper()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(statements); err != nil {
		_ = db.Close()
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
}

func schemaVersion(t *testing.T, db *sql.DB) int {
	t.Helper()
	var version int
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		t.Fatal(err)
	}
	return version
}

func accountTableColumns(t *testing.T, db *sql.DB) map[string]struct{} {
	t.Helper()
	rows, err := db.Query("PRAGMA table_info(accounts)")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	columns := make(map[string]struct{})
	for rows.Next() {
		var (
			cid        int
			name       string
			dataType   string
			notNull    int
			defaultV   any
			primaryKey int
		)
		if err := rows.Scan(&cid, &name, &dataType, &notNull, &defaultV, &primaryKey); err != nil {
			t.Fatal(err)
		}
		columns[name] = struct{}{}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return columns
}
