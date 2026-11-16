// Package admin implements backend administrator authentication and storage.
package admin

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	_ "modernc.org/sqlite"
)

var (
	// ErrUserNotFound 表示后台管理员不存在。
	ErrUserNotFound = errors.New("后台管理员不存在")
	// ErrUsernameExists 表示后台管理员用户名已经存在。
	ErrUsernameExists = errors.New("后台管理员用户名已存在")
	// ErrLastAdmin 表示不能删除后台管理员表中的最后一个账号。
	ErrLastAdmin = errors.New("至少需要保留一个后台管理员")
)

const (
	publicAPIAuthSettingKey = "public_api_require_auth"
)

const adminUserSchema = `
CREATE TABLE IF NOT EXISTS admin_users (
	id             INTEGER PRIMARY KEY AUTOINCREMENT,
	username       TEXT NOT NULL,
	username_key   TEXT NOT NULL UNIQUE,
	password_hash  TEXT NOT NULL,
	created_at     INTEGER NOT NULL,
	updated_at     INTEGER NOT NULL
);
`

const systemSettingSchema = `
CREATE TABLE IF NOT EXISTS system_settings (
	key        TEXT PRIMARY KEY,
	value      TEXT NOT NULL,
	updated_at INTEGER NOT NULL
);
`

// User 是后台管理员的安全公开视图，不包含密码摘要。
type User struct {
	ID        int64     `json:"id"`
	Username  string    `json:"username"`
	CreatedAt time.Time `json:"createdAt"`
	UpdatedAt time.Time `json:"updatedAt"`
}

type userRecord struct {
	User
	PasswordHash string
}

// Store 使用同一个不依赖 cgo 的 SQLite 数据库保存后台管理员。
type Store struct {
	db *sql.DB
}

// Open 打开管理员数据库。通常应传入与账号池相同的 SQLite 文件路径。
func Open(path string) (*Store, error) {
	path = filepath.Clean(strings.TrimSpace(path))
	if path == "" || path == "." {
		return nil, errors.New("后台管理员数据库路径不能为空")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("创建后台管理员数据库目录: %w", err)
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("打开后台管理员数据库: %w", err)
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

func (s *Store) initialize(ctx context.Context) error {
	for _, statement := range []string{
		"PRAGMA busy_timeout = 5000",
		"PRAGMA journal_mode = WAL",
		"PRAGMA synchronous = NORMAL",
	} {
		if _, err := s.db.ExecContext(ctx, statement); err != nil {
			return fmt.Errorf("初始化后台管理员数据库: %w", err)
		}
	}
	if _, err := s.db.ExecContext(ctx, adminUserSchema); err != nil {
		return fmt.Errorf("创建后台管理员表: %w", err)
	}
	if _, err := s.db.ExecContext(ctx, systemSettingSchema); err != nil {
		return fmt.Errorf("创建系统设置表: %w", err)
	}
	if _, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO system_settings (key, value, updated_at)
		VALUES (?, ?, ?)
	`, publicAPIAuthSettingKey, "false", time.Now().UTC().Unix()); err != nil {
		return fmt.Errorf("初始化公开接口鉴权开关: %w", err)
	}
	return nil
}

// PublicAPIAuthRequired 返回公开业务接口是否强制要求客户端授权。
// 设置不存在时按关闭处理；读取或解析设置失败时返回错误，避免静默放宽鉴权。
func (s *Store) PublicAPIAuthRequired(ctx context.Context) (bool, error) {
	var value string
	err := s.db.QueryRowContext(ctx, `
		SELECT value FROM system_settings WHERE key = ?
	`, publicAPIAuthSettingKey).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("读取公开接口鉴权开关: %w", err)
	}
	required, err := strconv.ParseBool(strings.TrimSpace(value))
	if err != nil {
		return false, fmt.Errorf("解析公开接口鉴权开关: %w", err)
	}
	return required, nil
}

// SetPublicAPIAuthRequired 更新公开业务接口是否强制要求客户端授权。
func (s *Store) SetPublicAPIAuthRequired(ctx context.Context, required bool) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO system_settings (key, value, updated_at)
		VALUES (?, ?, ?)
		ON CONFLICT(key) DO UPDATE SET
			value = excluded.value,
			updated_at = excluded.updated_at
	`, publicAPIAuthSettingKey, strconv.FormatBool(required), time.Now().UTC().Unix())
	if err != nil {
		return fmt.Errorf("保存公开接口鉴权开关: %w", err)
	}
	return nil
}

// Close 关闭数据库连接。
func (s *Store) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

// CountUsers 返回后台管理员表中的记录数。
func (s *Store) CountUsers(ctx context.Context) (int, error) {
	var count int
	if err := s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM admin_users").Scan(&count); err != nil {
		return 0, fmt.Errorf("统计后台管理员: %w", err)
	}
	return count, nil
}

// EnsureInitialUser 仅在管理员表完全为空时创建配置中的初始管理员。
// 表里已经存在其他管理员时，即使配置用户名不存在也不会新增记录。
func (s *Store) EnsureInitialUser(ctx context.Context, username, password string) (created bool, user User, err error) {
	count, err := s.CountUsers(ctx)
	if err != nil {
		return false, User{}, err
	}
	if count > 0 {
		return false, User{}, nil
	}
	username, err = validateUsername(username)
	if err != nil {
		return false, User{}, err
	}
	hash, err := HashPassword(password)
	if err != nil {
		return false, User{}, err
	}
	user, err = s.CreateUser(ctx, username, hash)
	if errors.Is(err, ErrUsernameExists) {
		return false, User{}, nil
	}
	if err != nil {
		return false, User{}, err
	}
	return true, user, nil
}

