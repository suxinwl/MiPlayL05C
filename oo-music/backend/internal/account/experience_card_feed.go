package account

import (
	"bytes"
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

	oomusic "github.com/rankgice/oo-music"
)

const (
	defaultExperienceCardFeedURL       = "https://h.m4a.cn/index.php?action=qqmusic_list&page=1"
	defaultExperienceCardFeedLimit     = 20
	experienceCardFeedResponseMaxBytes = 2 << 20
)

var errNoExperienceCardLinks = errors.New("experience-card feed returned no valid QQ Music links")

// experienceCardCandidate 是尚未换出官方 cardid 的领取候选。
// Request 非空时可直接领取；FeedID 非空时需要由 Feed 客户端换取官方链接。
type experienceCardCandidate struct {
	FeedID  string
	Request oomusic.ExperienceCardRequest
}

type experienceCardFeedItem struct {
	ID        string `json:"id"`
	URL       string `json:"url"`
	Source    string `json:"source"`
	Title     string `json:"title"`
	CreatedAt int64  `json:"created_at"`
}

type experienceCardFeedResponse struct {
	OK      bool                     `json:"ok"`
	Message string                   `json:"message"`
	Items   []experienceCardFeedItem `json:"items"`
}

type experienceCardFeedClient struct {
	endpoint   string
	httpClient *http.Client
	maxItems   int
}

func newExperienceCardFeedClient(endpoint string, timeout time.Duration, maxItems int) *experienceCardFeedClient {
	if strings.TrimSpace(endpoint) == "" {
		endpoint = defaultExperienceCardFeedURL
	}
	if timeout <= 0 {
		timeout = defaultRequestTimeout
	}
	if maxItems <= 0 {
		maxItems = defaultExperienceCardFeedLimit
	}
	jar, _ := cookiejar.New(nil)
	return &experienceCardFeedClient{
		endpoint: endpoint,
		httpClient: &http.Client{
			Timeout: timeout,
			Jar:     jar,
		},
		maxItems: maxItems,
	}
}

