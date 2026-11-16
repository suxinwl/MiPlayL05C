package account

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

const accountSchemaVersion = 1

const accountSchema = `
CREATE TABLE IF NOT EXISTS accounts (
	id                    INTEGER PRIMARY KEY AUTOINCREMENT,
	account_type          TEXT NOT NULL CHECK (account_type IN ('qq', 'netease')),
	account_id            TEXT NOT NULL,
	credential            TEXT NOT NULL,
	credential_updated_at INTEGER,
	access_key            TEXT,
	nickname              TEXT NOT NULL DEFAULT '',
	avatar_url            TEXT NOT NULL DEFAULT '',
	vip_level             INTEGER NOT NULL DEFAULT 0,
	vip_expires_at        INTEGER,
	vip_checked_at        INTEGER,
	login_valid           INTEGER NOT NULL DEFAULT 1,
	login_checked_at      INTEGER,
	login_expires_at      INTEGER,
	created_at            INTEGER NOT NULL,
	updated_at            INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_identity
	ON accounts(account_type, account_id);
CREATE INDEX IF NOT EXISTS idx_accounts_selection
	ON accounts(account_type, login_valid, vip_level DESC, vip_expires_at DESC, id ASC);
`

// Store 封装账号 SQLite 数据库。该实现使用 modernc.org/sqlite，
// 不依赖 cgo，适合在本地桌面后端中直接嵌入。
type Store struct {
	db *sql.DB
}

// Open 打开或创建账号数据库；旧结构会被清空并按当前 schema 重建。
func Open(path string) (*Store, error) {
	path = filepath.Clean(path)
	if err := ensureDatabaseFile(path); err != nil {
		return nil, err
	}

	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("打开账号数据库: %w", err)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)

	store := &Store{db: db}
	if err := store.initialize(context.Background()); err != nil {
		_ = db.Close()
		return nil, err
	}
	return store, nil
}

func ensureDatabaseFile(path string) error {
	if path == "" {
		return errors.New("账号数据库路径不能为空")
	}
	directory := filepath.Dir(path)
	_, directoryError := os.Stat(directory)
	newDirectory := errors.Is(directoryError, os.ErrNotExist)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("创建账号数据库目录: %w", err)
	}
	// Only tighten directories created for this database, never an existing
	// project/shared parent directory. Windows needs an inheritable DACL for
	// SQLite WAL/SHM files; Unix already applies 0700 in MkdirAll.
	if newDirectory {
		if err := setPrivateDatabaseDirectory(directory); err != nil {
			return fmt.Errorf("设置账号数据库目录权限: %w", err)
		}
	}
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return fmt.Errorf("创建账号数据库文件: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("关闭账号数据库文件: %w", err)
	}
	if err := setPrivateDatabaseFile(path); err != nil {
		return fmt.Errorf("设置账号数据库权限: %w", err)
	}
	return nil
}

