// Package netease implements NetEase Cloud Music authentication, QR login and
// the media APIs used by the source-neutral backend.
package netease

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	defaultBaseURL     = "https://music.163.com"
	defaultAppBaseURL  = "https://interface.music.163.com"
	defaultHTTPTimeout = 20 * time.Second
	maxResponseBytes   = 2 << 20
)

var (
	// ErrUnauthorized 表示网易云明确拒绝了当前 Cookie。
	ErrUnauthorized = errors.New("网易云音乐登录态已失效")
	// ErrUIDMismatch 表示 Cookie 对应账号与用户填写的账号 ID 不一致。
	ErrUIDMismatch = errors.New("网易云音乐账号 ID 与 Cookie 不匹配")
	// ErrInvitationExpired 表示邀请 token 已过期或不存在。
	ErrInvitationExpired = errors.New("网易云会员邀请已过期")
	// ErrInvitationAlreadyAccepted 表示当前账号已经领取过该邀请人或本月的邀请福利。
	ErrInvitationAlreadyAccepted = errors.New("网易云会员邀请已经领取")
	// ErrInvitationRisk 表示网易云以账号或设备风险为由拒绝领取。
	ErrInvitationRisk = errors.New("网易云会员邀请触发风控")
)

// InvitationAPIError 保留邀请接口的业务码和分类错误。
type InvitationAPIError struct {
	Method  string
	Code    int
	Message string
	Err     error
}

// Error 实现 error 接口。
func (e *InvitationAPIError) Error() string {
	if e == nil {
		return "网易云会员邀请接口错误"
	}
	return fmt.Sprintf("网易云 %s 返回业务码 %d: %s", e.Method, e.Code, e.Message)
}

// Unwrap 返回稳定的错误分类。
func (e *InvitationAPIError) Unwrap() error {
	if e == nil || e.Err == nil {
		return errors.New("网易云会员邀请接口错误")
	}
	return e.Err
}

// AccountState 是一次网易云账号检查或刷新后的规范化状态。
type AccountState struct {
	UID       int64
	Nickname  string
	AvatarURL string
	Cookie    string
	ExpiresAt *time.Time
}

// VIPStatus 是网易云黑胶会员的规范化状态。
type VIPStatus struct {
	Active      bool
	Level       int
	ExpiresAt   *time.Time
	VipCode     int64
	RedVipLevel int64
}

// InvitationDetail 是网易云黑胶邀请活动详情。
type InvitationDetail struct {
	RecordID            int64
	CurrentUserRecordID int64
	TokenExpireTime     *time.Time
	Duration            int64
	AcceptTime          int64
	HasInvitee          bool
}

// InvitationAcceptResult 是网易云邀请领取结果。
type InvitationAcceptResult struct {
	Code    int
	Message string
	Data    json.RawMessage
}

// Client 调用网易云音乐 WeAPI 登录相关接口。
type Client struct {
	httpClient *http.Client
	baseURL    string
	appBaseURL string
	now        func() time.Time
}

// Option 配置网易云客户端，主要用于测试和自定义部署。
type Option func(*Client) error

// WithHTTPClient 使用指定的 HTTP 客户端。
func WithHTTPClient(client *http.Client) Option {
	return func(target *Client) error {
		if client == nil {
			return errors.New("HTTP 客户端不能为空")
		}
		target.httpClient = client
		return nil
	}
}

// WithBaseURL 覆盖网易云基础地址，仅用于测试或兼容镜像环境。
func WithBaseURL(raw string) Option {
	return func(target *Client) error {
		parsed, err := url.Parse(strings.TrimSpace(raw))
		if err != nil || parsed.Scheme == "" || parsed.Host == "" {
			return errors.New("网易云基础地址不合法")
		}
		target.baseURL = strings.TrimRight(parsed.String(), "/")
		return nil
	}
}

// WithAppBaseURL 覆盖网易云 App/H5 接口基础地址，仅用于测试或兼容镜像环境。
func WithAppBaseURL(raw string) Option {
	return func(target *Client) error {
		parsed, err := url.Parse(strings.TrimSpace(raw))
		if err != nil || parsed.Scheme == "" || parsed.Host == "" {
			return errors.New("网易云 App 接口基础地址不合法")
		}
		target.appBaseURL = strings.TrimRight(parsed.String(), "/")
		return nil
	}
}

