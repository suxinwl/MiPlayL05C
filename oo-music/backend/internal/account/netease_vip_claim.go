package account

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"path"
	"sort"
	"strings"
	"time"
)

const (
	defaultNeteaseVIPFeedURL   = "https://h.m4a.cn/index.php?action=list&page=1&sort=new"
	defaultNeteaseVIPFeedLimit = 20
	neteaseVIPMaxBodyBytes     = 2 << 20
)

var (
	errNoNeteaseVIPLinks       = errors.New("网易云会员领取列表没有可用链接")
	errInvalidNeteaseVIPLink   = errors.New("网易云会员领取链接不合法")
	errNeteaseVIPClaimRejected = errors.New("网易云会员领取站点拒绝请求")
)

type neteaseVIPInvitation struct {
	ID        string
	CreatedAt int64
}

type neteaseVIPFeedItem struct {
	ID        string `json:"id"`
	CreatedAt int64  `json:"created_at"`
}

type neteaseVIPFeedResponse struct {
	OK      bool                 `json:"ok"`
	Message string               `json:"message"`
	Items   []neteaseVIPFeedItem `json:"items"`
}

type neteaseVIPFeedClient struct {
	endpoint   string
	httpClient *http.Client
	maxItems   int
}

func newNeteaseVIPFeedClient(endpoint string, timeout time.Duration, maxItems int) *neteaseVIPFeedClient {
	if strings.TrimSpace(endpoint) == "" {
		endpoint = defaultNeteaseVIPFeedURL
	}
	if timeout <= 0 {
		timeout = defaultRequestTimeout
	}
	if maxItems <= 0 {
		maxItems = defaultNeteaseVIPFeedLimit
	}
	return &neteaseVIPFeedClient{
		endpoint:   endpoint,
		httpClient: &http.Client{Timeout: timeout},
		maxItems:   maxItems,
	}
}