func (s *Store) initialize(ctx context.Context) error {
	if s == nil || s.db == nil {
		return errors.New("账号数据库尚未初始化")
	}
	pragmas := []string{
		"PRAGMA busy_timeout = 5000",
		"PRAGMA journal_mode = WAL",
		"PRAGMA synchronous = NORMAL",
		"PRAGMA foreign_keys = ON",
	}
	for _, statement := range pragmas {
		if _, err := s.db.ExecContext(ctx, statement); err != nil {
			return fmt.Errorf("初始化账号数据库: %w", err)
		}
	}

	if s.hasCurrentAccountSchema(ctx) {
		if _, err := s.db.ExecContext(ctx, accountSchema); err != nil {
			return fmt.Errorf("校验账号数据库表: %w", err)
		}
		return nil
	}

	// 旧版账号数据没有迁移价值。仅保留当前完整结构，其余结构直接重建，
	// 避免长期维护多套字段补列与数据转换逻辑。
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("开始账号表重建事务: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, "DROP TABLE IF EXISTS accounts_v2"); err != nil {
		return fmt.Errorf("清理旧迁移临时表: %w", err)
	}
	if _, err := tx.ExecContext(ctx, "DROP TABLE IF EXISTS accounts"); err != nil {
		return fmt.Errorf("清理旧账号表: %w", err)
	}
	if _, err := tx.ExecContext(ctx, accountSchema); err != nil {
		return fmt.Errorf("重建账号数据库表: %w", err)
	}
	if _, err := tx.ExecContext(ctx, fmt.Sprintf("PRAGMA user_version = %d", accountSchemaVersion)); err != nil {
		return fmt.Errorf("设置账号数据库版本: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("提交账号表重建: %w", err)
	}
	return nil
}

func (s *Store) hasCurrentAccountSchema(ctx context.Context) bool {
	var version int
	if err := s.db.QueryRowContext(ctx, "PRAGMA user_version").Scan(&version); err != nil || version != accountSchemaVersion {
		return false
	}
	rows, err := s.db.QueryContext(ctx, "PRAGMA table_info(accounts)")
	if err != nil {
		return false
	}
	defer rows.Close()

	expected := map[string]struct{}{
		"id": {}, "account_type": {}, "account_id": {}, "credential": {},
		"credential_updated_at": {}, "access_key": {}, "nickname": {},
		"avatar_url": {}, "vip_level": {}, "vip_expires_at": {},
		"vip_checked_at": {}, "login_valid": {}, "login_checked_at": {},
		"login_expires_at": {}, "created_at": {}, "updated_at": {},
	}
	found := 0
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
			return false
		}
		if _, ok := expected[name]; !ok {
			return false
		}
		delete(expected, name)
		found++
	}
	return rows.Err() == nil && found == 16 && len(expected) == 0
}

const accountColumns = `
	id, account_type, account_id, credential, credential_updated_at,
	access_key, nickname, avatar_url, vip_level, vip_expires_at,
	vip_checked_at, login_valid, login_checked_at, login_expires_at,
	created_at, updated_at
`

// Close 关闭数据库连接。
func (s *Store) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

