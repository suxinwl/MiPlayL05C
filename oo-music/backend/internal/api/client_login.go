package api

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"

	"github.com/rankgice/oo-music/internal/account"
	"github.com/rankgice/oo-music/internal/netease"
	"github.com/rankgice/oo-music/internal/qqlogin"
)

// QQLoginService 是客户端 QQ 扫码登录所需的二维码会话能力。
type QQLoginService interface {
	Start(context.Context) (qqlogin.StartResult, error)
	Poll(context.Context, string) (qqlogin.PollResult, error)
	Image(string) ([]byte, error)
	Cancel(string) error
}

func (s *Server) handleStartClientLogin(w http.ResponseWriter, r *http.Request) {
	source, ok := s.readMusicSource(w, r)
	if !ok {
		return
	}
	if source == account.AccountTypeQQ {
		if s.qqQR == nil {
			writeAPIError(w, http.StatusServiceUnavailable, "login_unavailable", "QQ 扫码登录服务暂不可用")
			return
		}
		result, err := s.qqQR.Start(r.Context())
		if errors.Is(err, qqlogin.ErrTooManySessions) {
			writeAPIError(w, http.StatusTooManyRequests, "too_many_qr_sessions", "待处理扫码会话过多，请稍后重试")
			return
		}
		if err != nil {
			s.logger.Printf("创建客户端 QQ 扫码会话失败: %v", err)
			writeAPIError(w, http.StatusBadGateway, "qr_start_failed", "获取 QQ 登录二维码失败")
			return
		}
		writeClientLoginStart(w, source, result.ID, string(result.Status), result.Message, result.ExpiresAt)
		return
	}
	if s.neteaseQR == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "login_unavailable", "网易云扫码登录服务暂不可用")
		return
	}
	result, err := s.neteaseQR.Start(r.Context())
	if err != nil {
		s.logger.Printf("创建客户端网易云扫码会话失败: %v", err)
		writeAPIError(w, http.StatusBadGateway, "qr_start_failed", "获取网易云音乐登录二维码失败")
		return
	}
	writeClientLoginStart(w, source, result.ID, string(result.Status), result.Message, result.ExpiresAt)
}

func writeClientLoginStart(
	w http.ResponseWriter,
	source account.AccountType,
	sessionID, status, message string,
	expiresAt any,
) {
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusCreated, map[string]any{
		"sessionId": sessionID,
		"source":    source,
		"status":    status,
		"message":   message,
		"expiresAt": expiresAt,
		"imageUrl":  clientLoginImageURL(source, sessionID),
	})
}

func (s *Server) handlePollClientLogin(w http.ResponseWriter, r *http.Request) {
	source, ok := s.readMusicSource(w, r)
	if !ok {
		return
	}
	sessionID := strings.TrimSpace(r.PathValue("id"))
	if source == account.AccountTypeQQ {
		s.pollQQClientLogin(w, r, sessionID)
		return
	}
	s.pollNeteaseClientLogin(w, r, sessionID)
}

