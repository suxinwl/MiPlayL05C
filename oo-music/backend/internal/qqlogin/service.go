// Package qqlogin implements the QQ Music web QR authorization flow used by
// the administration console. Credentials produced by this package never leave
// the backend process.
package qqlogin

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"log"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	ptAppID           = "716027609"
	ptDaid            = "383"
	pt3rdAID          = "100497308"
	ptU1              = "https://graph.qq.com/oauth2.0/login_jump"
	authorizeRedirect = "https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https://y.qq.com/"

	defaultQRTTL        = 5 * time.Minute
	defaultHTTPTimeout  = 15 * time.Second
	maxBodyBytes        = 2 << 20
	maxActiveSessions   = 100
	maxCredentialLength = 4096
)

var (
	// ErrSessionNotFound 表示扫码会话不存在、已取消或已过期。
	ErrSessionNotFound = errors.New("扫码会话不存在或已过期")
	// ErrTooManySessions 表示短时间内创建的扫码会话过多。
	ErrTooManySessions = errors.New("待处理扫码会话过多，请稍后重试")
	// ErrQRExchange 表示腾讯登录链路已完成扫码，但未能换取音乐凭据。
	ErrQRExchange = errors.New("QQ 扫码登录换票失败")
)

// Status 是扫码会话的稳定状态。
type Status string

const (
	// StatusWaiting 表示等待手机扫码。
	StatusWaiting Status = "waiting"
	// StatusScanned 表示已扫码，等待手机确认。
	StatusScanned Status = "scanned"
	// StatusCompleted 表示已取得 QQ 音乐登录凭据并由后台保存。
	StatusCompleted Status = "completed"
	// StatusExpired 表示二维码已过期。
	StatusExpired Status = "expired"
	// StatusRejected 表示用户在手机上拒绝登录。
	StatusRejected Status = "rejected"
	// StatusCanceled 表示管理端主动取消。
	StatusCanceled Status = "canceled"
	// StatusError 表示扫码后换票失败。
	StatusError Status = "error"
)

// Session 是可安全返回给管理接口的扫码会话视图。
type Session struct {
	ID        string    `json:"id"`
	Status    Status    `json:"status"`
	Message   string    `json:"message"`
	ExpiresAt time.Time `json:"expiresAt"`
}

// StartResult 包含二维码图片和不透明会话标识。qrsig 等敏感数据不会返回。
type StartResult struct {
	Session
	// ImagePNG 只供已鉴权的管理接口读取，禁止直接序列化到 JSON。
	ImagePNG []byte `json:"-"`
}

// PollResult 是后端内部轮询结果。UIN 和 QMKeyst 只能交给账号池保存，
// 禁止直接序列化到管理 API。
type PollResult struct {
	Session
	// UIN 和 QMKeyst 是服务端内部凭据，序列化保护避免误返回给管理端。
	UIN     string `json:"-"`
	QMKeyst string `json:"-"`
}

type loginSession struct {
	mu        sync.Mutex
	id        string
	status    Status
	message   string
	imagePNG  []byte
	qrsig     string
	loginSig  string
	cookieJar *cookiejar.Jar
	ptqrtoken int64
	expiresAt time.Time
	uin       string
	qmKeyst   string
}

type endpoints struct {
	loginInit  string
	qrShow     string
	qrPoll     string
	musicLogin string
}

// Service 管理短生命周期的扫码会话。所有登录中间凭据仅保存在进程内存中。
type Service struct {
	httpClient *http.Client
	logger     *log.Logger
	now        func() time.Time
	ttl        time.Duration
	endpoints  endpoints

	mu       sync.Mutex
	sessions map[string]*loginSession
}

// Option 配置扫码登录服务，主要用于测试和自定义部署。
type Option func(*Service) error

// WithHTTPClient 使用指定的 HTTP 客户端。
func WithHTTPClient(client *http.Client) Option {
	return func(service *Service) error {
		if client == nil {
			return errors.New("HTTP 客户端不能为空")
		}
		service.httpClient = client
		return nil
	}
}

// WithSessionTTL 设置扫码会话的最长保留时间。
func WithSessionTTL(ttl time.Duration) Option {
	return func(service *Service) error {
		if ttl <= 0 {
			return errors.New("扫码会话有效期必须大于零")
		}
		service.ttl = ttl
		return nil
	}
}

// WithEndpoints 覆盖腾讯登录端点，只用于测试或兼容镜像环境。
func WithEndpoints(loginInit, qrShow, qrPoll, musicLogin string) Option {
	return func(service *Service) error {
		for name, raw := range map[string]string{
			"登录初始化": loginInit,
			"二维码生成": qrShow,
			"扫码轮询":  qrPoll,
			"音乐登录":  musicLogin,
		} {
			parsed, err := url.Parse(strings.TrimSpace(raw))
			if err != nil || parsed.Scheme == "" || parsed.Host == "" {
				return fmt.Errorf("%s端点不合法", name)
			}
		}
		service.endpoints = endpoints{
			loginInit: loginInit, qrShow: qrShow, qrPoll: qrPoll, musicLogin: musicLogin,
		}
		return nil
	}
}

