package netease

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/url"
	"strings"
	"sync"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

const (
	defaultQRTTL      = 5 * time.Minute
	maxQRSessions     = 100
	defaultQRCodeSize = 384
)

var ErrQRSessionNotFound = errors.New("网易云扫码会话不存在或已过期")

// QRStatus 是网易云扫码会话的稳定状态。
type QRStatus string

const (
	QRStatusWaiting   QRStatus = "waiting"
	QRStatusScanned   QRStatus = "scanned"
	QRStatusCompleted QRStatus = "completed"
	QRStatusExpired   QRStatus = "expired"
	QRStatusRejected  QRStatus = "rejected"
	QRStatusCanceled  QRStatus = "canceled"
	QRStatusError     QRStatus = "error"
)

// QRSession 是可安全返回给管理接口的扫码会话视图。
type QRSession struct {
	ID        string    `json:"id"`
	Status    QRStatus  `json:"status"`
	Message   string    `json:"message"`
	ExpiresAt time.Time `json:"expiresAt"`
}

// QRStartResult 包含二维码图片。
type QRStartResult struct {
	QRSession
	ImagePNG []byte `json:"-"`
}

// QRPollResult 是后端内部扫码轮询结果。
type QRPollResult struct {
	QRSession
	UID           int64      `json:"-"`
	Nickname      string     `json:"-"`
	AvatarURL     string     `json:"-"`
	Cookie        string     `json:"-"`
	AuthExpiresAt *time.Time `json:"-"`
}

type qrLoginSession struct {
	mu            sync.Mutex
	id            string
	status        QRStatus
	message       string
	imagePNG      []byte
	key           string
	cookies       map[string]string
	expiresAt     time.Time
	uid           int64
	nickname      string
	avatarURL     string
	cookie        string
	authExpiresAt *time.Time
}

// QRService 管理网易云二维码登录会话。中间 Cookie 只保存在内存中。
type QRService struct {
	client *Client
	logger *log.Logger
	now    func() time.Time
	ttl    time.Duration

	mu       sync.Mutex
	sessions map[string]*qrLoginSession
}

// QROption 配置扫码登录服务。
type QROption func(*QRService) error

// WithQRTTL 设置二维码会话有效期。
func WithQRTTL(ttl time.Duration) QROption {
	return func(service *QRService) error {
		if ttl <= 0 {
			return errors.New("扫码会话有效期必须大于零")
		}
		service.ttl = ttl
		return nil
	}
}

// NewQRService 创建网易云扫码登录服务。
func NewQRService(client *Client, logger *log.Logger, options ...QROption) (*QRService, error) {
	if client == nil {
		return nil, errors.New("网易云客户端不能为空")
	}
	if logger == nil {
		logger = log.Default()
	}
	service := &QRService{
		client:   client,
		logger:   logger,
		now:      time.Now,
		ttl:      defaultQRTTL,
		sessions: make(map[string]*qrLoginSession),
	}
	for _, option := range options {
		if option == nil {
			continue
		}
		if err := option(service); err != nil {
			return nil, err
		}
	}
	return service, nil
}

// Start 创建网易云二维码登录会话。
func (s *QRService) Start(ctx context.Context) (QRStartResult, error) {
	s.cleanup()
	s.mu.Lock()
	active := 0
	for _, session := range s.sessions {
		session.mu.Lock()
		if session.status == QRStatusWaiting || session.status == QRStatusScanned {
			active++
		}
		session.mu.Unlock()
	}
	s.mu.Unlock()
	if active >= maxQRSessions {
		return QRStartResult{}, fmt.Errorf("待处理网易云扫码会话过多")
	}

	cookies, err := s.client.normalizedCookies("")
	if err != nil {
		return QRStartResult{}, err
	}
	result, err := s.client.doWeapi(ctx, "/api/login/qrcode/unikey", map[string]any{"type": 3}, cookies)
	if err != nil {
		return QRStartResult{}, err
	}
	if result.Code != 200 {
		return QRStartResult{}, fmt.Errorf("生成网易云二维码失败，业务码 %d: %s", result.Code, result.Message)
	}
	var body struct {
		UniKey string `json:"unikey"`
	}
	if err := json.Unmarshal(result.Raw, &body); err != nil {
		return QRStartResult{}, fmt.Errorf("解析网易云二维码响应: %w", err)
	}
	if strings.TrimSpace(body.UniKey) == "" {
		return QRStartResult{}, errors.New("网易云二维码响应缺少 unikey")
	}
	qrURL := "https://music.163.com/login?codekey=" + url.QueryEscape(body.UniKey)
	imagePNG, err := qrcode.Encode(qrURL, qrcode.Medium, defaultQRCodeSize)
	if err != nil {
		return QRStartResult{}, fmt.Errorf("生成网易云二维码图片: %w", err)
	}
	id, err := qrSessionID()
	if err != nil {
		return QRStartResult{}, err
	}
	now := s.now().UTC()
	session := &qrLoginSession{
		id:        id,
		status:    QRStatusWaiting,
		message:   "请使用网易云音乐 App 扫码",
		imagePNG:  imagePNG,
		key:       body.UniKey,
		cookies:   cookies,
		expiresAt: now.Add(s.ttl),
	}
	s.mu.Lock()
	s.sessions[id] = session
	s.mu.Unlock()
	return QRStartResult{QRSession: session.public(), ImagePNG: append([]byte(nil), imagePNG...)}, nil
}

