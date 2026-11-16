// Package adminapi exposes authenticated administration endpoints for the
// oo-music backend. Music API routes remain outside this package.
package adminapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/rankgice/oo-music/internal/account"
	"github.com/rankgice/oo-music/internal/admin"
	"github.com/rankgice/oo-music/internal/netease"
	"github.com/rankgice/oo-music/internal/qqlogin"
)

const maxJSONBodyBytes = 1 << 20

var (
	errUnauthorized = errors.New("管理登录会话无效")
)

// AccountManager 是后台管理接口需要的最小账号池能力。
type AccountManager interface {
	ListBoundAccounts(context.Context) ([]account.PublicAccount, error)
	Upsert(context.Context, string, string) (account.Account, error)
	UpsertNetease(context.Context, string, string, *time.Time, string, string) (account.Account, error)
	CreateManualAccount(context.Context, account.AccountType, string, string) (account.PublicAccount, string, error)
	UpdateAccountCredential(context.Context, int64, string) (account.PublicAccount, string, error)
	DeleteBoundAccount(context.Context, int64) error
	RefreshBoundAccount(context.Context, int64) (account.PublicAccount, error)
	RefreshProfile(context.Context, string) (account.Account, error)
}

// QRService 是扫码登录服务需要的最小能力。
type QRService interface {
	Start(context.Context) (qqlogin.StartResult, error)
	Get(string) (qqlogin.Session, error)
	Image(string) ([]byte, error)
	Poll(context.Context, string) (qqlogin.PollResult, error)
	Cancel(string) error
}

// NeteaseQRService 是网易云音乐扫码登录服务需要的最小能力。
type NeteaseQRService interface {
	Start(context.Context) (netease.QRStartResult, error)
	Get(string) (netease.QRSession, error)
	Image(string) ([]byte, error)
	Poll(context.Context, string) (netease.QRPollResult, error)
	Cancel(string) error
}

// Config 配置管理 API 的浏览器来源和服务信息。
type Config struct {
	// AllowedOrigins 是允许访问管理 API 的前端来源，默认允许本机 Vite 开发端口。
	AllowedOrigins []string
}

// Server 处理后台登录、管理员管理、绑定账号管理和扫码授权。
type Server struct {
	admins    *admin.Store
	auth      *admin.AuthService
	accounts  AccountManager
	qr        QRService
	neteaseQR NeteaseQRService
	logger    *log.Logger
	origins   map[string]struct{}

	qrKindsMu sync.Mutex
	qrKinds   map[string]account.AccountType
}