// NewService 创建 QQ 扫码登录服务。
func NewService(logger *log.Logger, options ...Option) (*Service, error) {
	if logger == nil {
		logger = log.Default()
	}
	service := &Service{
		httpClient: &http.Client{Timeout: defaultHTTPTimeout},
		logger:     logger,
		now:        time.Now,
		ttl:        defaultQRTTL,
		endpoints: endpoints{
			loginInit:  "https://xui.ptlogin2.qq.com/cgi-bin/xlogin",
			qrShow:     "https://xui.ptlogin2.qq.com/ssl/ptqrshow",
			qrPoll:     "https://xui.ptlogin2.qq.com/ssl/ptqrlogin",
			musicLogin: "https://u.y.qq.com/cgi-bin/musicu.fcg",
		},
		sessions: make(map[string]*loginSession),
	}
	for _, option := range options {
		if option == nil {
			continue
		}
		if err := option(service); err != nil {
			return nil, fmt.Errorf("配置 QQ 扫码登录: %w", err)
		}
	}
	// QQ 登录链路会在多个 302 跳转中分批下发 skey、p_skey 等 Cookie。
	// 使用无 CookieJar 的 http.Client 自动跟随跳转时，中间响应的 Set-Cookie
	// 会丢失；exchange 已按跳转逐次合并 Cookie 并限制目标地址，因此这里必须
	// 关闭自动重定向，避免 p_skey 在中间响应中丢失。
	client := *service.httpClient
	client.CheckRedirect = func(_ *http.Request, _ []*http.Request) error {
		return http.ErrUseLastResponse
	}
	service.httpClient = &client
	return service, nil
}

// Start 创建一个新的二维码扫码会话。
func (s *Service) Start(ctx context.Context) (StartResult, error) {
	s.cleanup()
	s.mu.Lock()
	active := 0
	for _, session := range s.sessions {
		session.mu.Lock()
		if session.status == StatusWaiting || session.status == StatusScanned {
			active++
		}
		session.mu.Unlock()
	}
	s.mu.Unlock()
	if active >= maxActiveSessions {
		return StartResult{}, ErrTooManySessions
	}

	// 腾讯网页扫码不是直接从二维码开始：xlogin 会下发 pt_login_sig，
	// 后续 ptqrlogin 必须携带该值。缺少它时手机仍可扫码成功，但 check_sig
	// 不会下发有效的 p_skey，最终无法换取 QQ 音乐登录态。
	loginURL, err := url.Parse(s.endpoints.loginInit)
	if err != nil {
		return StartResult{}, errors.New("登录初始化端点不合法")
	}
	loginQuery := loginURL.Query()
	loginQuery.Set("appid", ptAppID)
	loginQuery.Set("daid", ptDaid)
	loginQuery.Set("style", "33")
	loginQuery.Set("hide_title_bar", "1")
	loginQuery.Set("hide_border", "1")
	loginQuery.Set("target", "self")
	loginQuery.Set("s_url", ptU1)
	loginQuery.Set("pt_3rd_aid", pt3rdAID)
	loginQuery.Set("theme", "2")
	loginURL.RawQuery = loginQuery.Encode()

	cookieJar, err := cookiejar.New(nil)
	if err != nil {
		return StartResult{}, errors.New("初始化 QQ 登录 Cookie 管理器失败")
	}
	response, err := s.doGetWithJar(ctx, loginURL.String(), cookieJar, "https://graph.qq.com/")
	if err != nil {
		return StartResult{}, fmt.Errorf("初始化 QQ 登录服务失败: %w", err)
	}
	storeResponseCookies(cookieJar, loginURL, response)
	_, _ = readLimited(response.Body)
	_ = response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return StartResult{}, fmt.Errorf("QQ 登录初始化服务返回 HTTP %d", response.StatusCode)
	}
	loginSig := firstNonEmpty(cookieValueForURL(cookieJar, loginURL, "pt_login_sig"), cookieValueForURL(cookieJar, loginURL, "login_sig"))
	if loginSig == "" {
		return StartResult{}, errors.New("QQ 登录初始化响应缺少 pt_login_sig")
	}

	requestURL, err := url.Parse(s.endpoints.qrShow)
	if err != nil {
		return StartResult{}, errors.New("二维码端点不合法")
	}
	query := requestURL.Query()
	query.Set("appid", ptAppID)
	query.Set("e", "2")
	query.Set("l", "M")
	query.Set("s", "3")
	query.Set("d", "72")
	query.Set("v", "4")
	query.Set("t", strconv.FormatFloat(float64(s.now().UnixNano())/1e9, 'f', -1, 64))
	query.Set("daid", ptDaid)
	query.Set("pt_3rd_aid", pt3rdAID)
	query.Set("u1", ptU1)
	requestURL.RawQuery = query.Encode()

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, requestURL.String(), nil)
	if err != nil {
		return StartResult{}, errors.New("创建二维码请求失败")
	}
	setQQBrowserHeaders(request)
	request.Header.Set("Cookie", cookieHeader(cookiesForURL(cookieJar, requestURL)))
	request.Header.Set("Accept", "image/avif,image/webp,image/apng,image/*,*/*;q=0.8")
	response, err = s.httpClient.Do(request)
	if err != nil {
		return StartResult{}, fmt.Errorf("请求 QQ 二维码服务失败: %w", err)
	}
	defer response.Body.Close()
	imagePNG, err := readLimited(response.Body)
	if err != nil {
		return StartResult{}, err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return StartResult{}, fmt.Errorf("QQ 二维码服务返回 HTTP %d", response.StatusCode)
	}
	if len(imagePNG) == 0 {
		return StartResult{}, errors.New("QQ 二维码服务返回空图片")
	}
	storeResponseCookies(cookieJar, requestURL, response)
	qrsig := cookieValueForURL(cookieJar, requestURL, "qrsig")
	if qrsig == "" {
		return StartResult{}, errors.New("QQ 二维码响应缺少 qrsig")
	}
	id, err := randomID()
	if err != nil {
		return StartResult{}, fmt.Errorf("生成扫码会话标识: %w", err)
	}
	now := s.now().UTC()
	session := &loginSession{
		id:        id,
		status:    StatusWaiting,
		message:   "请使用手机 QQ 扫码",
		imagePNG:  imagePNG,
		qrsig:     qrsig,
		loginSig:  loginSig,
		cookieJar: cookieJar,
		ptqrtoken: hash33(qrsig),
		expiresAt: now.Add(s.ttl),
	}
	s.mu.Lock()
	s.sessions[id] = session
	s.mu.Unlock()
	return StartResult{
		Session:  session.public(),
		ImagePNG: append([]byte(nil), imagePNG...),
	}, nil
}