func (c *neteaseVIPFeedClient) fetch(ctx context.Context) ([]neteaseVIPInvitation, error) {
	if c == nil || c.httpClient == nil {
		return nil, errors.New("网易云会员领取列表客户端未初始化")
	}
	endpoint, err := url.Parse(c.endpoint)
	if err != nil || endpoint.Host == "" || (endpoint.Scheme != "http" && endpoint.Scheme != "https") {
		return nil, fmt.Errorf("网易云会员领取列表地址不合法: %q", c.endpoint)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return nil, fmt.Errorf("创建网易云会员领取列表请求: %w", err)
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("User-Agent", "oo-music/1.0")
	response, err := c.httpClient.Do(request)
	if err != nil {
		return nil, fmt.Errorf("请求网易云会员领取列表: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		return nil, fmt.Errorf("网易云会员领取列表返回 HTTP %d", response.StatusCode)
	}
	var payload neteaseVIPFeedResponse
	if err := json.NewDecoder(io.LimitReader(response.Body, neteaseVIPMaxBodyBytes)).Decode(&payload); err != nil {
		return nil, fmt.Errorf("解析网易云会员领取列表: %w", err)
	}
	if !payload.OK {
		if strings.TrimSpace(payload.Message) == "" {
			return nil, errNeteaseVIPClaimRejected
		}
		return nil, fmt.Errorf("%w: %s", errNeteaseVIPClaimRejected, strings.TrimSpace(payload.Message))
	}
	ordered := append([]neteaseVIPFeedItem(nil), payload.Items...)
	sort.SliceStable(ordered, func(i, j int) bool { return ordered[i].CreatedAt > ordered[j].CreatedAt })
	seen := make(map[string]struct{})
	result := make([]neteaseVIPInvitation, 0, min(len(ordered), c.maxItems))
	for _, item := range ordered {
		id := strings.TrimSpace(item.ID)
		if id == "" {
			continue
		}
		if _, exists := seen[id]; exists {
			continue
		}
		seen[id] = struct{}{}
		result = append(result, neteaseVIPInvitation{ID: id, CreatedAt: item.CreatedAt})
		if len(result) >= c.maxItems {
			break
		}
	}
	if len(result) == 0 {
		return nil, errNoNeteaseVIPLinks
	}
	return result, nil
}

type neteaseVIPClaimLink struct {
	OfficialURL string
	Token       string
}

type neteaseVIPClaimClient struct {
	httpClient    *http.Client
	claimEndpoint string
	shortBaseURL  string
	shortHost     string
	userAgent     string
}

func newNeteaseVIPClaimClient(timeout time.Duration) *neteaseVIPClaimClient {
	if timeout <= 0 {
		timeout = defaultRequestTimeout
	}
	return &neteaseVIPClaimClient{
		httpClient:    &http.Client{Timeout: timeout},
		claimEndpoint: "https://h.m4a.cn/index.php?action=claim",
		shortBaseURL:  "https://h.m4a.cn",
		shortHost:     "h.m4a.cn",
		userAgent:     "oo-music/1.0",
	}
}

func (c *neteaseVIPClaimClient) claim(ctx context.Context, invitationID string) (neteaseVIPClaimLink, error) {
	if c == nil || c.httpClient == nil {
		return neteaseVIPClaimLink{}, errors.New("网易云会员领取客户端未初始化")
	}
	invitationID = strings.TrimSpace(invitationID)
	if invitationID == "" {
		return neteaseVIPClaimLink{}, errNoNeteaseVIPLinks
	}
	jar, err := cookiejar.New(nil)
	if err != nil {
		return neteaseVIPClaimLink{}, err
	}
	client := *c.httpClient
	client.Jar = jar
	base, err := url.Parse(strings.TrimRight(c.shortBaseURL, "/"))
	if err != nil || base.Host == "" {
		return neteaseVIPClaimLink{}, errors.New("网易云会员领取站点地址不合法")
	}
	homepage := base.ResolveReference(&url.URL{Path: "/"}).String()
	initRequest, err := http.NewRequestWithContext(ctx, http.MethodGet, homepage, nil)
	if err != nil {
		return neteaseVIPClaimLink{}, err
	}
	initRequest.Header.Set("User-Agent", c.userAgent)
	initResponse, err := client.Do(initRequest)
	if err != nil {
		return neteaseVIPClaimLink{}, fmt.Errorf("初始化网易云会员领取会话: %w", err)
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(initResponse.Body, 4096))
	_ = initResponse.Body.Close()
	if initResponse.StatusCode < http.StatusOK || initResponse.StatusCode >= http.StatusMultipleChoices {
		return neteaseVIPClaimLink{}, fmt.Errorf("初始化网易云会员领取会话返回 HTTP %d", initResponse.StatusCode)
	}

	claimPayload, err := c.postJSON(ctx, &client, c.claimEndpoint, map[string]any{"id": invitationID}, "https://h.m4a.cn/")
	if err != nil {
		return neteaseVIPClaimLink{}, fmt.Errorf("分配网易云会员短链: %w", err)
	}
	var claimResponse struct {
		OK  bool   `json:"ok"`
		URL string `json:"url"`
	}
	if err := json.Unmarshal(claimPayload, &claimResponse); err != nil {
		return neteaseVIPClaimLink{}, fmt.Errorf("解析网易云会员短链: %w", err)
	}
	if !claimResponse.OK || strings.TrimSpace(claimResponse.URL) == "" {
		return neteaseVIPClaimLink{}, errNeteaseVIPClaimRejected
	}
	shortURL, err := url.Parse(strings.TrimSpace(claimResponse.URL))
	if err != nil || !strings.EqualFold(shortURL.Hostname(), c.shortHost) || !strings.HasPrefix(shortURL.Path, "/d/") {
		return neteaseVIPClaimLink{}, errInvalidNeteaseVIPLink
	}
	code := path.Base(strings.TrimRight(shortURL.Path, "/"))
	if code == "" || code == "." || code == "/" {
		return neteaseVIPClaimLink{}, errInvalidNeteaseVIPLink
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, shortURL.String(), nil)
	if err != nil {
		return neteaseVIPClaimLink{}, err
	}
	request.Header.Set("User-Agent", c.userAgent)
	request.Header.Set("Referer", "https://h.m4a.cn/")
	response, err := client.Do(request)
	if err != nil {
		return neteaseVIPClaimLink{}, fmt.Errorf("打开网易云会员中转页: %w", err)
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, neteaseVIPMaxBodyBytes))
	_ = response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return neteaseVIPClaimLink{}, fmt.Errorf("网易云会员中转页返回 HTTP %d", response.StatusCode)
	}

	apiEndpoint := base.ResolveReference(&url.URL{Path: "/d/api.php"}).String()
	realPayload, err := c.postJSON(ctx, &client, apiEndpoint, map[string]any{"code": code}, shortURL.String())
	if err != nil {
		return neteaseVIPClaimLink{}, fmt.Errorf("解析网易云官方邀请链接: %w", err)
	}
	var realResponse struct {
		OK    bool   `json:"ok"`
		URL   string `json:"url"`
		Quota *struct {
			Allowed bool `json:"allowed"`
		} `json:"quota"`
	}
	if err := json.Unmarshal(realPayload, &realResponse); err != nil {
		return neteaseVIPClaimLink{}, fmt.Errorf("解析网易云官方邀请链接响应: %w", err)
	}
	if !realResponse.OK || strings.TrimSpace(realResponse.URL) == "" || (realResponse.Quota != nil && !realResponse.Quota.Allowed) {
		return neteaseVIPClaimLink{}, errNeteaseVIPClaimRejected
	}
	officialURL, err := url.Parse(strings.TrimSpace(realResponse.URL))
	if err != nil || !strings.EqualFold(officialURL.Scheme, "https") || !strings.EqualFold(officialURL.Hostname(), "y.music.163.com") || !strings.HasPrefix(officialURL.Path, "/g/vip-invite-cashier/") {
		return neteaseVIPClaimLink{}, errInvalidNeteaseVIPLink
	}
	token := strings.TrimSpace(officialURL.Query().Get("token"))
	if token == "" {
		return neteaseVIPClaimLink{}, errInvalidNeteaseVIPLink
	}
	return neteaseVIPClaimLink{OfficialURL: officialURL.String(), Token: token}, nil
}

func (c *neteaseVIPClaimClient) postJSON(ctx context.Context, client *http.Client, endpoint string, payload map[string]any, referer string) ([]byte, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(string(body)))
	if err != nil {
		return nil, err
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("User-Agent", c.userAgent)
	if referer != "" {
		request.Header.Set("Referer", referer)
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, neteaseVIPMaxBodyBytes))
	if err != nil {
		return nil, err
	}
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return nil, fmt.Errorf("HTTP %d", response.StatusCode)
	}
	return raw, nil
}