func (c *experienceCardFeedClient) fetch(ctx context.Context) ([]experienceCardCandidate, error) {
	if c == nil || c.httpClient == nil {
		return nil, errors.New("experience-card feed client is not initialized")
	}
	endpoint, err := url.Parse(c.endpoint)
	if err != nil || endpoint.Host == "" || (endpoint.Scheme != "http" && endpoint.Scheme != "https") {
		return nil, fmt.Errorf("invalid experience-card feed endpoint: %q", c.endpoint)
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return nil, fmt.Errorf("create experience-card feed request: %w", err)
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("User-Agent", "oo-music/1.0")

	response, err := c.httpClient.Do(request)
	if err != nil {
		return nil, fmt.Errorf("request experience-card feed: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		return nil, fmt.Errorf("experience-card feed returned HTTP %d", response.StatusCode)
	}

	var payload experienceCardFeedResponse
	decoder := json.NewDecoder(io.LimitReader(response.Body, experienceCardFeedResponseMaxBytes))
	if err := decoder.Decode(&payload); err != nil {
		return nil, fmt.Errorf("decode experience-card feed: %w", err)
	}
	if !payload.OK {
		if strings.TrimSpace(payload.Message) == "" {
			return nil, errors.New("experience-card feed rejected the request")
		}
		return nil, fmt.Errorf("experience-card feed rejected the request: %s", strings.TrimSpace(payload.Message))
	}

	return normalizeExperienceCardFeedItems(payload.Items, c.maxItems)
}

// resolve 使用站点当前的两段式领取链路换取 y.qq.com 官方体验卡链接：
// 内部 ID -> 站点短链 -> /d/api.php -> 官方 cardid。
func (c *experienceCardFeedClient) resolve(ctx context.Context, feedID string) (oomusic.ExperienceCardRequest, error) {
	if c == nil || c.httpClient == nil {
		return oomusic.ExperienceCardRequest{}, errors.New("experience-card feed client is not initialized")
	}
	feedID = strings.TrimSpace(feedID)
	if feedID == "" {
		return oomusic.ExperienceCardRequest{}, errors.New("experience-card feed ID is empty")
	}
	endpoint, err := url.Parse(c.endpoint)
	if err != nil || endpoint.Host == "" || (endpoint.Scheme != "http" && endpoint.Scheme != "https") {
		return oomusic.ExperienceCardRequest{}, fmt.Errorf("invalid experience-card feed endpoint: %q", c.endpoint)
	}

	claimEndpoint := *endpoint
	query := claimEndpoint.Query()
	query.Set("action", "qqmusic_claim")
	claimEndpoint.RawQuery = query.Encode()

	var claimResponse struct {
		OK      bool   `json:"ok"`
		Message string `json:"message"`
		URL     string `json:"url"`
	}
	if err := c.postJSON(ctx, claimEndpoint.String(), endpoint.String(), map[string]string{"id": feedID}, &claimResponse); err != nil {
		return oomusic.ExperienceCardRequest{}, fmt.Errorf("resolve experience-card feed ID: %w", err)
	}
	if !claimResponse.OK {
		message := strings.TrimSpace(claimResponse.Message)
		if message == "" {
			message = "claim request rejected"
		}
		return oomusic.ExperienceCardRequest{}, fmt.Errorf("resolve experience-card feed ID: %s", message)
	}

	shortURL, err := url.Parse(strings.TrimSpace(claimResponse.URL))
	if err != nil || shortURL.Host == "" || (shortURL.Scheme != "http" && shortURL.Scheme != "https") {
		return oomusic.ExperienceCardRequest{}, errors.New("experience-card feed returned an invalid short link")
	}
	if !strings.EqualFold(shortURL.Hostname(), endpoint.Hostname()) {
		return oomusic.ExperienceCardRequest{}, fmt.Errorf("experience-card short link host %q is not trusted", shortURL.Hostname())
	}

	code := path.Base(strings.TrimSpace(shortURL.Path))
	if code == "" || code == "." || code == "/" {
		return oomusic.ExperienceCardRequest{}, errors.New("experience-card short link has no code")
	}

	// 中转页会设置短期 feed_seed Cookie，后续换链接口依赖该会话。
	pageRequest, err := http.NewRequestWithContext(ctx, http.MethodGet, shortURL.String(), nil)
	if err != nil {
		return oomusic.ExperienceCardRequest{}, fmt.Errorf("create experience-card short-link request: %w", err)
	}
	pageRequest.Header.Set("Accept", "text/html")
	pageRequest.Header.Set("User-Agent", "oo-music/1.0")
	pageRequest.Header.Set("Referer", endpoint.String())
	pageResponse, err := c.httpClient.Do(pageRequest)
	if err != nil {
		return oomusic.ExperienceCardRequest{}, fmt.Errorf("request experience-card short link: %w", err)
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(pageResponse.Body, experienceCardFeedResponseMaxBytes))
	_ = pageResponse.Body.Close()
	if pageResponse.StatusCode < http.StatusOK || pageResponse.StatusCode >= http.StatusMultipleChoices {
		return oomusic.ExperienceCardRequest{}, fmt.Errorf("experience-card short link returned HTTP %d", pageResponse.StatusCode)
	}

	realEndpoint := &url.URL{
		Scheme: endpoint.Scheme,
		Host:   endpoint.Host,
		Path:   "/d/api.php",
	}
	var realResponse struct {
		OK      bool   `json:"ok"`
		Message string `json:"message"`
		URL     string `json:"url"`
	}
	if err := c.postJSON(ctx, realEndpoint.String(), shortURL.String(), map[string]string{"code": code}, &realResponse); err != nil {
		return oomusic.ExperienceCardRequest{}, fmt.Errorf("exchange experience-card short link: %w", err)
	}
	if !realResponse.OK {
		message := strings.TrimSpace(realResponse.Message)
		if message == "" {
			message = "short-link exchange rejected"
		}
		return oomusic.ExperienceCardRequest{}, fmt.Errorf("exchange experience-card short link: %s", message)
	}

	officialURL, err := url.Parse(strings.TrimSpace(realResponse.URL))
	if err != nil || officialURL.Host == "" || (officialURL.Scheme != "http" && officialURL.Scheme != "https") {
		return oomusic.ExperienceCardRequest{}, errors.New("experience-card feed returned an invalid official link")
	}
	if !strings.EqualFold(officialURL.Hostname(), "y.qq.com") {
		return oomusic.ExperienceCardRequest{}, fmt.Errorf("experience-card official link host %q is not y.qq.com", officialURL.Hostname())
	}
	request, err := oomusic.ParseExperienceCardLink(officialURL.String())
	if err != nil {
		return oomusic.ExperienceCardRequest{}, fmt.Errorf("parse experience-card official link: %w", err)
	}
	return request, nil
}

func (c *experienceCardFeedClient) postJSON(ctx context.Context, target, referer string, value, out any) error {
	payload, err := json.Marshal(value)
	if err != nil {
		return fmt.Errorf("encode request: %w", err)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, target, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}
	endpoint, _ := url.Parse(c.endpoint)
	origin := ""
	if endpoint != nil && endpoint.Scheme != "" && endpoint.Host != "" {
		origin = endpoint.Scheme + "://" + endpoint.Host
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("User-Agent", "oo-music/1.0")
	if origin != "" {
		request.Header.Set("Origin", origin)
	}
	if strings.TrimSpace(referer) != "" {
		request.Header.Set("Referer", referer)
	}

	response, err := c.httpClient.Do(request)
	if err != nil {
		return fmt.Errorf("request failed: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		return fmt.Errorf("returned HTTP %d", response.StatusCode)
	}
	decoder := json.NewDecoder(io.LimitReader(response.Body, experienceCardFeedResponseMaxBytes))
	if err := decoder.Decode(out); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}
	return nil
}

func normalizeExperienceCardFeedItems(items []experienceCardFeedItem, limit int) ([]experienceCardCandidate, error) {
	ordered := append([]experienceCardFeedItem(nil), items...)
	sort.SliceStable(ordered, func(i, j int) bool {
		return ordered[i].CreatedAt > ordered[j].CreatedAt
	})

	candidates := make([]experienceCardCandidate, 0, min(len(ordered), max(limit, 0)))
	seen := make(map[string]struct{})
	var invalid []error
	for _, item := range ordered {
		if limit > 0 && len(candidates) >= limit {
			break
		}
		if source := strings.TrimSpace(item.Source); source != "" && !strings.EqualFold(source, "qqmusic") {
			continue
		}

		link := strings.TrimSpace(item.URL)
		if link != "" {
			parsed, err := url.Parse(link)
			if err != nil || !strings.EqualFold(parsed.Scheme, "https") || !strings.EqualFold(parsed.Hostname(), "y.qq.com") {
				invalid = append(invalid, fmt.Errorf("ignore non-official experience-card link %q", link))
			} else if request, parseErr := oomusic.ParseExperienceCardLink(link); parseErr != nil {
				invalid = append(invalid, parseErr)
			} else {
				key := "card:" + request.CardID
				if _, exists := seen[key]; !exists {
					seen[key] = struct{}{}
					candidates = append(candidates, experienceCardCandidate{Request: request})
				}
				continue
			}
		}

		feedID := strings.TrimSpace(item.ID)
		if feedID == "" {
			continue
		}
		key := "feed:" + feedID
		if _, exists := seen[key]; exists {
			continue
		}
		seen[key] = struct{}{}
		candidates = append(candidates, experienceCardCandidate{FeedID: feedID})
	}
	if len(candidates) == 0 {
		return nil, errors.Join(append([]error{errNoExperienceCardLinks}, invalid...)...)
	}
	return candidates, nil
}