// Get 返回会话当前状态，不触发腾讯接口轮询。
func (s *Service) Get(id string) (Session, error) {
	session, err := s.lookup(id)
	if err != nil {
		return Session{}, err
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	if s.expiredLocked(session) {
		return Session{}, ErrSessionNotFound
	}
	return session.public(), nil
}

// Image 返回二维码 PNG。二维码图片只能通过已鉴权的管理接口读取。
func (s *Service) Image(id string) ([]byte, error) {
	session, err := s.lookup(id)
	if err != nil {
		return nil, err
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	if s.expiredLocked(session) {
		return nil, ErrSessionNotFound
	}
	return append([]byte(nil), session.imagePNG...), nil
}

// Poll 轮询一次二维码状态；扫码成功后会自动完成腾讯换票流程。
// 返回的 UIN、QMKeyst 仅供调用方写入服务端账号表。
func (s *Service) Poll(ctx context.Context, id string) (PollResult, error) {
	session, err := s.lookup(id)
	if err != nil {
		return PollResult{}, err
	}
	session.mu.Lock()
	defer session.mu.Unlock()

	if s.expiredLocked(session) {
		return PollResult{}, ErrSessionNotFound
	}
	switch session.status {
	case StatusCompleted, StatusExpired, StatusRejected, StatusCanceled, StatusError:
		return session.pollResult(), nil
	}

	requestURL, err := url.Parse(s.endpoints.qrPoll)
	if err != nil {
		return PollResult{}, errors.New("扫码轮询端点不合法")
	}
	query := requestURL.Query()
	query.Set("u1", ptU1)
	query.Set("ptqrtoken", strconv.FormatInt(session.ptqrtoken, 10))
	query.Set("ptredirect", "0")
	query.Set("h", "1")
	query.Set("t", "1")
	query.Set("g", "1")
	query.Set("from_ui", "1")
	query.Set("ptlang", "2052")
	query.Set("action", "0-0-"+strconv.FormatInt(s.now().UnixMilli(), 10))
	query.Set("js_ver", "26030415")
	query.Set("js_type", "1")
	query.Set("login_sig", session.loginSig)
	query.Set("pt_uistyle", "40")
	query.Set("aid", ptAppID)
	query.Set("daid", ptDaid)
	query.Set("pt_3rd_aid", pt3rdAID)
	requestURL.RawQuery = query.Encode()

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, requestURL.String(), nil)
	if err != nil {
		return PollResult{}, errors.New("创建扫码轮询请求失败")
	}
	setQQBrowserHeaders(request)
	request.Header.Set("Cookie", cookieHeader(cookiesForURL(session.cookieJar, requestURL)))
	request.Header.Set("Accept", "*/*")
	response, err := s.httpClient.Do(request)
	if err != nil {
		return PollResult{}, errors.New("请求 QQ 扫码轮询服务失败")
	}
	defer response.Body.Close()
	storeResponseCookies(session.cookieJar, requestURL, response)
	body, readErr := readLimited(response.Body)
	if readErr != nil {
		return PollResult{}, readErr
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return PollResult{}, fmt.Errorf("QQ 扫码轮询服务返回 HTTP %d", response.StatusCode)
	}

	code, _, checkURL, parseErr := parsePTUICB(string(body))
	if parseErr != nil {
		return PollResult{}, parseErr
	}
	switch code {
	case 65:
		session.status = StatusExpired
		session.message = "二维码已失效，请重新获取"
		return session.pollResult(), nil
	case 66:
		session.status = StatusWaiting
		session.message = "请使用手机 QQ 扫码"
		return session.pollResult(), nil
	case 67:
		session.status = StatusScanned
		session.message = "已扫码，请在手机 QQ 确认登录"
		return session.pollResult(), nil
	case 68:
		session.status = StatusRejected
		session.message = "手机端已拒绝登录"
		return session.pollResult(), nil
	case 0:
		if strings.TrimSpace(checkURL) == "" {
			session.status = StatusError
			session.message = "登录检查失败，请重新扫码"
			return session.pollResult(), ErrQRExchange
		}
	default:
		return PollResult{}, fmt.Errorf("QQ 扫码轮询返回未知状态码 %d", code)
	}

	uin, qmKeyst, err := s.exchange(ctx, unescapePTURL(checkURL), session.cookieJar)
	if err != nil {
		session.status = StatusError
		session.message = "扫码成功，但换取 QQ 音乐登录态失败，请重新扫码"
		s.logger.Printf("QQ 扫码换票失败: %v", err)
		return session.pollResult(), ErrQRExchange
	}
	session.uin = uin
	session.qmKeyst = qmKeyst
	session.status = StatusCompleted
	session.message = "登录成功，账号已绑定"
	return session.pollResult(), nil
}

// Cancel 取消扫码会话并使二维码失效。
func (s *Service) Cancel(id string) error {
	session, err := s.lookup(id)
	if err != nil {
		return err
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	session.status = StatusCanceled
	session.message = "扫码登录已取消"
	session.qrsig = ""
	session.qmKeyst = ""
	return nil
}

func (s *Service) exchange(ctx context.Context, checkURL string, cookieJar *cookiejar.Jar) (string, string, error) {
	parsedCheck, err := url.Parse(checkURL)
	if err != nil || (parsedCheck.Scheme != "https" && parsedCheck.Scheme != "http") || parsedCheck.Host == "" {
		return "", "", errors.New("登录检查地址不合法")
	}
	checkSigUIN := normalizeUIN(parsedCheck.Query().Get("uin"))
	checkSigSIGX := strings.TrimSpace(parsedCheck.Query().Get("ptsigx"))
	if checkSigUIN == "" || checkSigSIGX == "" {
		return "", "", errors.New("登录检查地址缺少 uin 或 ptsigx")
	}

	// 先按网页登录脚本的标准方式请求 check_sig，并且明确不携带任何 Cookie。
	// 这样腾讯会按登录票据重新签发 p_skey；把二维码阶段的全部 Cookie 混入
	// 反而会污染该接口的登录上下文，最终得到 pt_oauth_token 却没有 p_skey。
	checkSigURL := &url.URL{Scheme: "https", Host: "ssl.ptlogin2.graph.qq.com", Path: "/check_sig"}
	checkSigQuery := checkSigURL.Query()
	checkSigQuery.Set("uin", checkSigUIN)
	checkSigQuery.Set("pttype", "1")
	checkSigQuery.Set("service", "ptqrlogin")
	checkSigQuery.Set("nodirect", "0")
	checkSigQuery.Set("ptsigx", checkSigSIGX)
	checkSigQuery.Set("s_url", ptU1)
	checkSigQuery.Set("ptlang", "2052")
	checkSigQuery.Set("ptredirect", "100")
	checkSigQuery.Set("aid", ptAppID)
	checkSigQuery.Set("daid", ptDaid)
	checkSigQuery.Set("j_later", "0")
	checkSigQuery.Set("low_login_hour", "0")
	checkSigQuery.Set("regmaster", "0")
	checkSigQuery.Set("pt_login_type", "3")
	checkSigQuery.Set("pt_aid", "0")
	checkSigQuery.Set("pt_aaid", "16")
	checkSigQuery.Set("pt_light", "0")
	checkSigQuery.Set("pt_3rd_aid", pt3rdAID)
	checkSigURL.RawQuery = checkSigQuery.Encode()

	response, err := s.doGet(ctx, checkSigURL.String(), nil, "https://xui.ptlogin2.qq.com/")
	if err != nil {
		return "", "", errors.New("请求登录检查服务失败")
	}
	sigCookies := responseCookies(response)
	s.logLoginHop("check_sig_standard", checkSigURL, response)
	_, _ = readLimited(response.Body)
	_ = response.Body.Close()

	if cookieValue(sigCookies, "p_skey") == "" {
		// 少部分账号/风控环境要求浏览器式重试。此时只带上浏览器确实会发给
		// check_sig 主机的登录 Cookie，不能再把 xui.ptlogin2.qq.com 的
		// qrsig、pt_login_sig 等主机专属 Cookie 一并发送。
		retryCookies := cookiesForURL(cookieJar, parsedCheck)
		response, err = s.doGet(ctx, parsedCheck.String(), retryCookies, "https://xui.ptlogin2.qq.com/")
		if err != nil {
			return "", "", errors.New("重试登录检查服务失败")
		}
		sigCookies = responseCookies(response)
		s.logLoginHop("check_sig_browser_retry", parsedCheck, response)
		_, _ = readLimited(response.Body)
		_ = response.Body.Close()
	}
	pSkey := cookieValue(sigCookies, "p_skey")
	if pSkey == "" {
		return "", "", fmt.Errorf("登录检查未下发 p_skey（最终 HTTP %d，Cookie 名 %s）", response.StatusCode, strings.Join(cookieNames(sigCookies), ","))
	}
	gtk := gtkFromPSkey(pSkey)
	ui := strings.ToUpper(cookieValue(sigCookies, "ui"))
	if ui == "" {
		// 官方授权页在 ui Cookie 不存在时会生成一个随机 UUID，并同时写入 Cookie。
		ui = randomGUID()
	}

	form := url.Values{}
	form.Set("response_type", "code")
	form.Set("client_id", pt3rdAID)
	form.Set("redirect_uri", authorizeRedirect)
	form.Set("scope", "get_user_info,get_app_friends")
	form.Set("state", "state")
	form.Set("switch", "")
	form.Set("from_ptlogin", "1")
	form.Set("src", "1")
	form.Set("update_auth", "1")
	form.Set("openapi", "1010_1030")
	form.Set("g_tk", strconv.FormatInt(gtk, 10))
	form.Set("auth_time", strconv.FormatInt(s.now().UnixMilli(), 10))
	form.Set("ui", ui)

	authorizeURL := "https://graph.qq.com/oauth2.0/authorize"
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, authorizeURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", "", errors.New("创建 QQ 授权请求失败")
	}
	setQQBrowserHeaders(request)
	request.Header.Set("Cookie", cookieHeader(sigCookies))
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("Origin", "https://graph.qq.com")
	request.Header.Set("Referer", "https://graph.qq.com/")
	response, err = s.httpClient.Do(request)
	if err != nil {
		return "", "", errors.New("请求 QQ 授权服务失败")
	}
	mergeCookieMaps(sigCookies, responseCookies(response))
	location := response.Header.Get("Location")
	body, _ := readLimited(response.Body)
	_ = response.Body.Close()
	s.logger.Printf(
		"QQ OAuth authorize: HTTP %d 新Cookie=%s 有Location=%t 响应字节=%d 响应类型=%s",
		response.StatusCode,
		strings.Join(cookieNames(responseCookies(response)), ","),
		response.Header.Get("Location") != "",
		len(body),
		response.Header.Get("Content-Type"),
	)
	s.logOAuthHop("authorize", authorizeURL, response, body)
	var authorizeResult struct {
		Ret      int    `json:"ret"`
		Msg      string `json:"msg"`
		Callback string `json:"callback"`
	}
	if json.Unmarshal(body, &authorizeResult) == nil {
		if authorizeResult.Ret != 0 {
			return "", "", fmt.Errorf("QQ 授权返回业务码 %d: %s", authorizeResult.Ret, authorizeResult.Msg)
		}
		if authorizeResult.Callback != "" {
			location = authorizeResult.Callback
		}
	}
	code := oauthCode(location, string(body))
	baseURL := mustURL(authorizeURL)
	for hop := 0; hop < 4 && code == "" && location != "" && response.StatusCode >= 300 && response.StatusCode < 400; hop++ {
		next, resolveErr := resolveRedirect(baseURL, location)
		if resolveErr != nil {
			return "", "", resolveErr
		}
		baseURL = next
		response, err = s.doGet(ctx, next.String(), sigCookies, authorizeURL)
		if err != nil {
			return "", "", errors.New("跟随 QQ 授权跳转失败")
		}
		mergeCookieMaps(sigCookies, responseCookies(response))
		location = response.Header.Get("Location")
		body, _ = readLimited(response.Body)
		_ = response.Body.Close()
		s.logOAuthHop(fmt.Sprintf("authorize_redirect_%d", hop+1), next.String(), response, body)
		code = oauthCode(location, string(body))
	}
	if code == "" {
		if location != "" {
			s.logger.Printf("QQ OAuth 最终未取得 code，最后一跳=%s", safeURLForLog(location))
		}
		return "", "", errors.New("QQ 授权响应缺少 code")
	}

	payload := map[string]any{
		"comm": map[string]any{"g_tk": gtk, "platform": "yqq", "ct": 24, "cv": 0, "tmeLoginType": 2},
		"req": map[string]any{
			"module": "QQConnectLogin.LoginServer",
			"method": "QQLogin",
			"param":  map[string]any{"code": code},
		},
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return "", "", errors.New("编码 QQ 音乐登录请求失败")
	}
	request, err = http.NewRequestWithContext(ctx, http.MethodPost, s.endpoints.musicLogin, strings.NewReader(string(encoded)))
	if err != nil {
		return "", "", errors.New("创建 QQ 音乐登录请求失败")
	}
	setQQBrowserHeaders(request)
	request.Header.Set("Cookie", cookieHeader(sigCookies))
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("Origin", "https://y.qq.com")
	request.Header.Set("Referer", "https://y.qq.com/")
	response, err = s.httpClient.Do(request)
	if err != nil {
		return "", "", errors.New("请求 QQ 音乐登录服务失败")
	}
	defer response.Body.Close()
	mergeCookieMaps(sigCookies, responseCookies(response))
	loginBody, err := readLimited(response.Body)
	if err != nil {
		return "", "", err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return "", "", fmt.Errorf("QQ 音乐登录服务返回 HTTP %d", response.StatusCode)
	}

	var result struct {
		Code int `json:"code"`
		Req  struct {
			Code int `json:"code"`
			Data struct {
				MusicID    any    `json:"musicid"`
				UIN        any    `json:"uin"`
				MusicKey   string `json:"musickey"`
				QQMusicKey string `json:"qqmusic_key"`
			} `json:"data"`
		} `json:"req"`
	}
	if err := json.Unmarshal(loginBody, &result); err != nil {
		return "", "", errors.New("解析 QQ 音乐登录响应失败")
	}
	if result.Code != 0 || (result.Req.Code != 0 && result.Req.Code != 1000) {
		return "", "", fmt.Errorf("QQ 音乐登录返回业务码 %d/%d", result.Code, result.Req.Code)
	}
	qmKeyst := strings.TrimSpace(result.Req.Data.MusicKey)
	if qmKeyst == "" {
		qmKeyst = strings.TrimSpace(result.Req.Data.QQMusicKey)
	}
	if qmKeyst == "" {
		qmKeyst = cookieValue(sigCookies, "qm_keyst")
	}
	if qmKeyst == "" {
		qmKeyst = cookieValue(sigCookies, "qqmusic_key")
	}
	if qmKeyst == "" || len(qmKeyst) > maxCredentialLength {
		return "", "", errors.New("QQ 音乐登录响应缺少有效 musickey")
	}
	uin := checkSigUIN
	if uin == "" {
		uin = normalizeUIN(fmt.Sprint(result.Req.Data.UIN))
	}
	if uin == "" {
		uin = normalizeUIN(fmt.Sprint(result.Req.Data.MusicID))
	}
	if uin == "" {
		uin = normalizeUIN(firstNonEmpty(cookieValue(sigCookies, "uin"), cookieValue(sigCookies, "p_uin")))
	}
	if uin == "" {
		return "", "", errors.New("QQ 音乐登录响应缺少 UIN")
	}
	return uin, qmKeyst, nil
}

func (s *Service) doGet(ctx context.Context, address string, cookies map[string]string, referer string) (*http.Response, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	setQQBrowserHeaders(request)
	request.Header.Set("Cookie", cookieHeader(cookies))
	request.Header.Set("Referer", referer)
	request.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
	return s.httpClient.Do(request)
}

func (s *Service) doGetWithJar(ctx context.Context, address string, cookieJar *cookiejar.Jar, referer string) (*http.Response, error) {
	parsed, err := url.Parse(address)
	if err != nil {
		return nil, err
	}
	return s.doGet(ctx, address, cookiesForURL(cookieJar, parsed), referer)
}

func (s *Service) lookup(id string) (*loginSession, error) {
	id = strings.TrimSpace(id)
	if id == "" {
		return nil, ErrSessionNotFound
	}
	s.mu.Lock()
	session := s.sessions[id]
	s.mu.Unlock()
	if session == nil {
		return nil, ErrSessionNotFound
	}
	session.mu.Lock()
	expired := s.expiredLocked(session)
	session.mu.Unlock()
	if expired {
		return nil, ErrSessionNotFound
	}
	return session, nil
}

func (s *Service) expiredLocked(session *loginSession) bool {
	return !session.expiresAt.After(s.now().UTC())
}

func (s *Service) cleanup() {
	now := s.now().UTC()
	s.mu.Lock()
	defer s.mu.Unlock()
	for id, session := range s.sessions {
		session.mu.Lock()
		expired := !session.expiresAt.After(now)
		session.mu.Unlock()
		if expired {
			delete(s.sessions, id)
		}
	}
}

func (session *loginSession) public() Session {
	return Session{ID: session.id, Status: session.status, Message: session.message, ExpiresAt: session.expiresAt}
}

func (session *loginSession) pollResult() PollResult {
	return PollResult{Session: session.public(), UIN: session.uin, QMKeyst: session.qmKeyst}
}

func setQQBrowserHeaders(request *http.Request) {
	request.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36")
	request.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	request.Header.Set("Referer", "https://xui.ptlogin2.qq.com/")
}

// unescapePTURL 处理 ptuiCB 中可能出现的 JavaScript 转义形式。
func unescapePTURL(raw string) string {
	raw = strings.ReplaceAll(raw, `\/`, `/`)
	raw = strings.ReplaceAll(raw, `\x26`, `&`)
	raw = strings.ReplaceAll(raw, `\u0026`, `&`)
	return html.UnescapeString(raw)
}

func (s *Service) logLoginHop(stage string, address *url.URL, response *http.Response) {
	keys := make([]string, 0)
	for key := range address.Query() {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	redirect := safeURLForLog(response.Header.Get("Location"))
	s.logger.Printf(
		"QQ 扫码链路 %s: HTTP %d 主机=%s 路径=%s 查询参数=%s 新Cookie=%s 跳转=%s",
		stage,
		response.StatusCode,
		address.Hostname(),
		address.EscapedPath(),
		strings.Join(keys, ","),
		strings.Join(cookieNames(responseCookies(response)), ","),
		redirect,
	)
}

// logOAuthHop 记录授权链路的脱敏结构信息。查询参数只保留键名，
// 避免 code、token、key 等一次性凭据进入日志。
func (s *Service) logOAuthHop(stage, address string, response *http.Response, body []byte) {
	var ret *int
	var parsed struct {
		Ret int `json:"ret"`
	}
	if json.Unmarshal(body, &parsed) == nil {
		ret = &parsed.Ret
	}
	retText := "-"
	if ret != nil {
		retText = strconv.Itoa(*ret)
	}
	s.logger.Printf(
		"QQ OAuth 链路 %s: HTTP %d 跳转=%s 含code=%t JSON回复=%t ret=%s 响应字节=%d",
		stage,
		response.StatusCode,
		safeURLForLog(response.Header.Get("Location")),
		oauthCode(response.Header.Get("Location"), string(body)) != "",
		ret != nil,
		retText,
		len(body),
	)
	_ = address // 当前地址已由调用方在上一跳日志中记录。
}

// safeURLForLog 只输出 URL 的主机、路径和查询参数名。
func safeURLForLog(raw string) string {
	if strings.TrimSpace(raw) == "" {
		return "-"
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return "<invalid>"
	}
	keys := make([]string, 0, len(parsed.Query()))
	for key := range parsed.Query() {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	target := parsed.EscapedPath()
	if target == "" {
		target = "/"
	}
	if parsed.Hostname() != "" {
		target = parsed.Scheme + "://" + parsed.Hostname() + target
	}
	if len(keys) > 0 {
		target += " ?" + strings.Join(keys, ",")
	}
	return target
}

func responseCookies(response *http.Response) map[string]string {
	result := make(map[string]string)
	for _, cookie := range response.Cookies() {
		if cookie.Name != "" && cookie.Value != "" {
			result[cookie.Name] = cookie.Value
		}
	}
	return result
}

func storeResponseCookies(cookieJar *cookiejar.Jar, requestURL *url.URL, response *http.Response) {
	if cookieJar == nil || requestURL == nil || response == nil {
		return
	}
	cookieJar.SetCookies(requestURL, response.Cookies())
}

func cookiesForURL(cookieJar *cookiejar.Jar, requestURL *url.URL) map[string]string {
	result := make(map[string]string)
	if cookieJar == nil || requestURL == nil {
		return result
	}
	for _, cookie := range cookieJar.Cookies(requestURL) {
		if cookie.Name != "" && cookie.Value != "" {
			result[cookie.Name] = cookie.Value
		}
	}
	return result
}

func cookieValueForURL(cookieJar *cookiejar.Jar, requestURL *url.URL, name string) string {
	return cookieValue(cookiesForURL(cookieJar, requestURL), name)
}

func cookieNames(cookies map[string]string) []string {
	names := make([]string, 0, len(cookies))
	for name, value := range cookies {
		if name != "" && value != "" {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	return names
}

func mergeCookieMaps(target, source map[string]string) {
	for name, value := range source {
		if name != "" && value != "" {
			target[name] = value
		}
	}
}

func cookieValue(cookies map[string]string, name string) string {
	for key, value := range cookies {
		if strings.EqualFold(key, name) {
			return value
		}
	}
	return ""
}

func cookieHeader(cookies map[string]string) string {
	names := make([]string, 0, len(cookies))
	for name, value := range cookies {
		if name != "" && value != "" {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	parts := make([]string, 0, len(names))
	for _, name := range names {
		parts = append(parts, name+"="+cookies[name])
	}
	return strings.Join(parts, "; ")
}

func resolveRedirect(base *url.URL, location string) (*url.URL, error) {
	location = strings.TrimSpace(location)
	if location == "" {
		return nil, errors.New("QQ 登录跳转缺少目标地址")
	}
	next, err := url.Parse(location)
	if err != nil {
		return nil, errors.New("QQ 登录跳转地址不合法")
	}
	next = base.ResolveReference(next)
	if (next.Scheme != "https" && next.Scheme != "http") || next.Host == "" {
		return nil, errors.New("QQ 登录跳转地址不合法")
	}
	return next, nil
}

func mustURL(raw string) *url.URL {
	parsed, _ := url.Parse(raw)
	return parsed
}

func readLimited(reader io.Reader) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(reader, maxBodyBytes+1))
	if err != nil {
		return nil, errors.New("读取 QQ 登录服务响应失败")
	}
	if len(data) > maxBodyBytes {
		return nil, errors.New("QQ 登录服务响应过大")
	}
	return data, nil
}

func hashedToken(qrsig string) int64 {
	var token uint32
	for _, char := range qrsig {
		token = (token << 5) + token + uint32(char)
	}
	return int64(token & 0x7fffffff)
}

func hash33(qrsig string) int64 {
	return hashedToken(qrsig)
}

func gtkFromPSkey(pSkey string) int64 {
	var hash int64 = 5381
	for _, char := range pSkey {
		hash += (hash << 5) + int64(char)
	}
	return hash & 0x7fffffff
}

var ptuicbPattern = regexp.MustCompile(`(?s)ptuiCB\s*\((.*?)\)\s*;?`)

func parsePTUICB(body string) (code int, message, redirect string, err error) {
	match := ptuicbPattern.FindStringSubmatch(body)
	if len(match) != 2 {
		return 0, "", "", errors.New("无法解析 QQ 扫码状态")
	}
	args := quotedArguments(match[1])
	if len(args) < 5 {
		return 0, "", "", errors.New("QQ 扫码状态字段不完整")
	}
	code, err = strconv.Atoi(strings.TrimSpace(args[0]))
	if err != nil {
		return 0, "", "", errors.New("QQ 扫码状态码不合法")
	}
	return code, args[4], args[2], nil
}

var quotedArgumentPattern = regexp.MustCompile(`\s*(?:'((?:\\.|[^'])*)'|"((?:\\.|[^"])*)")\s*(?:,|$)`)

func quotedArguments(value string) []string {
	matches := quotedArgumentPattern.FindAllStringSubmatch(value, -1)
	result := make([]string, 0, len(matches))
	for _, match := range matches {
		part := match[1]
		if part == "" {
			part = match[2]
		}
		part = strings.ReplaceAll(part, `\'`, `'`)
		part = strings.ReplaceAll(part, `\"`, `"`)
		result = append(result, html.UnescapeString(part))
	}
	return result
}

var oauthCodePattern = regexp.MustCompile(`[?&]code=([^&"'\s]+)`)

func oauthCode(location, body string) string {
	for _, candidate := range []string{location, body} {
		match := oauthCodePattern.FindStringSubmatch(candidate)
		if len(match) == 2 {
			value, err := url.QueryUnescape(match[1])
			if err == nil && value != "" {
				return value
			}
		}
	}
	return ""
}

func digitsOnly(value string) string {
	var builder strings.Builder
	for _, char := range value {
		if char >= '0' && char <= '9' {
			builder.WriteRune(char)
		}
	}
	return builder.String()
}

// normalizeUIN 将 QQ 登录链路中的 o00209192670 等表示统一为 209192670。
func normalizeUIN(value string) string {
	digits := digitsOnly(value)
	trimmed := strings.TrimLeft(digits, "0")
	if trimmed == "" {
		return digits
	}
	return trimmed
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func randomID() (string, error) {
	value := make([]byte, 32)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}

func randomGUID() string {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		return "00000000-0000-4000-8000-000000000000"
	}
	value[6] = (value[6] & 0x0f) | 0x40
	value[8] = (value[8] & 0x3f) | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", value[0:4], value[4:6], value[6:8], value[8:10], value[10:16]))
}