func (s *Server) pollQQClientLogin(w http.ResponseWriter, r *http.Request, sessionID string) {
	if s.qqQR == nil || s.accounts == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "login_unavailable", "QQ 扫码登录服务暂不可用")
		return
	}
	result, err := s.qqQR.Poll(r.Context(), sessionID)
	if errors.Is(err, qqlogin.ErrSessionNotFound) {
		writeAPIError(w, http.StatusNotFound, "qr_session_not_found", "扫码会话不存在或已过期")
		return
	}
	if err != nil && !errors.Is(err, qqlogin.ErrQRExchange) {
		s.logger.Printf("轮询客户端 QQ 扫码会话失败: %v", err)
		writeAPIError(w, http.StatusBadGateway, "qr_poll_failed", "查询扫码状态失败")
		return
	}
	if result.ID == "" {
		result.ID = sessionID
	}
	response := clientLoginPollResponse(
		account.AccountTypeQQ,
		result.ID,
		string(result.Status),
		result.Message,
		result.ExpiresAt,
	)
	if result.Status == qqlogin.StatusCompleted {
		if strings.TrimSpace(result.UIN) == "" || strings.TrimSpace(result.QMKeyst) == "" {
			writeAPIError(w, http.StatusBadGateway, "account_save_failed", "扫码成功，但后端没有返回完整 QQ 授权信息")
			return
		}
		saved, saveErr := s.accounts.Upsert(r.Context(), result.UIN, result.QMKeyst)
		if saveErr != nil {
			s.logger.Printf("保存客户端 QQ 扫码账号失败: %v", saveErr)
			writeAPIError(w, http.StatusInternalServerError, "account_save_failed", "扫码成功，但保存 QQ 账号失败")
			return
		}
		if profile, profileErr := s.accounts.RefreshProfile(r.Context(), saved.AccountID); profileErr == nil {
			saved = profile
		} else {
			s.logger.Printf("刷新客户端 QQ 账号资料失败: %v", profileErr)
		}
		addClientLoginAccount(response, saved)
	}
	writeJSON(w, http.StatusOK, response)
}

func (s *Server) pollNeteaseClientLogin(w http.ResponseWriter, r *http.Request, sessionID string) {
	if s.neteaseQR == nil || s.accounts == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "login_unavailable", "网易云扫码登录服务暂不可用")
		return
	}
	result, err := s.neteaseQR.Poll(r.Context(), sessionID)
	if errors.Is(err, netease.ErrQRSessionNotFound) {
		writeAPIError(w, http.StatusNotFound, "qr_session_not_found", "扫码会话不存在或已过期")
		return
	}
	if err != nil {
		s.logger.Printf("轮询客户端网易云扫码会话失败: %v", err)
		writeAPIError(w, http.StatusBadGateway, "qr_poll_failed", "查询网易云扫码状态失败")
		return
	}
	if strings.TrimSpace(result.ID) == "" {
		result.ID = sessionID
	}
	response := clientLoginPollResponse(
		account.AccountTypeNetease,
		result.ID,
		string(result.Status),
		result.Message,
		result.ExpiresAt,
	)
	if result.Status == netease.QRStatusCompleted {
		if result.UID <= 0 || strings.TrimSpace(result.Cookie) == "" {
			writeAPIError(w, http.StatusBadGateway, "account_save_failed", "扫码成功，但后端没有返回完整网易云授权信息")
			return
		}
		saved, saveErr := s.accounts.UpsertNetease(
			r.Context(),
			strconv.FormatInt(result.UID, 10),
			result.Cookie,
			result.AuthExpiresAt,
			result.Nickname,
			result.AvatarURL,
		)
		if saveErr != nil {
			s.logger.Printf("保存客户端网易云扫码账号失败: %v", saveErr)
			writeAPIError(w, http.StatusInternalServerError, "account_save_failed", "扫码成功，但保存网易云账号失败")
			return
		}
		addClientLoginAccount(response, saved)
	}
	writeJSON(w, http.StatusOK, response)
}

func clientLoginPollResponse(
	source account.AccountType,
	sessionID, status, message string,
	expiresAt any,
) map[string]any {
	return map[string]any{
		"sessionId": sessionID,
		"source":    source,
		"status":    status,
		"message":   message,
		"expiresAt": expiresAt,
		"imageUrl":  clientLoginImageURL(source, sessionID),
	}
}

func addClientLoginAccount(response map[string]any, saved account.Account) {
	response["accountId"] = saved.AccountID
	response["accessKey"] = saved.AccessKey
	response["nickname"] = saved.Nickname
	response["avatarUrl"] = saved.AvatarURL
	response["account"] = saved.Public()
}

func clientLoginImageURL(source account.AccountType, sessionID string) string {
	return "/api/client/login/sessions/" + sessionID + "/image?source=" + string(source)
}