// NewClient 创建网易云登录客户端。
func NewClient(options ...Option) (*Client, error) {
	client := &Client{
		httpClient: &http.Client{Timeout: defaultHTTPTimeout},
		baseURL:    defaultBaseURL,
		appBaseURL: defaultAppBaseURL,
		now:        time.Now,
	}
	for _, option := range options {
		if option == nil {
			continue
		}
		if err := option(client); err != nil {
			return nil, err
		}
	}
	return client, nil
}

// GetInvitationDetail 查询网易云黑胶邀请详情。
func (c *Client) GetInvitationDetail(ctx context.Context, cookie, token, channel, referer string) (InvitationDetail, error) {
	cookies, err := c.normalizedCookies(cookie)
	if err != nil {
		return InvitationDetail{}, err
	}
	if strings.TrimSpace(cookies["MUSIC_U"]) == "" {
		return InvitationDetail{}, ErrUnauthorized
	}
	token = strings.TrimSpace(token)
	if token == "" {
		return InvitationDetail{}, ErrInvitationExpired
	}
	query := url.Values{"token": []string{token}}
	if channel = strings.TrimSpace(channel); channel != "" {
		query.Set("refer", channel)
	}
	result, err := c.doAppRequest(ctx, http.MethodGet, "/api/vipactivity/app/vip/invitation/detail/info/get", query, nil, cookies, referer)
	if err != nil {
		return InvitationDetail{}, err
	}
	if result.Code == 12208 {
		return InvitationDetail{}, &InvitationAPIError{Method: "invitation/detail", Code: result.Code, Message: result.Message, Err: ErrInvitationRisk}
	}
	if result.Code != 200 {
		if isUnauthorizedCode(result.Code) {
			return InvitationDetail{}, ErrUnauthorized
		}
		classification := error(nil)
		if result.Code == 404 || result.Code == 410 {
			classification = ErrInvitationExpired
		}
		return InvitationDetail{}, &InvitationAPIError{Method: "invitation/detail", Code: result.Code, Message: result.Message, Err: classification}
	}
	var payload struct {
		Data struct {
			RecordID            int64  `json:"recordId"`
			CurrentUserRecordID int64  `json:"currentUserRecordId"`
			TokenExpireTime     number `json:"tokenExpireTime"`
			Duration            number `json:"duration"`
			AcceptTime          number `json:"acceptTime"`
			Invitee             any    `json:"invitee"`
		} `json:"data"`
	}
	if err := json.Unmarshal(result.Raw, &payload); err != nil {
		return InvitationDetail{}, fmt.Errorf("解析网易云邀请详情: %w", err)
	}
	detail := InvitationDetail{
		RecordID:            payload.Data.RecordID,
		CurrentUserRecordID: payload.Data.CurrentUserRecordID,
		Duration:            payload.Data.Duration.Int64(),
		AcceptTime:          payload.Data.AcceptTime.Int64(),
		HasInvitee:          payload.Data.Invitee != nil,
	}
	if expiresMillis := payload.Data.TokenExpireTime.Int64(); expiresMillis > 0 {
		expiresAt := time.UnixMilli(expiresMillis).UTC()
		detail.TokenExpireTime = &expiresAt
		if c.now().UTC().After(expiresAt) {
			return InvitationDetail{}, ErrInvitationExpired
		}
	}
	return detail, nil
}