// NewHandler 创建管理 API。除登录外所有接口都要求 Bearer 登录令牌。
func NewHandler(
	admins *admin.Store,
	auth *admin.AuthService,
	accounts AccountManager,
	qr QRService,
	neteaseQR NeteaseQRService,
	logger *log.Logger,
	config Config,
) (http.Handler, error) {
	if admins == nil || auth == nil || accounts == nil || qr == nil || neteaseQR == nil {
		return nil, errors.New("管理 API 需要管理员数据库、认证服务、账号池和扫码服务")
	}
	if logger == nil {
		logger = log.Default()
	}
	origins := make(map[string]struct{})
	allowedOrigins := config.AllowedOrigins
	if len(allowedOrigins) == 0 {
		allowedOrigins = []string{"http://127.0.0.1:5173", "http://localhost:5173"}
	}
	for _, origin := range allowedOrigins {
		origin = strings.TrimRight(strings.TrimSpace(origin), "/")
		if origin != "" {
			origins[origin] = struct{}{}
		}
	}
	server := &Server{
		admins:    admins,
		auth:      auth,
		accounts:  accounts,
		qr:        qr,
		neteaseQR: neteaseQR,
		logger:    logger,
		origins:   origins,
		qrKinds:   make(map[string]account.AccountType),
	}

	root := http.NewServeMux()
	root.HandleFunc("POST /api/admin/login", server.handleLogin)
	protected := http.NewServeMux()
	protected.HandleFunc("POST /api/admin/logout", server.handleLogout)
	protected.HandleFunc("GET /api/admin/me", server.handleMe)
	protected.HandleFunc("GET /api/admin/users", server.handleListUsers)
	protected.HandleFunc("POST /api/admin/users", server.handleCreateUser)
	protected.HandleFunc("DELETE /api/admin/users/{id}", server.handleDeleteUser)
	protected.HandleFunc("GET /api/admin/settings/public-api-auth", server.handleGetPublicAPIAuth)
	protected.HandleFunc("PUT /api/admin/settings/public-api-auth", server.handleUpdatePublicAPIAuth)
	protected.HandleFunc("GET /api/admin/accounts", server.handleListAccounts)
	protected.HandleFunc("POST /api/admin/accounts", server.handleCreateAccount)
	protected.HandleFunc("PATCH /api/admin/accounts/{id}/credential", server.handleUpdateCredential)
	protected.HandleFunc("POST /api/admin/accounts/{id}/refresh", server.handleRefreshAccount)
	protected.HandleFunc("DELETE /api/admin/accounts/{id}", server.handleDeleteAccount)
	protected.HandleFunc("POST /api/admin/qr-sessions", server.handleStartQR)
	protected.HandleFunc("GET /api/admin/qr-sessions/{id}", server.handlePollQR)
	protected.HandleFunc("GET /api/admin/qr-sessions/{id}/image", server.handleQRImage)
	protected.HandleFunc("DELETE /api/admin/qr-sessions/{id}", server.handleCancelQR)
	root.Handle("/api/admin/", server.requireAuth(protected))

	return server.withCORS(server.withNoStore(server.withLogging(root))), nil
}

type requestSessionKey struct{}

type loginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type loginResponse struct {
	Token     string     `json:"token"`
	ExpiresAt time.Time  `json:"expiresAt"`
	User      admin.User `json:"user"`
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var request loginRequest
	if err := decodeJSON(w, r, &request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	session, err := s.auth.Login(r.Context(), request.Username, request.Password)
	if errors.Is(err, admin.ErrInvalidCredentials) {
		writeError(w, http.StatusUnauthorized, "invalid_credentials", "用户名或密码错误")
		return
	}
	if err != nil {
		s.logger.Printf("后台管理员登录失败: %v", err)
		writeError(w, http.StatusInternalServerError, "login_failed", "登录失败，请稍后重试")
		return
	}
	writeJSON(w, http.StatusOK, loginResponse{Token: session.Token, ExpiresAt: session.ExpiresAt, User: session.User})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	session := currentSession(r)
	s.auth.Logout(session.Token)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	session := currentSession(r)
	writeJSON(w, http.StatusOK, map[string]any{"user": session.User, "expiresAt": session.ExpiresAt})
}

func (s *Server) handleListUsers(w http.ResponseWriter, r *http.Request) {
	users, err := s.admins.ListUsers(r.Context())
	if err != nil {
		s.internalError(w, "查询后台管理员失败", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": users})
}

type createUserRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

func (s *Server) handleCreateUser(w http.ResponseWriter, r *http.Request) {
	var request createUserRequest
	if err := decodeJSON(w, r, &request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	hash, err := admin.HashPassword(request.Password)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_password", err.Error())
		return
	}
	user, err := s.admins.CreateUser(r.Context(), request.Username, hash)
	if errors.Is(err, admin.ErrUsernameExists) {
		writeError(w, http.StatusConflict, "username_exists", "后台管理员用户名已存在")
		return
	}
	if err != nil {
		if strings.Contains(err.Error(), "用户名") {
			writeError(w, http.StatusBadRequest, "invalid_username", err.Error())
			return
		}
		s.internalError(w, "创建后台管理员失败", err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"user": user})
}

func (s *Server) handleDeleteUser(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_id", "后台管理员 ID 不合法")
		return
	}
	session := currentSession(r)
	if id == session.User.ID {
		writeError(w, http.StatusConflict, "cannot_delete_self", "不能删除当前登录的后台管理员")
		return
	}
	if err := s.admins.DeleteUserIfNotLast(r.Context(), id); errors.Is(err, admin.ErrLastAdmin) {
		writeError(w, http.StatusConflict, "last_admin", "至少需要保留一个后台管理员")
		return
	} else if errors.Is(err, admin.ErrUserNotFound) {
		writeError(w, http.StatusNotFound, "user_not_found", "后台管理员不存在")
		return
	} else if err != nil {
		s.internalError(w, "删除后台管理员失败", err)
		return
	}
	s.auth.RevokeUserSessions(id)
	w.WriteHeader(http.StatusNoContent)
}

type publicAPIAuthSettingResponse struct {
	Required bool `json:"required"`
}

type updatePublicAPIAuthRequest struct {
	Required *bool `json:"required"`
}

func (s *Server) handleGetPublicAPIAuth(w http.ResponseWriter, r *http.Request) {
	required, err := s.admins.PublicAPIAuthRequired(r.Context())
	if err != nil {
		s.internalError(w, "读取公开接口鉴权开关失败", err)
		return
	}
	writeJSON(w, http.StatusOK, publicAPIAuthSettingResponse{Required: required})
}

func (s *Server) handleUpdatePublicAPIAuth(w http.ResponseWriter, r *http.Request) {
	var request updatePublicAPIAuthRequest
	if err := decodeJSON(w, r, &request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	if request.Required == nil {
		writeError(w, http.StatusBadRequest, "required_missing", "required 字段不能为空")
		return
	}
	if err := s.admins.SetPublicAPIAuthRequired(r.Context(), *request.Required); err != nil {
		s.internalError(w, "更新公开接口鉴权开关失败", err)
		return
	}
	writeJSON(w, http.StatusOK, publicAPIAuthSettingResponse{Required: *request.Required})
}

func (s *Server) handleListAccounts(w http.ResponseWriter, r *http.Request) {
	items, err := s.accounts.ListBoundAccounts(r.Context())
	if err != nil {
		s.internalError(w, "查询绑定账号失败", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

type createAccountRequest struct {
	AccountType string `json:"accountType"`
	UID         string `json:"uid"`
	Credential  string `json:"credential"`
}

func (s *Server) handleCreateAccount(w http.ResponseWriter, r *http.Request) {
	var request createAccountRequest
	if err := decodeJSON(w, r, &request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	accountType, err := parseAccountType(request.AccountType)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_account_type", err.Error())
		return
	}
	if strings.TrimSpace(request.Credential) == "" {
		writeError(w, http.StatusBadRequest, "credential_missing", "账号凭据不能为空")
		return
	}
	item, warning, err := s.accounts.CreateManualAccount(r.Context(), accountType, request.UID, request.Credential)
	if err != nil {
		if isCredentialError(err) {
			writeError(w, http.StatusBadRequest, "invalid_credential", err.Error())
			return
		}
		s.internalError(w, "手动添加绑定账号失败", err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"account": item, "warning": warning})
}

type updateCredentialRequest struct {
	Credential string `json:"credential"`
}

func (s *Server) handleUpdateCredential(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_id", "绑定账号 ID 不合法")
		return
	}
	var request updateCredentialRequest
	if err := decodeJSON(w, r, &request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	item, warning, err := s.accounts.UpdateAccountCredential(r.Context(), id, request.Credential)
	if errors.Is(err, account.ErrNoAccount) {
		writeError(w, http.StatusNotFound, "account_not_found", "绑定账号不存在")
		return
	}
	if err != nil {
		if isCredentialError(err) {
			writeError(w, http.StatusBadRequest, "invalid_credential", err.Error())
			return
		}
		s.internalError(w, "更新绑定账号凭据失败", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"account": item, "warning": warning})
}

func parseAccountType(raw string) (account.AccountType, error) {
	accountType := account.AccountType(strings.TrimSpace(raw))
	if !accountType.Valid() {
		return "", errors.New("accountType 必须明确指定 qq 或 netease")
	}
	return accountType, nil
}

func isCredentialError(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, netease.ErrUnauthorized) || errors.Is(err, netease.ErrUIDMismatch) {
		return true
	}
	message := strings.ToLower(err.Error())
	return strings.Contains(message, "qm_keyst") ||
		strings.Contains(message, "cookie") ||
		strings.Contains(message, "uin") ||
		strings.Contains(message, "凭据") ||
		strings.Contains(message, "账号 id")
}

func (s *Server) handleRefreshAccount(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_id", "绑定账号 ID 不合法")
		return
	}
	item, err := s.accounts.RefreshBoundAccount(r.Context(), id)
	if errors.Is(err, account.ErrNoAccount) {
		writeError(w, http.StatusNotFound, "account_not_found", "绑定账号不存在")
		return
	}
	if errors.Is(err, account.ErrAccountLoginExpired) {
		writeJSON(w, http.StatusOK, map[string]any{"account": item, "warning": "账号登录态已失效，请重新授权"})
		return
	}
	if err != nil {
		s.logger.Printf("刷新绑定账号 %d 失败: %v", id, err)
		warning := "账号信息已返回，但本次登录态检查失败"
		if strings.Contains(err.Error(), "会员") {
			warning = "登录态已检测，但本次会员状态刷新失败"
		}
		writeJSON(w, http.StatusOK, map[string]any{"account": item, "warning": warning})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"account": item})
}

func (s *Server) handleDeleteAccount(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_id", "绑定账号 ID 不合法")
		return
	}
	if err := s.accounts.DeleteBoundAccount(r.Context(), id); errors.Is(err, account.ErrNoAccount) {
		writeError(w, http.StatusNotFound, "account_not_found", "绑定账号不存在")
		return
	} else if err != nil {
		s.internalError(w, "删除绑定账号失败", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleStartQR(w http.ResponseWriter, r *http.Request) {
	accountType, err := parseAccountType(r.URL.Query().Get("type"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_account_type", err.Error())
		return
	}
	if accountType == account.AccountTypeNetease {
		result, startErr := s.neteaseQR.Start(r.Context())
		if startErr != nil {
			s.logger.Printf("创建网易云扫码会话失败: %v", startErr)
			writeError(w, http.StatusBadGateway, "qr_start_failed", "获取网易云音乐登录二维码失败")
			return
		}
		s.rememberQRSession(result.ID, accountType)
		writeQRStart(w, result.ID, string(result.Status), result.Message, result.ExpiresAt)
		return
	}

	result, err := s.qr.Start(r.Context())
	if errors.Is(err, qqlogin.ErrTooManySessions) {
		writeError(w, http.StatusTooManyRequests, "too_many_qr_sessions", "待处理扫码会话过多，请稍后重试")
		return
	}
	if err != nil {
		s.logger.Printf("创建 QQ 扫码会话失败: %v", err)
		writeError(w, http.StatusBadGateway, "qr_start_failed", "获取 QQ 登录二维码失败")
		return
	}
	s.rememberQRSession(result.ID, accountType)
	writeQRStart(w, result.ID, string(result.Status), result.Message, result.ExpiresAt)
}

func (s *Server) handlePollQR(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimSpace(r.PathValue("id"))
	accountType, ok := s.qrSessionType(id)
	if !ok {
		writeError(w, http.StatusNotFound, "qr_session_not_found", "扫码会话不存在或已过期")
		return
	}
	if accountType == account.AccountTypeNetease {
		s.pollNeteaseQR(w, r, id)
		return
	}
	result, err := s.qr.Poll(r.Context(), id)
	if errors.Is(err, qqlogin.ErrSessionNotFound) {
		writeError(w, http.StatusNotFound, "qr_session_not_found", "扫码会话不存在或已过期")
		return
	}
	if err != nil && !errors.Is(err, qqlogin.ErrQRExchange) {
		s.logger.Printf("轮询 QQ 扫码会话失败: %v", err)
		writeError(w, http.StatusBadGateway, "qr_poll_failed", "查询扫码状态失败")
		return
	}
	response := map[string]any{
		"sessionId": result.ID,
		"status":    result.Status,
		"message":   result.Message,
		"expiresAt": result.ExpiresAt,
		"imageUrl":  "/qr-sessions/" + id + "/image",
	}
	if result.Status == qqlogin.StatusCompleted && result.QMKeyst != "" {
		saved, saveErr := s.accounts.Upsert(r.Context(), result.UIN, result.QMKeyst)
		if saveErr != nil {
			s.logger.Printf("保存扫码账号失败: %v", saveErr)
			writeError(w, http.StatusInternalServerError, "account_save_failed", "扫码成功，但保存绑定账号失败")
			return
		}
		// 资料查询失败不能阻断后台绑定；账号仍会立即出现在账户列表中。
		if profile, profileErr := s.accounts.RefreshProfile(r.Context(), saved.AccountID); profileErr == nil {
			saved = profile
		} else {
			s.logger.Printf("刷新后台扫码账号资料失败: %v", profileErr)
		}
		public := saved.Public()
		response["account"] = public
	}
	writeJSON(w, http.StatusOK, response)
}

func (s *Server) pollNeteaseQR(w http.ResponseWriter, r *http.Request, id string) {
	result, err := s.neteaseQR.Poll(r.Context(), id)
	if errors.Is(err, netease.ErrQRSessionNotFound) {
		writeError(w, http.StatusNotFound, "qr_session_not_found", "扫码会话不存在或已过期")
		return
	}
	if err != nil {
		s.logger.Printf("轮询网易云扫码会话失败: %v", err)
		writeError(w, http.StatusBadGateway, "qr_poll_failed", "查询网易云音乐扫码状态失败")
		return
	}
	response := map[string]any{
		"sessionId": result.ID,
		"status":    result.Status,
		"message":   result.Message,
		"expiresAt": result.ExpiresAt,
		"imageUrl":  "/qr-sessions/" + id + "/image",
	}
	if result.Status == netease.QRStatusCompleted && result.UID > 0 && result.Cookie != "" {
		saved, saveErr := s.accounts.UpsertNetease(
			r.Context(), fmt.Sprintf("%d", result.UID), result.Cookie,
			result.AuthExpiresAt, result.Nickname, result.AvatarURL,
		)
		if saveErr != nil {
			s.logger.Printf("保存网易云扫码账号失败: %v", saveErr)
			writeError(w, http.StatusInternalServerError, "account_save_failed", "扫码成功，但保存绑定账号失败")
			return
		}
		response["account"] = saved.Public()
	}
	writeJSON(w, http.StatusOK, response)
}

func (s *Server) handleQRImage(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimSpace(r.PathValue("id"))
	accountType, ok := s.qrSessionType(id)
	if !ok {
		writeError(w, http.StatusNotFound, "qr_session_not_found", "扫码会话不存在或已过期")
		return
	}
	var (
		image []byte
		err   error
	)
	if accountType == account.AccountTypeNetease {
		image, err = s.neteaseQR.Image(id)
		if errors.Is(err, netease.ErrQRSessionNotFound) {
			writeError(w, http.StatusNotFound, "qr_session_not_found", "扫码会话不存在或已过期")
			return
		}
	} else {
		image, err = s.qr.Image(id)
	}
	if errors.Is(err, qqlogin.ErrSessionNotFound) {
		writeError(w, http.StatusNotFound, "qr_session_not_found", "扫码会话不存在或已过期")
		return
	}
	if err != nil {
		s.logger.Printf("读取扫码二维码失败: %v", err)
		writeError(w, http.StatusInternalServerError, "qr_image_failed", "读取二维码失败")
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Content-Length", strconv.Itoa(len(image)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(image)
}

func (s *Server) handleCancelQR(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimSpace(r.PathValue("id"))
	accountType, ok := s.qrSessionType(id)
	if !ok {
		writeError(w, http.StatusNotFound, "qr_session_not_found", "扫码会话不存在或已过期")
		return
	}
	var err error
	if accountType == account.AccountTypeNetease {
		err = s.neteaseQR.Cancel(id)
	} else {
		err = s.qr.Cancel(id)
	}
	s.forgetQRSession(id)
	if errors.Is(err, qqlogin.ErrSessionNotFound) || errors.Is(err, netease.ErrQRSessionNotFound) {
		writeError(w, http.StatusNotFound, "qr_session_not_found", "扫码会话不存在或已过期")
		return
	} else if err != nil {
		s.internalError(w, "取消扫码会话失败", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func writeQRStart(w http.ResponseWriter, id, status, message string, expiresAt time.Time) {
	writeJSON(w, http.StatusCreated, map[string]any{
		"sessionId": id,
		"status":    status,
		"message":   message,
		"expiresAt": expiresAt,
		"imageUrl":  "/qr-sessions/" + id + "/image",
	})
}

func (s *Server) rememberQRSession(id string, accountType account.AccountType) {
	s.qrKindsMu.Lock()
	defer s.qrKindsMu.Unlock()
	s.qrKinds[id] = accountType
}

func (s *Server) qrSessionType(id string) (account.AccountType, bool) {
	s.qrKindsMu.Lock()
	defer s.qrKindsMu.Unlock()
	accountType, ok := s.qrKinds[id]
	return accountType, ok
}

func (s *Server) forgetQRSession(id string) {
	s.qrKindsMu.Lock()
	defer s.qrKindsMu.Unlock()
	delete(s.qrKinds, id)
}

func (s *Server) requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, ok := bearerToken(r.Header.Get("Authorization"))
		if !ok {
			writeError(w, http.StatusUnauthorized, "unauthorized", "请先登录管理后台")
			return
		}
		session, err := s.auth.Authenticate(token)
		if err != nil {
			writeError(w, http.StatusUnauthorized, "unauthorized", "管理登录已失效，请重新登录")
			return
		}
		ctx := context.WithValue(r.Context(), requestSessionKey{}, session)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func currentSession(r *http.Request) admin.Session {
	session, _ := r.Context().Value(requestSessionKey{}).(admin.Session)
	return session
}

func bearerToken(header string) (string, bool) {
	parts := strings.Fields(strings.TrimSpace(header))
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") || parts[1] == "" {
		return "", false
	}
	return parts[1], true
}

func decodeJSON(w http.ResponseWriter, r *http.Request, target any) error {
	if contentType := strings.ToLower(strings.TrimSpace(r.Header.Get("Content-Type"))); contentType != "" && !strings.HasPrefix(contentType, "application/json") {
		return errors.New("请求 Content-Type 必须是 application/json")
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxJSONBodyBytes)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		if errors.Is(err, io.EOF) {
			return errors.New("请求体不能为空")
		}
		return errors.New("请求 JSON 不合法")
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return errors.New("请求体只能包含一个 JSON 对象")
	}
	return nil
}

func pathID(r *http.Request) (int64, error) {
	id, err := strconv.ParseInt(strings.TrimSpace(r.PathValue("id")), 10, 64)
	if err != nil || id <= 0 {
		return 0, errors.New("invalid positive id")
	}
	return id, nil
}

type apiError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type errorResponse struct {
	Error apiError `json:"error"`
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		http.Error(w, "encode response", http.StatusInternalServerError)
	}
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, errorResponse{Error: apiError{Code: code, Message: message}})
}

func (s *Server) internalError(w http.ResponseWriter, message string, err error) {
	s.logger.Printf("%s: %v", message, err)
	writeError(w, http.StatusInternalServerError, "internal_error", "服务内部错误")
}

func (s *Server) withNoStore(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Pragma", "no-cache")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}

func (s *Server) withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := strings.TrimRight(strings.TrimSpace(r.Header.Get("Origin")), "/")
		if _, allowed := s.origins[origin]; allowed && origin != "" {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
			w.Header().Set("Access-Control-Max-Age", "600")
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) withLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		next.ServeHTTP(w, r)
		s.logger.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(started).Round(time.Millisecond))
	})
}