// CreateUser 使用已经哈希的密码创建后台管理员。
func (s *Store) CreateUser(ctx context.Context, username, passwordHash string) (User, error) {
	username, err := validateUsername(username)
	if err != nil {
		return User{}, err
	}
	if strings.TrimSpace(passwordHash) == "" {
		return User{}, errors.New("后台管理员密码摘要不能为空")
	}
	now := time.Now().UTC()
	result, err := s.db.ExecContext(ctx, `
		INSERT INTO admin_users (username, username_key, password_hash, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?)
	`, username, usernameKey(username), passwordHash, now.Unix(), now.Unix())
	if err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "unique") {
			return User{}, ErrUsernameExists
		}
		return User{}, fmt.Errorf("创建后台管理员: %w", err)
	}
	id, err := result.LastInsertId()
	if err != nil {
		return User{}, fmt.Errorf("读取后台管理员 ID: %w", err)
	}
	return User{ID: id, Username: username, CreatedAt: now, UpdatedAt: now}, nil
}

// ListUsers 返回所有后台管理员的安全公开视图。
func (s *Store) ListUsers(ctx context.Context) ([]User, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, username, created_at, updated_at
		FROM admin_users ORDER BY id ASC
	`)
	if err != nil {
		return nil, fmt.Errorf("查询后台管理员: %w", err)
	}
	defer rows.Close()
	result := make([]User, 0)
	for rows.Next() {
		var item User
		var createdAt, updatedAt int64
		if err := rows.Scan(&item.ID, &item.Username, &createdAt, &updatedAt); err != nil {
			return nil, fmt.Errorf("读取后台管理员: %w", err)
		}
		item.CreatedAt = time.Unix(createdAt, 0).UTC()
		item.UpdatedAt = time.Unix(updatedAt, 0).UTC()
		result = append(result, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("遍历后台管理员: %w", err)
	}
	return result, nil
}

// UserByID 按 ID 查询后台管理员。
func (s *Store) UserByID(ctx context.Context, id int64) (User, error) {
	if id <= 0 {
		return User{}, ErrUserNotFound
	}
	var item User
	var createdAt, updatedAt int64
	err := s.db.QueryRowContext(ctx, `
		SELECT id, username, created_at, updated_at
		FROM admin_users WHERE id = ?
	`, id).Scan(&item.ID, &item.Username, &createdAt, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return User{}, ErrUserNotFound
	}
	if err != nil {
		return User{}, fmt.Errorf("查询后台管理员: %w", err)
	}
	item.CreatedAt = time.Unix(createdAt, 0).UTC()
	item.UpdatedAt = time.Unix(updatedAt, 0).UTC()
	return item, nil
}

func (s *Store) userRecordByUsername(ctx context.Context, username string) (userRecord, error) {
	username, err := validateUsername(username)
	if err != nil {
		return userRecord{}, ErrUserNotFound
	}
	var item userRecord
	var createdAt, updatedAt int64
	err = s.db.QueryRowContext(ctx, `
		SELECT id, username, password_hash, created_at, updated_at
		FROM admin_users WHERE username_key = ?
	`, usernameKey(username)).Scan(
		&item.ID,
		&item.Username,
		&item.PasswordHash,
		&createdAt,
		&updatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return userRecord{}, ErrUserNotFound
	}
	if err != nil {
		return userRecord{}, fmt.Errorf("查询后台管理员账号: %w", err)
	}
	item.CreatedAt = time.Unix(createdAt, 0).UTC()
	item.UpdatedAt = time.Unix(updatedAt, 0).UTC()
	return item, nil
}

// DeleteUser 删除后台管理员。删除不存在的用户时返回 ErrUserNotFound。
func (s *Store) DeleteUser(ctx context.Context, id int64) error {
	if id <= 0 {
		return ErrUserNotFound
	}
	result, err := s.db.ExecContext(ctx, "DELETE FROM admin_users WHERE id = ?", id)
	if err != nil {
		return fmt.Errorf("删除后台管理员: %w", err)
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("读取后台管理员删除结果: %w", err)
	}
	if affected == 0 {
		return ErrUserNotFound
	}
	return nil
}

// DeleteUserIfNotLast 在同一事务内检查并删除管理员，防止并发请求删空管理员表。
func (s *Store) DeleteUserIfNotLast(ctx context.Context, id int64) error {
	if id <= 0 {
		return ErrUserNotFound
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("开始删除后台管理员事务: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var count int
	if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM admin_users").Scan(&count); err != nil {
		return fmt.Errorf("统计后台管理员: %w", err)
	}
	if count <= 1 {
		return ErrLastAdmin
	}
	result, err := tx.ExecContext(ctx, "DELETE FROM admin_users WHERE id = ?", id)
	if err != nil {
		return fmt.Errorf("删除后台管理员: %w", err)
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("读取后台管理员删除结果: %w", err)
	}
	if affected == 0 {
		return ErrUserNotFound
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("提交删除后台管理员事务: %w", err)
	}
	return nil
}

func validateUsername(value string) (string, error) {
	value = strings.TrimSpace(value)
	length := utf8.RuneCountInString(value)
	if length < 3 || length > 64 {
		return "", errors.New("后台用户名长度必须在 3 到 64 个字符之间")
	}
	for _, char := range value {
		if unicode.IsSpace(char) || unicode.IsControl(char) {
			return "", errors.New("后台用户名不能包含空白或控制字符")
		}
	}
	return value, nil
}

func usernameKey(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}
