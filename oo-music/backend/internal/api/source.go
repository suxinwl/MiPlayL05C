package api

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"

	oomusic "github.com/rankgice/oo-music"
	"github.com/rankgice/oo-music/internal/account"
	"github.com/rankgice/oo-music/internal/netease"
)

func parseMusicSource(raw string) (account.AccountType, error) {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "qq":
		return account.AccountTypeQQ, nil
	case "netease":
		return account.AccountTypeNetease, nil
	default:
		return "", fmt.Errorf("source 必须明确指定 qq 或 netease")
	}
}

// requestMusicSource 优先读取 source 查询参数，其次读取客户端平台请求头。
func requestMusicSource(r *http.Request) (account.AccountType, error) {
	raw := strings.TrimSpace(r.URL.Query().Get("source"))
	if raw == "" {
		raw = strings.TrimSpace(r.Header.Get(account.ClientSourceHeader))
	}
	return parseMusicSource(raw)
}

func (s *Server) readMusicSource(w http.ResponseWriter, r *http.Request) (account.AccountType, bool) {
	source, err := requestMusicSource(r)
	if err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_source", err.Error())
		return "", false
	}
	return source, true
}

// qqClientForMedia 只从服务端 QQ 账号池选择上游账号。
// 客户端 accessKey 只用于接口鉴权，不参与这里的上游账号选择。
func (s *Server) qqClientForMedia(ctx context.Context, policy account.MediaAccountPolicy) (*oomusic.Client, error) {
	if s.accounts == nil {
		return nil, errors.New("账号池不可用")
	}
	return s.accounts.ClientForMedia(ctx, policy)
}

// neteaseCookieForMedia 只从服务端网易云账号池选择上游 Cookie。
// 客户端 accessKey 只用于接口鉴权，不参与这里的上游账号选择。
func (s *Server) neteaseCookieForMedia(ctx context.Context, policy account.MediaAccountPolicy) (string, string, bool, error) {
	if s.accounts == nil {
		return "", "", false, errors.New("账号池不可用")
	}
	item, ok, err := s.accounts.SelectedCredentialForMedia(ctx, account.AccountTypeNetease, policy)
	if err != nil || !ok {
		return "", "", false, err
	}
	return item.Credential, item.AccountID, true, nil
}

func (s *Server) neteaseAvailable(w http.ResponseWriter) bool {
	if s.netease == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "netease_unavailable", "网易云音乐服务暂不可用")
		return false
	}
	return true
}

func (s *Server) neteaseMediaError(w http.ResponseWriter, operation string, err error) {
	if errors.Is(err, netease.ErrUnauthorized) {
		writeAPIError(w, http.StatusUnauthorized, "netease_login_invalid", "网易云音乐登录态已失效，请重新授权")
		return
	}
	if errors.Is(err, account.ErrAccountLoginExpired) || errors.Is(err, account.ErrInvalidClientAuthorization) {
		writeAPIError(w, http.StatusUnauthorized, "netease_login_invalid", "网易云音乐登录态已失效，请重新授权")
		return
	}
	s.internalError(w, operation, err)
}