// AcceptInvitation 使用当前账号领取网易云黑胶邀请福利。
func (c *Client) AcceptInvitation(ctx context.Context, cookie, token, channel, referer string) (InvitationAcceptResult, error) {
	cookies, err := c.normalizedCookies(cookie)
	if err != nil {
		return InvitationAcceptResult{}, err
	}
	if strings.TrimSpace(cookies["MUSIC_U"]) == "" {
		return InvitationAcceptResult{}, ErrUnauthorized
	}
	token = strings.TrimSpace(token)
	if token == "" {
		return InvitationAcceptResult{}, ErrInvitationExpired
	}
	form := url.Values{"token": []string{token}}
	if channel = strings.TrimSpace(channel); channel != "" {
		form.Set("refer", channel)
	}
	result, err := c.doAppRequest(ctx, http.MethodPost, "/api/vipactivity/app/vip/invitation/accept", nil, form, cookies, referer)
	if err != nil {
		return InvitationAcceptResult{}, err
	}
	response := InvitationAcceptResult{Code: result.Code, Message: result.Message, Data: cloneRaw(result.Raw)}
	switch result.Code {
	case 200, 201:
		return response, nil
	case 12208:
		return response, &InvitationAPIError{Method: "invitation/accept", Code: result.Code, Message: result.Message, Err: ErrInvitationRisk}
	}
	if isUnauthorizedCode(result.Code) {
		return response, ErrUnauthorized
	}
	classification := error(nil)
	if result.Code == 404 || result.Code == 410 {
		classification = ErrInvitationExpired
	}
	return response, &InvitationAPIError{Method: "invitation/accept", Code: result.Code, Message: result.Message, Err: classification}
}

// Check 校验 Cookie 对应账号是否有效，并返回刷新后的规范化 Cookie。
func (c *Client) Check(ctx context.Context, cookie string, expectedUID string) (AccountState, error) {
	cookies, err := c.normalizedCookies(cookie)
	if err != nil {
		return AccountState{}, err
	}
	if strings.TrimSpace(cookies["MUSIC_U"]) == "" {
		return AccountState{}, ErrUnauthorized
	}
	result, err := c.doWeapi(ctx, "/api/w/nuser/account/get", nil, cookies)
	if err != nil {
		return AccountState{}, err
	}
	if result.Code != 200 {
		if isUnauthorizedCode(result.Code) {
			return AccountState{}, ErrUnauthorized
		}
		return AccountState{}, fmt.Errorf("网易云账号接口返回业务码 %d: %s", result.Code, result.Message)
	}
	var response accountResponse
	if err := json.Unmarshal(result.Raw, &response); err != nil {
		return AccountState{}, fmt.Errorf("解析网易云账号响应: %w", err)
	}
	if response.Account == nil || response.Account.ID <= 0 {
		return AccountState{}, ErrUnauthorized
	}
	expectedUID = strings.TrimSpace(expectedUID)
	if expectedUID != "" && expectedUID != strconv.FormatInt(response.Account.ID, 10) {
		return AccountState{}, ErrUIDMismatch
	}
	state := AccountState{
		UID:       response.Account.ID,
		Cookie:    result.Cookie,
		ExpiresAt: result.ExpiresAt,
	}
	if response.Profile != nil {
		state.Nickname = strings.TrimSpace(response.Profile.Nickname)
		state.AvatarURL = strings.TrimSpace(response.Profile.AvatarURL)
		if state.Nickname == "" {
			state.Nickname = strings.TrimSpace(response.Profile.UserName)
		}
	}
	return state, nil
}

// Refresh 尝试调用网易云 token refresh 接口，并在刷新后重新校验账号。
func (c *Client) Refresh(ctx context.Context, cookie string, expectedUID string) (AccountState, error) {
	cookies, err := c.normalizedCookies(cookie)
	if err != nil {
		return AccountState{}, err
	}
	if strings.TrimSpace(cookies["MUSIC_U"]) == "" {
		return AccountState{}, ErrUnauthorized
	}
	result, err := c.doWeapi(ctx, "/api/login/token/refresh", nil, cookies)
	if err != nil {
		return AccountState{}, err
	}
	if result.Code != 200 && !isRefreshSuccessCode(result.Code, result.BizCode) && isUnauthorizedCode(result.Code) {
		return AccountState{}, ErrUnauthorized
	}
	return c.Check(ctx, result.Cookie, expectedUID)
}

