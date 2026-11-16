package oomusic

import (
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	defaultEndpoint  = "https://u6.y.qq.com"
	defaultUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/146.0.0.0"
	defaultTimeout   = 30 * time.Second
)

// Option 配置通过 NewClient 创建的 Client。
type Option func(*clientOptions) error

type clientOptions struct {
	session    session
	httpClient *http.Client
	endpoint   *url.URL
	userAgent  string
}

// WithCredentials 配置 QQ 音乐网页端的 UIN 和 qm_keyst 登录凭据。
// 两项均传空字符串时使用匿名公开接口。
func WithCredentials(uin, qmKeyst string) Option {
	return func(options *clientOptions) error {
		uin = strings.TrimSpace(uin)
		qmKeyst = strings.TrimSpace(qmKeyst)
		if (uin == "") != (qmKeyst == "") {
			return errors.New("uin and qmKeyst must be provided together")
		}
		options.session = session{uin: uin, qmKeyst: qmKeyst}
		return nil
	}
}

// WithHTTPClient 设置自定义 HTTP 客户端；传入 nil 会返回配置错误。
func WithHTTPClient(client *http.Client) Option {
	return func(options *clientOptions) error {
		if client == nil {
			return errors.New("http client must not be nil")
		}
		options.httpClient = client
		return nil
	}
}

// WithEndpoint 修改 QQ 音乐基础地址，主要用于测试或切换腾讯官方边缘节点。
func WithEndpoint(endpoint string) Option {
	return func(options *clientOptions) error {
		parsed, err := url.Parse(strings.TrimSpace(endpoint))
		if err != nil {
			return err
		}
		if parsed.Scheme != "https" && parsed.Scheme != "http" {
			return errors.New("endpoint scheme must be http or https")
		}
		if parsed.Host == "" {
			return errors.New("endpoint host must not be empty")
		}
		options.endpoint = parsed
		return nil
	}
}

// WithUserAgent 修改请求头及签名器浏览器环境使用的 User-Agent。
// 传入空字符串时恢复 SDK 默认值。
func WithUserAgent(userAgent string) Option {
	return func(options *clientOptions) error {
		options.userAgent = strings.TrimSpace(userAgent)
		return nil
	}
}

// WithRequestTimeout 设置 SDK 创建的 HTTP 客户端超时时间。
// 若通过 WithHTTPClient 提供的客户端已设置超时，则保留其原值。
func WithRequestTimeout(timeout time.Duration) Option {
	return func(options *clientOptions) error {
		if timeout <= 0 {
			return errors.New("request timeout must be greater than zero")
		}
		if options.httpClient == nil {
			options.httpClient = &http.Client{Timeout: timeout}
		} else if options.httpClient.Timeout == 0 {
			options.httpClient.Timeout = timeout
		}
		return nil
	}
}