func (s *Server) handleClientLoginImage(w http.ResponseWriter, r *http.Request) {
	source, ok := s.readMusicSource(w, r)
	if !ok {
		return
	}
	sessionID := strings.TrimSpace(r.PathValue("id"))
	var (
		image []byte
		err   error
	)
	if source == account.AccountTypeQQ {
		if s.qqQR == nil {
			writeAPIError(w, http.StatusServiceUnavailable, "login_unavailable", "QQ 扫码登录服务暂不可用")
			return
		}
		image, err = s.qqQR.Image(sessionID)
	} else {
		if s.neteaseQR == nil {
			writeAPIError(w, http.StatusServiceUnavailable, "login_unavailable", "网易云扫码登录服务暂不可用")
			return
		}
		image, err = s.neteaseQR.Image(sessionID)
	}
	if errors.Is(err, qqlogin.ErrSessionNotFound) || errors.Is(err, netease.ErrQRSessionNotFound) {
		writeAPIError(w, http.StatusNotFound, "qr_session_not_found", "扫码会话不存在或已过期")
		return
	}
	if err != nil {
		s.logger.Printf("读取客户端登录二维码失败: %v", err)
		writeAPIError(w, http.StatusInternalServerError, "qr_image_failed", "读取二维码失败")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Content-Length", strconv.Itoa(len(image)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(image)
}

func (s *Server) handleCancelClientLogin(w http.ResponseWriter, r *http.Request) {
	source, ok := s.readMusicSource(w, r)
	if !ok {
		return
	}
	sessionID := strings.TrimSpace(r.PathValue("id"))
	var err error
	if source == account.AccountTypeQQ {
		if s.qqQR == nil {
			writeAPIError(w, http.StatusServiceUnavailable, "login_unavailable", "QQ 扫码登录服务暂不可用")
			return
		}
		err = s.qqQR.Cancel(sessionID)
	} else {
		if s.neteaseQR == nil {
			writeAPIError(w, http.StatusServiceUnavailable, "login_unavailable", "网易云扫码登录服务暂不可用")
			return
		}
		err = s.neteaseQR.Cancel(sessionID)
	}
	if errors.Is(err, qqlogin.ErrSessionNotFound) || errors.Is(err, netease.ErrQRSessionNotFound) {
		writeAPIError(w, http.StatusNotFound, "qr_session_not_found", "扫码会话不存在或已过期")
		return
	}
	if err != nil {
		s.internalError(w, "取消客户端扫码会话失败", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type clientAccountResponse struct {
	Source    account.AccountType `json:"source"`
	AccountID string              `json:"accountId"`
	Nickname  string              `json:"nickname"`
	AvatarURL string              `json:"avatarUrl"`
}

func (s *Server) handleClientAccount(w http.ResponseWriter, r *http.Request) {
	authorized, ok := AuthorizedClientAccount(r.Context())
	if !ok {
		writeAPIError(w, http.StatusUnauthorized, "client_unauthorized", "客户端授权已失效，请重新登录")
		return
	}
	response := clientAccountResponse{
		Source:    authorized.Type,
		AccountID: authorized.AccountID,
		Nickname:  authorized.Nickname,
		AvatarURL: authorized.AvatarURL,
	}
	if authorized.Type == account.AccountTypeQQ {
		profile, err := s.accounts.RefreshProfile(r.Context(), authorized.AccountID)
		switch {
		case err == nil:
			response.Nickname = profile.Nickname
			response.AvatarURL = profile.AvatarURL
		case errors.Is(err, account.ErrAccountLoginExpired):
			writeAPIError(w, http.StatusUnauthorized, "client_unauthorized", "客户端授权已失效，请重新登录")
			return
		default:
			s.logger.Printf("刷新客户端 QQ 账号资料失败: %v", err)
		}
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, response)
}
