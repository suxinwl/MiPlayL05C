package oomusic

import (
	"fmt"
	"net/http"
	"net/url"

	"github.com/rankgice/oo-music/internal/signer"
)

// Client 是并发安全的 QQ 音乐接口客户端。
// 请先通过 NewClient 创建实例，再调用 Search、GetTrackInfo、CallQQ 等方法。
type Client struct {
	session    session
	httpClient *http.Client
	endpoint   *url.URL
	userAgent  string
	signer     *signer.Signer
}

// NewClient 创建 QQ 音乐客户端。不传选项时使用匿名模式并连接
// https://u6.y.qq.com。
func NewClient(options ...Option) (*Client, error) {
	config := clientOptions{
		httpClient: &http.Client{Timeout: defaultTimeout},
		endpoint:   mustParseURL(defaultEndpoint),
		userAgent:  defaultUserAgent,
	}
	for _, option := range options {
		if option == nil {
			continue
		}
		if err := option(&config); err != nil {
			return nil, fmt.Errorf("configure QQ Music client: %w", err)
		}
	}
	if config.userAgent == "" {
		config.userAgent = defaultUserAgent
	}
	signEngine, err := signer.New(config.userAgent)
	if err != nil {
		return nil, fmt.Errorf("create QQ Music client: %w", err)
	}
	return &Client{
		session:    config.session,
		httpClient: config.httpClient,
		endpoint:   config.endpoint,
		userAgent:  config.userAgent,
		signer:     signEngine,
	}, nil
}

// IsLoggedIn 判断客户端是否同时配置了 UIN 和 qm_keyst 登录凭据。
func (c *Client) IsLoggedIn() bool {
	return c.session.isLoggedIn()
}

func mustParseURL(raw string) *url.URL {
	parsed, err := url.Parse(raw)
	if err != nil {
		panic(err)
	}
	return parsed
}