// GetVIPStatus 查询网易云账号当前黑胶会员状态和到期时间。
func (c *Client) GetVIPStatus(ctx context.Context, cookie, userID string) (VIPStatus, error) {
	cookies, err := c.normalizedCookies(cookie)
	if err != nil {
		return VIPStatus{}, err
	}
	if strings.TrimSpace(cookies["MUSIC_U"]) == "" {
		return VIPStatus{}, ErrUnauthorized
	}
	userID = strings.TrimSpace(userID)
	if userID == "" {
		return VIPStatus{}, errors.New("网易云音乐账号 ID 不能为空")
	}
	result, err := c.doWeapi(ctx, "/api/music-vip-membership/front/vip/info", map[string]any{
		"userId": userID,
	}, cookies)
	if err != nil {
		return VIPStatus{}, err
	}
	if result.Code != 200 {
		if isUnauthorizedCode(result.Code) {
			return VIPStatus{}, ErrUnauthorized
		}
		return VIPStatus{}, fmt.Errorf("网易云会员接口返回业务码 %d: %s", result.Code, result.Message)
	}
	var response vipInfoResponse
	if err := json.Unmarshal(result.Raw, &response); err != nil {
		return VIPStatus{}, fmt.Errorf("解析网易云会员响应: %w", err)
	}
	status := VIPStatus{RedVipLevel: response.Data.RedVipLevel.Int64()}
	membership := response.Data.Associator
	if membership != nil {
		status.VipCode = membership.VipCode.Int64()
		expiresAt := membership.ExpiresTime()
		if expiresAt != nil && expiresAt.After(c.now().UTC()) {
			status.Active = true
			status.Level = 1
			status.ExpiresAt = expiresAt
		}
	}
	return status, nil
}

type accountResponse struct {
	Code    int              `json:"code"`
	Account *accountIdentity `json:"account"`
	Profile *accountProfile  `json:"profile"`
}

type accountIdentity struct {
	ID int64 `json:"id"`
}

type accountProfile struct {
	UserID    int64  `json:"userId"`
	UserName  string `json:"userName"`
	Nickname  string `json:"nickname"`
	AvatarURL string `json:"avatarUrl"`
}

type vipInfoResponse struct {
	Code int `json:"code"`
	Data struct {
		Associator  *vipMembership `json:"associator"`
		RedVipLevel number         `json:"redVipLevel"`
	} `json:"data"`
}

type vipMembership struct {
	VipCode    number `json:"vipCode"`
	ExpireTime number `json:"expireTime"`
}

func (m *vipMembership) ExpiresTime() *time.Time {
	if m == nil {
		return nil
	}
	value := m.ExpireTime.Int64()
	if value <= 0 {
		return nil
	}
	var unixMilli int64
	if value > 1e12 {
		unixMilli = value
	} else {
		unixMilli = value * 1000
	}
	expiresAt := time.UnixMilli(unixMilli).UTC()
	return &expiresAt
}

// number accepts both JSON numbers and numeric strings from NetEase APIs.
type number int64

func (n *number) UnmarshalJSON(raw []byte) error {
	text := strings.Trim(strings.TrimSpace(string(raw)), `"`)
	if text == "" || text == "null" {
		*n = 0
		return nil
	}
	value, err := strconv.ParseInt(text, 10, 64)
	if err != nil {
		parsed, floatErr := strconv.ParseFloat(text, 64)
		if floatErr != nil {
			return err
		}
		value = int64(parsed)
	}
	*n = number(value)
	return nil
}

func (n number) Int64() int64 {
	return int64(n)
}

type apiResult struct {
	Code      int
	BizCode   string
	Message   string
	Raw       []byte
	Cookie    string
	ExpiresAt *time.Time
}

func (c *Client) doWeapi(ctx context.Context, path string, data map[string]any, cookies map[string]string) (apiResult, error) {
	if ctx == nil {
		return apiResult{}, errors.New("请求 context 不能为空")
	}
	if data == nil {
		data = make(map[string]any)
	}
	if token := strings.TrimSpace(cookies["__csrf"]); token != "" {
		data["csrf_token"] = token
	}
	form, err := encryptWeapiPayload(data)
	if err != nil {
		return apiResult{}, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, weapiURL(c.baseURL, path), strings.NewReader(form.Encode()))
	if err != nil {
		return apiResult{}, fmt.Errorf("创建网易云请求: %w", err)
	}
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("Referer", c.baseURL)
	request.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
	request.Header.Set("Cookie", cookieHeader(cookies))

	response, err := c.httpClient.Do(request)
	if err != nil {
		return apiResult{}, fmt.Errorf("请求网易云接口: %w", err)
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes))
	if err != nil {
		return apiResult{}, fmt.Errorf("读取网易云响应: %w", err)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return apiResult{}, fmt.Errorf("网易云接口返回 HTTP %d", response.StatusCode)
	}

	var envelope struct {
		Code    json.RawMessage `json:"code"`
		BizCode json.RawMessage `json:"bizCode"`
		Message string          `json:"message"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return apiResult{}, fmt.Errorf("解析网易云响应: %w", err)
	}
	code := parseNumericValue(envelope.Code)
	bizCode := strings.Trim(parseStringValue(envelope.BizCode), `"`)
	mergedCookie, expiresAt := mergeResponseCookies(cookies, response.Cookies(), c.now().UTC())
	if code == 0 && len(raw) > 0 {
		code = response.StatusCode
	}
	return apiResult{
		Code:      code,
		BizCode:   bizCode,
		Message:   strings.TrimSpace(envelope.Message),
		Raw:       raw,
		Cookie:    cookieHeader(mergedCookie),
		ExpiresAt: expiresAt,
	}, nil
}

