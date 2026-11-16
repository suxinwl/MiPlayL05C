package admin

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"
)

const defaultSessionTTL = 12 * time.Hour

var (
	// ErrInvalidCredentials 表示后台用户名或密码错误。
	ErrInvalidCredentials = errors.New("后台用户名或密码错误")
	// ErrInvalidSession 表示管理端会话不存在、已过期或已退出。
	ErrInvalidSession = errors.New("后台登录会话无效")
)

// Session 是已登录后台管理员的会话。
type Session struct {
	Token     string
	User      User
	ExpiresAt time.Time
}

type sessionRecord struct {
	user      User
	expiresAt time.Time
}

// AuthService 负责管理员登录校验和内存会话管理。
// 服务重启后会话会失效，需要重新登录；管理员账号仍持久化在 SQLite 中。
type AuthService struct {
	store     *Store
	ttl       time.Duration
	now       func() time.Time
	mu        sync.RWMutex
	sessions  map[string]sessionRecord
	dummyHash string
}

// NewAuthService 创建管理员认证服务。ttl 小于等于零时默认 12 小时。
func NewAuthService(store *Store, ttl time.Duration) (*AuthService, error) {
	if store == nil {
		return nil, errors.New("后台认证服务需要管理员数据库")
	}
	if ttl <= 0 {
		ttl = defaultSessionTTL
	}
	dummyHash, err := HashPassword("oo-music-invalid-login-dummy")
	if err != nil {
		return nil, fmt.Errorf("初始化后台登录校验: %w", err)
	}
	return &AuthService{
		store:     store,
		ttl:       ttl,
		now:       time.Now,
		sessions:  make(map[string]sessionRecord),
		dummyHash: dummyHash,
	}, nil
}

// Login 校验用户名和密码，成功后生成不可预测的随机会话令牌。
func (a *AuthService) Login(ctx context.Context, username, password string) (Session, error) {
	record, err := a.store.userRecordByUsername(ctx, username)
	if errors.Is(err, ErrUserNotFound) {
		_, _ = VerifyPassword(a.dummyHash, password)
		return Session{}, ErrInvalidCredentials
	}
	if err != nil {
		return Session{}, err
	}
	valid, err := VerifyPassword(record.PasswordHash, password)
	if err != nil {
		return Session{}, fmt.Errorf("校验后台密码摘要: %w", err)
	}
	if !valid {
		return Session{}, ErrInvalidCredentials
	}
	token, err := randomToken()
	if err != nil {
		return Session{}, fmt.Errorf("生成后台登录会话: %w", err)
	}
	now := a.now().UTC()
	session := Session{Token: token, User: record.User, ExpiresAt: now.Add(a.ttl)}
	a.mu.Lock()
	a.removeExpiredLocked(now)
	a.sessions[token] = sessionRecord{user: record.User, expiresAt: session.ExpiresAt}
	a.mu.Unlock()
	return session, nil
}

// Authenticate 验证会话令牌并返回当前管理员。
func (a *AuthService) Authenticate(token string) (Session, error) {
	token = strings.TrimSpace(token)
	if token == "" {
		return Session{}, ErrInvalidSession
	}
	now := a.now().UTC()
	a.mu.RLock()
	record, exists := a.sessions[token]
	a.mu.RUnlock()
	if !exists || !record.expiresAt.After(now) {
		if exists {
			a.mu.Lock()
			delete(a.sessions, token)
			a.mu.Unlock()
		}
		return Session{}, ErrInvalidSession
	}
	return Session{Token: token, User: record.user, ExpiresAt: record.expiresAt}, nil
}

// Logout 删除指定会话令牌。
func (a *AuthService) Logout(token string) {
	a.mu.Lock()
	delete(a.sessions, strings.TrimSpace(token))
	a.mu.Unlock()
}

// RevokeUserSessions 在管理员被删除后立即注销其全部会话。
func (a *AuthService) RevokeUserSessions(userID int64) {
	a.mu.Lock()
	for token, record := range a.sessions {
		if record.user.ID == userID {
			delete(a.sessions, token)
		}
	}
	a.mu.Unlock()
}

// TTL 返回当前配置的会话有效期。
func (a *AuthService) TTL() time.Duration {
	if a == nil {
		return defaultSessionTTL
	}
	return a.ttl
}

func (a *AuthService) removeExpiredLocked(now time.Time) {
	for token, record := range a.sessions {
		if !record.expiresAt.After(now) {
			delete(a.sessions, token)
		}
	}
}

func randomToken() (string, error) {
	value := make([]byte, 32)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}