// Poll 轮询网易云扫码状态；成功后返回账号和 Cookie 供账号池保存。
func (s *QRService) Poll(ctx context.Context, id string) (QRPollResult, error) {
	session, err := s.lookup(id)
	if err != nil {
		return QRPollResult{}, err
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	if s.expiredLocked(session) {
		return QRPollResult{}, ErrQRSessionNotFound
	}
	result, err := s.client.doWeapi(ctx, "/api/login/qrcode/client/login", map[string]any{
		"key":  session.key,
		"type": 3,
	}, session.cookies)
	if err != nil {
		return QRPollResult{QRSession: session.public()}, err
	}
	session.cookies = parseCookieHeader(result.Cookie)
	switch result.Code {
	case 800:
		session.status = QRStatusExpired
		session.message = "二维码已过期，请重新获取"
	case 801:
		session.status = QRStatusWaiting
		session.message = "等待使用网易云音乐 App 扫码"
	case 802:
		session.status = QRStatusScanned
		session.message = "已扫码，请在手机上确认"
	case 803:
		state, checkErr := s.client.Check(ctx, result.Cookie, "")
		if checkErr != nil {
			session.status = QRStatusError
			session.message = "扫码成功，但校验网易云登录态失败"
			return QRPollResult{QRSession: session.public()}, checkErr
		}
		session.status = QRStatusCompleted
		session.message = "网易云音乐授权成功"
		session.uid = state.UID
		session.nickname = state.Nickname
		session.avatarURL = state.AvatarURL
		session.cookie = state.Cookie
		session.authExpiresAt = state.ExpiresAt
	default:
		session.status = QRStatusRejected
		session.message = fmt.Sprintf("网易云扫码登录失败（%d）", result.Code)
	}
	return QRPollResult{
		QRSession:     session.public(),
		UID:           session.uid,
		Nickname:      session.nickname,
		AvatarURL:     session.avatarURL,
		Cookie:        session.cookie,
		AuthExpiresAt: cloneTime(session.authExpiresAt),
	}, nil
}

// Get 返回扫码会话当前状态，不主动请求网易云接口。
func (s *QRService) Get(id string) (QRSession, error) {
	session, err := s.lookup(id)
	if err != nil {
		return QRSession{}, err
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	if s.expiredLocked(session) {
		return QRSession{}, ErrQRSessionNotFound
	}
	return session.public(), nil
}

// Image 返回二维码 PNG。
func (s *QRService) Image(id string) ([]byte, error) {
	session, err := s.lookup(id)
	if err != nil {
		return nil, err
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	if s.expiredLocked(session) {
		return nil, ErrQRSessionNotFound
	}
	return append([]byte(nil), session.imagePNG...), nil
}

// Cancel 取消扫码会话。
func (s *QRService) Cancel(id string) error {
	s.mu.Lock()
	session, ok := s.sessions[id]
	if ok {
		delete(s.sessions, id)
	}
	s.mu.Unlock()
	if !ok {
		return ErrQRSessionNotFound
	}
	session.mu.Lock()
	if !isTerminalQRStatus(session.status) {
		session.status = QRStatusCanceled
		session.message = "扫码会话已取消"
	}
	session.mu.Unlock()
	return nil
}

func (s *QRService) lookup(id string) (*qrLoginSession, error) {
	id = strings.TrimSpace(id)
	s.mu.Lock()
	session := s.sessions[id]
	s.mu.Unlock()
	if session == nil {
		return nil, ErrQRSessionNotFound
	}
	return session, nil
}

func (s *QRService) cleanup() {
	now := s.now().UTC()
	s.mu.Lock()
	for id, session := range s.sessions {
		session.mu.Lock()
		expired := now.After(session.expiresAt.Add(time.Minute)) || isTerminalQRStatus(session.status)
		session.mu.Unlock()
		if expired {
			delete(s.sessions, id)
		}
	}
	s.mu.Unlock()
}

func (s *QRService) expiredLocked(session *qrLoginSession) bool {
	return s.now().UTC().After(session.expiresAt)
}

func (s *qrLoginSession) public() QRSession {
	return QRSession{ID: s.id, Status: s.status, Message: s.message, ExpiresAt: s.expiresAt}
}

func isTerminalQRStatus(status QRStatus) bool {
	return status == QRStatusCompleted || status == QRStatusExpired || status == QRStatusRejected || status == QRStatusCanceled || status == QRStatusError
}

func qrSessionID() (string, error) {
	value := make([]byte, 18)
	if _, err := rand.Read(value); err != nil {
		return "", fmt.Errorf("生成网易云扫码会话标识: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}

func cloneTime(value *time.Time) *time.Time {
	if value == nil {
		return nil
	}
	copied := value.UTC()
	return &copied
}