// UpsertCredentials 新增账号，或更新已有 QQ 音乐账号的 credential。
func (s *Store) UpsertCredentials(ctx context.Context, uin, qmKeyst string) (Account, error) {
	uin, qmKeyst, err := validateCredentials(uin, qmKeyst)
	if err != nil {
		return Account{}, err
	}
	accessKey, err := newAccessKey()
	if err != nil {
		return Account{}, err
	}
	now := time.Now().UTC().Unix()
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO accounts (
			account_type, account_id, credential, credential_updated_at,
			access_key, vip_level, vip_expires_at, vip_checked_at,
			login_valid, login_checked_at, created_at, updated_at
		)
		VALUES ('qq', ?, ?, ?, ?, 0, NULL, NULL, 1, NULL, ?, ?)
		ON CONFLICT(account_type, account_id) DO UPDATE SET
			credential = excluded.credential,
			credential_updated_at = CASE
				WHEN accounts.credential <> excluded.credential THEN excluded.credential_updated_at
				ELSE COALESCE(accounts.credential_updated_at, accounts.updated_at)
			END,
			access_key = CASE
				WHEN accounts.access_key IS NULL OR accounts.access_key = ''
					THEN excluded.access_key
				ELSE accounts.access_key
			END,
			vip_level = CASE
				WHEN accounts.credential <> excluded.credential THEN 0
				ELSE accounts.vip_level
			END,
			vip_expires_at = CASE
				WHEN accounts.credential <> excluded.credential THEN NULL
				ELSE accounts.vip_expires_at
			END,
			vip_checked_at = CASE
				WHEN accounts.credential <> excluded.credential THEN NULL
				ELSE accounts.vip_checked_at
			END,
			login_valid = 1,
			login_checked_at = NULL,
			login_expires_at = NULL,
			updated_at = excluded.updated_at
	`, uin, qmKeyst, now, accessKey, now, now)
	if err != nil {
		return Account{}, fmt.Errorf("保存 QQ 音乐账号: %w", err)
	}
	return s.accountByUIN(ctx, uin)
}

// UpsertNeteaseCredentials 新增或更新网易云音乐账号。
func (s *Store) UpsertNeteaseCredentials(ctx context.Context, uid, cookie string, expiresAt *time.Time) (Account, error) {
	uid, cookie, err := validateNeteaseCredentials(uid, cookie)
	if err != nil {
		return Account{}, err
	}
	accessKey, err := newAccessKey()
	if err != nil {
		return Account{}, err
	}
	now := time.Now().UTC().Unix()
	_, err = s.db.ExecContext(ctx, `
		INSERT INTO accounts (
			account_type, account_id, credential, credential_updated_at,
			access_key, vip_level, vip_expires_at, vip_checked_at,
			login_valid, login_checked_at, login_expires_at, created_at, updated_at
		)
		VALUES ('netease', ?, ?, ?, ?, 0, NULL, NULL, 1, NULL, ?, ?, ?)
		ON CONFLICT(account_type, account_id) DO UPDATE SET
			credential = excluded.credential,
			credential_updated_at = CASE
				WHEN accounts.credential <> excluded.credential THEN excluded.credential_updated_at
				ELSE COALESCE(accounts.credential_updated_at, accounts.updated_at)
			END,
			access_key = CASE
				WHEN accounts.access_key IS NULL OR accounts.access_key = ''
					THEN excluded.access_key
				ELSE accounts.access_key
			END,
			vip_level = 0,
			vip_expires_at = NULL,
			vip_checked_at = NULL,
			login_valid = 1,
			login_checked_at = NULL,
			login_expires_at = excluded.login_expires_at,
			updated_at = excluded.updated_at
	`, uid, cookie, now, accessKey, unixPtr(expiresAt), now, now)
	if err != nil {
		return Account{}, fmt.Errorf("保存网易云音乐账号: %w", err)
	}
	return s.accountByTypeAndID(ctx, AccountTypeNetease, uid)
}

func (s *Store) accountByUIN(ctx context.Context, uin string) (Account, error) {
	return s.accountByTypeAndID(ctx, AccountTypeQQ, uin)
}

func (s *Store) accountByTypeAndID(ctx context.Context, accountType AccountType, accountID string) (Account, error) {
	if !accountType.Valid() {
		return Account{}, errors.New("账号类型不合法")
	}
	row := s.db.QueryRowContext(ctx, `
		SELECT `+accountColumns+`
		FROM accounts WHERE account_type = ? AND account_id = ?
	`, accountType, strings.TrimSpace(accountID))
	item, err := scanAccount(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Account{}, ErrNoAccount
	}
	if err != nil {
		return Account{}, accountScanError(0, err)
	}
	return item, nil
}

// AccountByID 按数据库 ID 查询绑定账号。
func (s *Store) AccountByID(ctx context.Context, id int64) (Account, error) {
	if id <= 0 {
		return Account{}, ErrNoAccount
	}
	row := s.db.QueryRowContext(ctx, `
		SELECT `+accountColumns+`
		FROM accounts WHERE id = ?
	`, id)
	item, err := scanAccount(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Account{}, ErrNoAccount
	}
	if err != nil {
		return Account{}, accountScanError(id, err)
	}
	return item, nil
}

// UpdateProfile 保存账号昵称和头像地址。
// 空值不会覆盖数据库中已有的资料，方便资料接口短暂异常时保留旧缓存。
func (s *Store) UpdateProfile(ctx context.Context, id int64, nickname, avatarURL string) error {
	if id <= 0 {
		return errors.New("账号 ID 不合法")
	}
	nickname = strings.TrimSpace(nickname)
	avatarURL = strings.TrimSpace(avatarURL)
	if len(nickname) > 200 {
		nickname = nickname[:200]
	}
	if len(avatarURL) > 2048 {
		avatarURL = avatarURL[:2048]
	}
	_, err := s.db.ExecContext(ctx, `
		UPDATE accounts
		SET nickname = CASE WHEN ? <> '' THEN ? ELSE nickname END,
			avatar_url = CASE WHEN ? <> '' THEN ? ELSE avatar_url END,
			updated_at = ?
		WHERE id = ?
	`, nickname, nickname, avatarURL, avatarURL, time.Now().UTC().Unix(), id)
	if err != nil {
		return fmt.Errorf("更新账号资料: %w", err)
	}
	return nil
}

// UpdateCredentialsByID 替换指定 QQ 音乐账号的 credential，并重置登录检查状态。
func (s *Store) UpdateCredentialsByID(ctx context.Context, id int64, qmKeyst string) (Account, error) {
	if id <= 0 {
		return Account{}, ErrNoAccount
	}
	qmKeyst = strings.TrimSpace(qmKeyst)
	if qmKeyst == "" {
		return Account{}, errors.New("qm_keyst 不能为空")
	}
	if len(qmKeyst) > 4096 {
		return Account{}, errors.New("qm_keyst 长度不合法")
	}
	accessKey, err := newAccessKey()
	if err != nil {
		return Account{}, err
	}
	now := time.Now().UTC().Unix()
	result, err := s.db.ExecContext(ctx, `
		UPDATE accounts
		SET credential = ?, credential_updated_at = ?, access_key = CASE
				WHEN access_key IS NULL OR access_key = '' THEN ?
				ELSE access_key
			END,
			vip_level = 0, vip_expires_at = NULL,
			vip_checked_at = NULL, login_valid = 1,
			login_checked_at = NULL, login_expires_at = NULL, updated_at = ?
		WHERE id = ? AND account_type = 'qq'
	`, qmKeyst, now, accessKey, now, id)
	if err != nil {
		return Account{}, fmt.Errorf("更新账号 qm_keyst: %w", err)
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return Account{}, fmt.Errorf("读取账号更新结果: %w", err)
	}
	if affected == 0 {
		return Account{}, ErrNoAccount
	}
	return s.AccountByID(ctx, id)
}

// UpdateNeteaseCookieByID 替换指定网易云音乐账号的 credential，并重置登录检查状态。
func (s *Store) UpdateNeteaseCookieByID(ctx context.Context, id int64, cookie string, expiresAt *time.Time) (Account, error) {
	if id <= 0 {
		return Account{}, ErrNoAccount
	}
	cookie = normalizeCookieInput(cookie)
	if cookie == "" {
		return Account{}, errors.New("Cookie 不能为空")
	}
	if len(cookie) > maxNeteaseCookieLength {
		return Account{}, errors.New("Cookie 长度不合法")
	}
	now := time.Now().UTC().Unix()
	result, err := s.db.ExecContext(ctx, `
		UPDATE accounts
		SET credential = ?, credential_updated_at = ?,
			vip_level = 0, vip_expires_at = NULL,
			vip_checked_at = NULL, login_valid = 1,
			login_checked_at = NULL, login_expires_at = ?, updated_at = ?
		WHERE id = ? AND account_type = 'netease'
	`, cookie, now, unixPtr(expiresAt), now, id)
	if err != nil {
		return Account{}, fmt.Errorf("更新网易云音乐账号 Cookie: %w", err)
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return Account{}, fmt.Errorf("读取账号更新结果: %w", err)
	}
	if affected == 0 {
		return Account{}, ErrNoAccount
	}
	return s.AccountByID(ctx, id)
}

// UpdateNeteaseSession 保存网易云音乐账号刷新后的 Cookie、登录态和授权到期时间。
func (s *Store) UpdateNeteaseSession(ctx context.Context, id int64, cookie string, valid bool, expiresAt, checkedAt time.Time) error {
	if id <= 0 {
		return errors.New("账号 ID 不合法")
	}
	cookie = normalizeCookieInput(cookie)
	if valid && cookie == "" {
		return errors.New("有效网易云音乐账号缺少 Cookie")
	}
	if checkedAt.IsZero() {
		checkedAt = time.Now().UTC()
	}
	validValue := 0
	if valid {
		validValue = 1
	}
	now := time.Now().UTC().Unix()
	_, err := s.db.ExecContext(ctx, `
		UPDATE accounts
		SET credential = CASE WHEN ? <> '' THEN ? ELSE credential END,
			credential_updated_at = CASE WHEN ? <> '' THEN ? ELSE credential_updated_at END,
			login_valid = ?, login_checked_at = ?, login_expires_at = ?,
			access_key = CASE WHEN ? THEN access_key ELSE NULL END,
			updated_at = ?
		WHERE id = ? AND account_type = 'netease'
	`, cookie, cookie, cookie, now, validValue, checkedAt.UTC().Unix(), unixPtr(timePtr(expiresAt)),
		valid, now, id)
	if err != nil {
		return fmt.Errorf("更新网易云音乐账号会话: %w", err)
	}
	return nil
}

// DeleteAccountByID 删除指定绑定账号。
func (s *Store) DeleteAccountByID(ctx context.Context, id int64) error {
	if id <= 0 {
		return ErrNoAccount
	}
	result, err := s.db.ExecContext(ctx, "DELETE FROM accounts WHERE id = ?", id)
	if err != nil {
		return fmt.Errorf("删除绑定账号: %w", err)
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("读取绑定账号删除结果: %w", err)
	}
	if affected == 0 {
		return ErrNoAccount
	}
	return nil
}

// SelectAccount 按会员等级和到期时间选择优先级最高的 QQ 音乐账号。
// 已知已经过期的会员等级会在排序时按 0 处理。
func (s *Store) SelectAccount(ctx context.Context) (Account, error) {
	return s.SelectAccountByType(ctx, AccountTypeQQ)
}

// SelectAccountByType 按会员等级和到期时间选择指定平台优先级最高的账号。
func (s *Store) SelectAccountByType(ctx context.Context, accountType AccountType) (Account, error) {
	if !accountType.Valid() {
		return Account{}, errors.New("账号类型不合法")
	}
	now := time.Now().UTC().Unix()
	row := s.db.QueryRowContext(ctx, `
		SELECT `+accountColumns+`
		FROM accounts
		WHERE account_type = ? AND login_valid = 1
		ORDER BY
			CASE WHEN vip_expires_at IS NOT NULL AND vip_expires_at <= ? THEN 0 ELSE vip_level END DESC,
			COALESCE(vip_expires_at, 0) DESC,
			id ASC
		LIMIT 1
	`, accountType, now)
	item, err := scanAccount(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Account{}, ErrNoAccount
	}
	if err != nil {
		return Account{}, fmt.Errorf("选择%s账号: %w", accountType.Name(), err)
	}
	return item, nil
}

// ListAccounts 返回数据库中的全部账号，仅供账号池和后台任务使用。
func (s *Store) ListAccounts(ctx context.Context) ([]Account, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT `+accountColumns+`
		FROM accounts ORDER BY id ASC
	`)
	if err != nil {
		return nil, fmt.Errorf("查询音乐账号: %w", err)
	}
	defer rows.Close()

	var result []Account
	for rows.Next() {
		item, err := scanAccount(rows)
		if err != nil {
			return nil, fmt.Errorf("读取音乐账号: %w", err)
		}
		result = append(result, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("遍历音乐账号: %w", err)
	}
	return result, nil
}