func (c *Client) doAppRequest(ctx context.Context, method, path string, query, form url.Values, cookies map[string]string, referer string) (apiResult, error) {
	if ctx == nil {
		return apiResult{}, errors.New("请求 context 不能为空")
	}
	if query == nil {
		query = make(url.Values)
	}
	if form == nil {
		form = make(url.Values)
	}
	if csrf := strings.TrimSpace(cookies["__csrf"]); csrf != "" {
		query.Set("csrf_token", csrf)
		if method == http.MethodPost {
			form.Set("csrf_token", csrf)
		}
	}
	address := strings.TrimRight(c.appBaseURL, "/") + path
	if encoded := query.Encode(); encoded != "" {
		address += "?" + encoded
	}
	var body io.Reader
	if method == http.MethodPost {
		body = strings.NewReader(form.Encode())
	}
	request, err := http.NewRequestWithContext(ctx, method, address, body)
	if err != nil {
		return apiResult{}, fmt.Errorf("创建网易云 App 请求: %w", err)
	}
	request.Header.Set("Accept", "application/json, text/plain, */*")
	request.Header.Set("Origin", "https://y.music.163.com")
	if strings.TrimSpace(referer) == "" {
		referer = "https://y.music.163.com/"
	}
	request.Header.Set("Referer", referer)
	request.Header.Set("User-Agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148")
	request.Header.Set("Cookie", cookieHeader(cookies))
	if method == http.MethodPost {
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	response, err := c.httpClient.Do(request)
	if err != nil {
		return apiResult{}, fmt.Errorf("请求网易云 App 接口: %w", err)
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes))
	if err != nil {
		return apiResult{}, fmt.Errorf("读取网易云 App 响应: %w", err)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return apiResult{}, fmt.Errorf("网易云 App 接口返回 HTTP %d", response.StatusCode)
	}
	var envelope struct {
		Code    json.RawMessage `json:"code"`
		Message string          `json:"message"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return apiResult{}, fmt.Errorf("解析网易云 App 响应: %w", err)
	}
	code := parseNumericValue(envelope.Code)
	if code == 0 && len(raw) > 0 {
		code = response.StatusCode
	}
	return apiResult{Code: code, Message: strings.TrimSpace(envelope.Message), Raw: raw}, nil
}

func cloneRaw(raw []byte) json.RawMessage {
	if len(raw) == 0 {
		return nil
	}
	return append(json.RawMessage(nil), raw...)
}

func (c *Client) normalizedCookies(raw string) (map[string]string, error) {
	cookies := parseCookieHeader(raw)
	if cookies == nil {
		cookies = make(map[string]string)
	}
	setDefault(cookies, "__remember_me", "true")
	setDefault(cookies, "os", "pc")
	setDefault(cookies, "appver", "3.1.17.204416")
	setDefault(cookies, "osver", "Microsoft-Windows-10-Professional-build-19045-64bit")
	setDefault(cookies, "channel", "netease")
	deviceID := cookies["deviceId"]
	if deviceID == "" {
		generated, err := randomHex(26)
		if err != nil {
			return nil, err
		}
		deviceID = strings.ToUpper(generated)
		cookies["deviceId"] = deviceID
	}
	setDefault(cookies, "sDeviceId", deviceID)
	setDefault(cookies, "NMTID", "00O"+deviceID)
	nuid := cookies["_ntes_nuid"]
	if nuid == "" {
		generated, err := randomHex(16)
		if err != nil {
			return nil, err
		}
		nuid = generated
		cookies["_ntes_nuid"] = nuid
	}
	setDefault(cookies, "_ntes_nnid", nuid+","+strconv.FormatInt(c.now().UnixMilli(), 10))
	setDefault(cookies, "WNMCID", "ncmctl."+strconv.FormatInt(c.now().UnixMilli(), 10)+".01.0")
	return cookies, nil
}

func setDefault(cookies map[string]string, key, value string) {
	if strings.TrimSpace(cookies[key]) == "" {
		cookies[key] = value
	}
}

func parseCookieHeader(raw string) map[string]string {
	raw = strings.TrimSpace(raw)
	if strings.HasPrefix(strings.ToLower(raw), "cookie:") {
		raw = strings.TrimSpace(raw[len("cookie:"):])
	}
	result := make(map[string]string)
	for _, part := range strings.Split(raw, ";") {
		part = strings.TrimSpace(part)
		index := strings.IndexByte(part, '=')
		if index <= 0 {
			continue
		}
		name := strings.TrimSpace(part[:index])
		value := strings.TrimSpace(part[index+1:])
		if name != "" {
			result[name] = value
		}
	}
	return result
}

func cookieHeader(cookies map[string]string) string {
	if len(cookies) == 0 {
		return ""
	}
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

func mergeResponseCookies(current map[string]string, responseCookies []*http.Cookie, now time.Time) (map[string]string, *time.Time) {
	merged := make(map[string]string, len(current)+len(responseCookies))
	for name, value := range current {
		merged[name] = value
	}
	var expiresAt *time.Time
	for _, cookie := range responseCookies {
		if cookie == nil || strings.TrimSpace(cookie.Name) == "" {
			continue
		}
		if cookie.MaxAge < 0 {
			delete(merged, cookie.Name)
			continue
		}
		if cookie.Value != "" {
			merged[cookie.Name] = cookie.Value
		}
		var expiry time.Time
		if cookie.MaxAge > 0 {
			expiry = now.Add(time.Duration(cookie.MaxAge) * time.Second)
		} else if !cookie.Expires.IsZero() {
			expiry = cookie.Expires.UTC()
		}
		if (cookie.Name == "MUSIC_U" || cookie.Name == "MUSIC_R_U") && !expiry.IsZero() {
			if expiresAt == nil || expiry.After(*expiresAt) {
				value := expiry.UTC()
				expiresAt = &value
			}
		}
	}
	return merged, expiresAt
}

func weapiURL(baseURL, path string) string {
	path = strings.TrimSpace(path)
	path = strings.TrimPrefix(path, "/")
	if strings.HasPrefix(path, "api/") {
		path = "weapi/" + strings.TrimPrefix(path, "api/")
	}
	if !strings.HasPrefix(path, "weapi/") {
		path = "weapi/" + path
	}
	return strings.TrimRight(baseURL, "/") + "/" + path
}

func isUnauthorizedCode(code int) bool {
	return code == 301 || code == 302 || code == 401
}

func isRefreshSuccessCode(code int, bizCode string) bool {
	return code == 200 || code == 201 || strings.TrimSpace(bizCode) == "201"
}

func parseNumericValue(raw json.RawMessage) int {
	if len(raw) == 0 {
		return 0
	}
	var number json.Number
	if err := json.Unmarshal(raw, &number); err == nil {
		value, _ := strconv.Atoi(number.String())
		return value
	}
	var text string
	if err := json.Unmarshal(raw, &text); err == nil {
		value, _ := strconv.Atoi(strings.TrimSpace(text))
		return value
	}
	return 0
}

func parseStringValue(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var text string
	if err := json.Unmarshal(raw, &text); err == nil {
		return text
	}
	return string(raw)
}

func randomHex(byteLength int) (string, error) {
	value := make([]byte, byteLength)
	if _, err := rand.Read(value); err != nil {
		return "", fmt.Errorf("生成网易云设备标识: %w", err)
	}
	return hex.EncodeToString(value), nil
}
