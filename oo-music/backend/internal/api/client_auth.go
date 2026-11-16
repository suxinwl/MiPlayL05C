package api

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"github.com/rankgice/oo-music/internal/account"
)

type clientAccountContextKey struct{}

// requireClientAuthorization 校验客户端请求头中的平台账号 ID、来源和 accessKey。
// 用户资料、远程歌单等固定受保护接口直接使用该中间件；公开业务接口则通过
// withPublicAPIAuthorization 根据管理后台的运行时开关决定是否调用它。
func (s *Server) requireClientAuthorization(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.accounts == nil {
			writeAPIError(w, http.StatusServiceUnavailable, "authorization_unavailable", "客户端授权服务暂不可用")
			return
		}
		source, ok := s.readMusicSource(w, r)
		if !ok {
			return
		}
		authorized, err := s.accounts.AuthorizeSource(
			r.Context(),
			source,
			strings.TrimSpace(r.Header.Get(account.ClientAccountIDHeader)),
			strings.TrimSpace(r.Header.Get(account.ClientAccessKeyHeader)),
		)
		if errors.Is(err, account.ErrInvalidClientAuthorization) {
			writeAPIError(w, http.StatusUnauthorized, "client_unauthorized", "客户端授权已失效，请重新扫码登录")
			return
		}
		if err != nil {
			s.internalError(w, "校验客户端授权失败", err)
			return
		}
		ctx := context.WithValue(r.Context(), clientAccountContextKey{}, authorized)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// withPublicAPIAuthorization 根据运行时开关保护原本公开的业务接口。
// 开关关闭且没有携带授权头时允许匿名；携带授权头时仍会按平台校验。
// 开关开启时，即使请求未携带凭据也会返回 401。
func (s *Server) withPublicAPIAuthorization(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		source, ok := s.readMusicSource(w, r)
		if !ok {
			return
		}
		required := false
		if s.publicAuthPolicy != nil {
			var err error
			required, err = s.publicAuthPolicy.PublicAPIAuthRequired(r.Context())
			if err != nil {
				s.logger.Printf("读取公开接口鉴权开关失败: %v", err)
				writeAPIError(w, http.StatusServiceUnavailable, "authorization_policy_unavailable", "客户端鉴权策略暂不可用")
				return
			}
		}
		accountID := strings.TrimSpace(r.Header.Get(account.ClientAccountIDHeader))
		accessKey := strings.TrimSpace(r.Header.Get(account.ClientAccessKeyHeader))
		if accountID == "" && accessKey == "" && !required {
			next.ServeHTTP(w, r)
			return
		}
		if s.accounts == nil {
			writeAPIError(w, http.StatusServiceUnavailable, "authorization_unavailable", "客户端授权服务暂不可用")
			return
		}
		if accountID == "" || accessKey == "" {
			writeAPIError(w, http.StatusUnauthorized, "client_unauthorized", "客户端授权已失效，请重新扫码登录")
			return
		}
		authorized, err := s.accounts.AuthorizeSource(r.Context(), source, accountID, accessKey)
		if errors.Is(err, account.ErrInvalidClientAuthorization) {
			writeAPIError(w, http.StatusUnauthorized, "client_unauthorized", "客户端授权已失效，请重新扫码登录")
			return
		}
		if err != nil {
			s.internalError(w, "校验客户端授权失败", err)
			return
		}
		ctx := context.WithValue(r.Context(), clientAccountContextKey{}, authorized)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// AuthorizedClientAccount 返回当前请求经校验后的账号身份。
// 只有处理器由 requireClientAuthorization 包裹时，第二个返回值才为 true。
func AuthorizedClientAccount(ctx context.Context) (account.AuthorizedAccount, bool) {
	authorized, ok := ctx.Value(clientAccountContextKey{}).(account.AuthorizedAccount)
	return authorized, ok
}