// ListStaleAccounts 返回 QQ 音乐会员状态超过指定时间未刷新的账号。
func (s *Store) ListStaleAccounts(ctx context.Context, staleBefore time.Time) ([]Account, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT `+accountColumns+`
		FROM accounts
		WHERE account_type = 'qq' AND (vip_checked_at IS NULL OR vip_checked_at < ?)
		ORDER BY id ASC
	`, staleBefore.UTC().Unix())
	if err != nil {
		return nil, fmt.Errorf("查询待刷新账号: %w", err)
	}
	defer rows.Close()

	var result []Account
	for rows.Next() {
		item, err := scanAccount(rows)
		if err != nil {
			return nil, fmt.Errorf("读取待刷新账号: %w", err)
		}
		result = append(result, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("遍历待刷新账号: %w", err)
	}
	return result, nil
}

// UpdateVipStatus 保存刷新后的会员等级和到期时间。
func (s *Store) UpdateVipStatus(ctx context.Context, id int64, level int, expiresAt, checkedAt time.Time) error {
	if id <= 0 {
		return errors.New("账号 ID 不合法")
	}
	if level < VipLevelNone || level > VipLevelSuper {
		return fmt.Errorf("会员等级不合法: %d", level)
	}
	if checkedAt.IsZero() {
		checkedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx, `
		UPDATE accounts
		SET vip_level = ?, vip_expires_at = ?, vip_checked_at = ?, updated_at = ?
		WHERE id = ?
	`, level, unixPtr(timePtr(expiresAt)), checkedAt.UTC().Unix(), time.Now().UTC().Unix(), id)
	if err != nil {
		return fmt.Errorf("更新账号会员状态: %w", err)
	}
	return nil
}

// MarkVipCheckAttempt 记录一次刷新尝试，避免刷新失败时每次请求都重复访问接口。
func (s *Store) MarkVipCheckAttempt(ctx context.Context, id int64, checkedAt time.Time) error {
	if id <= 0 {
		return errors.New("账号 ID 不合法")
	}
	_, err := s.db.ExecContext(ctx, `
		UPDATE accounts SET vip_checked_at = ?, updated_at = ? WHERE id = ?
	`, checkedAt.UTC().Unix(), time.Now().UTC().Unix(), id)
	if err != nil {
		return fmt.Errorf("记录会员状态刷新时间: %w", err)
	}
	return nil
}

// ExpireVIPAccounts 将已经超过会员到期时间的账号立即降级为普通用户。
func (s *Store) ExpireVIPAccounts(ctx context.Context, now time.Time) error {
	_, err := s.db.ExecContext(ctx, `
		UPDATE accounts
		SET vip_level = 0, vip_checked_at = ?, updated_at = ?
		WHERE vip_level > 0 AND vip_expires_at IS NOT NULL AND vip_expires_at <= ?
	`, now.UTC().Unix(), now.UTC().Unix(), now.UTC().Unix())
	if err != nil {
		return fmt.Errorf("更新过期会员账号: %w", err)
	}
	return nil
}

// UpdateLoginStatus 保存账号最近一次登录态检查结果。
func (s *Store) UpdateLoginStatus(ctx context.Context, id int64, valid bool, checkedAt time.Time) error {
	if id <= 0 {
		return errors.New("账号 ID 不合法")
	}
	value := 0
	if valid {
		value = 1
	}
	statement := `
		UPDATE accounts
		SET login_valid = ?, login_checked_at = ?, updated_at = ?
		WHERE id = ?
	`
	args := []any{value, checkedAt.UTC().Unix(), time.Now().UTC().Unix(), id}
	if !valid {
		statement = `
			UPDATE accounts
			SET login_valid = 0, access_key = NULL,
				login_checked_at = ?, updated_at = ?
			WHERE id = ?
		`
		args = []any{checkedAt.UTC().Unix(), time.Now().UTC().Unix(), id}
	}
	_, err := s.db.ExecContext(ctx, statement, args...)
	if err != nil {
		return fmt.Errorf("更新账号登录状态: %w", err)
	}
	return nil
}

// MarkLoginCheckAttempt 记录一次未得出结论的登录态检查时间。
func (s *Store) MarkLoginCheckAttempt(ctx context.Context, id int64, checkedAt time.Time) error {
	if id <= 0 {
		return errors.New("账号 ID 不合法")
	}
	_, err := s.db.ExecContext(ctx, `
		UPDATE accounts
		SET login_checked_at = ?, updated_at = ?
		WHERE id = ?
	`, checkedAt.UTC().Unix(), time.Now().UTC().Unix(), id)
	if err != nil {
		return fmt.Errorf("记录账号登录态检查时间: %w", err)
	}
	return nil
}

// ListUsableAccounts 返回当前登录态未被标记为失效的 QQ 音乐账号。
func (s *Store) ListUsableAccounts(ctx context.Context) ([]Account, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT `+accountColumns+`
		FROM accounts
		WHERE account_type = 'qq' AND login_valid = 1
		ORDER BY id ASC
	`)
	if err != nil {
		return nil, fmt.Errorf("查询可用 QQ 音乐账号: %w", err)
	}
	defer rows.Close()
	var result []Account
	for rows.Next() {
		item, err := scanAccount(rows)
		if err != nil {
			return nil, fmt.Errorf("读取可用 QQ 音乐账号: %w", err)
		}
		result = append(result, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("遍历可用 QQ 音乐账号: %w", err)
	}
	return result, nil
}

// ListUsableAccountsByType 返回指定平台当前登录态未被标记为失效的账号。
func (s *Store) ListUsableAccountsByType(ctx context.Context, accountType AccountType) ([]Account, error) {
	if !accountType.Valid() {
		return nil, errors.New("账号类型不合法")
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT `+accountColumns+`
		FROM accounts
		WHERE account_type = ? AND login_valid = 1
		ORDER BY id ASC
	`, accountType)
	if err != nil {
		return nil, fmt.Errorf("查询可用音乐账号: %w", err)
	}
	defer rows.Close()
	var result []Account
	for rows.Next() {
		item, err := scanAccount(rows)
		if err != nil {
			return nil, fmt.Errorf("读取可用音乐账号: %w", err)
		}
		result = append(result, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("遍历可用音乐账号: %w", err)
	}
	return result, nil
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanAccount(scanner rowScanner) (Account, error) {
	var (
		item                Account
		accountType         string
		credentialUpdatedAt sql.NullInt64
		accessKey           sql.NullString
		expiresAt           sql.NullInt64
		checkedAt           sql.NullInt64
		loginValid          int
		loginCheckedAt      sql.NullInt64
		loginExpiresAt      sql.NullInt64
		createdAt           int64
		updatedAt           int64
	)
	if err := scanner.Scan(
		&item.ID,
		&accountType,
		&item.AccountID,
		&item.Credential,
		&credentialUpdatedAt,
		&accessKey,
		&item.Nickname,
		&item.AvatarURL,
		&item.VipLevel,
		&expiresAt,
		&checkedAt,
		&loginValid,
		&loginCheckedAt,
		&loginExpiresAt,
		&createdAt,
		&updatedAt,
	); err != nil {
		return Account{}, err
	}
	item.Type = AccountType(accountType)
	if !item.Type.Valid() {
		return Account{}, fmt.Errorf("账号 %d 使用未知平台 %q", item.ID, accountType)
	}
	if credentialUpdatedAt.Valid {
		item.CredentialUpdatedAt = parseUnixPointer(&credentialUpdatedAt.Int64)
	}
	if accessKey.Valid {
		item.AccessKey = accessKey.String
	}
	if expiresAt.Valid {
		item.VipExpiresAt = parseUnixPointer(&expiresAt.Int64)
	}
	if checkedAt.Valid {
		item.VipCheckedAt = parseUnixPointer(&checkedAt.Int64)
	}
	item.LoginValid = loginValid != 0
	if loginCheckedAt.Valid {
		item.LoginCheckedAt = parseUnixPointer(&loginCheckedAt.Int64)
	}
	if loginExpiresAt.Valid {
		item.LoginExpiresAt = parseUnixPointer(&loginExpiresAt.Int64)
	}
	item.CreatedAt = time.Unix(createdAt, 0).UTC()
	item.UpdatedAt = time.Unix(updatedAt, 0).UTC()
	return item, nil
}
