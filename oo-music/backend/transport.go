package oomusic

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	qqcrypto "github.com/rankgice/oo-music/internal/crypto"
)

const maxResponseBytes = 32 << 20

// CallRequest 描述批量请求中的一个 QQ 音乐模块方法调用。
type CallRequest struct {
	// Module 是 QQ 音乐 CGI 模块名，例如 "music.search.SearchCgiService"。
	Module string `json:"module"`
	// Method 是 CGI 模块中的方法名。
	Method string `json:"method"`
	// Param 会被编码为该方法的 JSON 参数对象。
	Param any `json:"param"`
}

// CallResult 表示单个 req_N 请求的解密响应。
type CallResult struct {
	// Module 是发起该请求时 CallRequest 中的模块名。
	Module string
	// Method 是发起该请求时 CallRequest 中的方法名。
	Method string
	// Code 是该请求返回的业务状态码。
	Code int `json:"code"`
	// Data 是接口返回的原始 JSON 数据对象。
	Data json.RawMessage `json:"data"`
	// Raw 是完整的 req_N 响应 JSON。
	Raw json.RawMessage `json:"-"`
}

// BatchResult 表示解码后的 musics.fcg 批量响应。
type BatchResult struct {
	// Code 是顶层响应码，0 表示协议层调用成功。
	Code int `json:"code"`
	// Results 将 req_1 等请求键映射到对应响应。
	Results map[string]*CallResult
	// Raw 是完整的解密响应 JSON。
	Raw json.RawMessage
}

// APIError 表示 QQ 音乐返回了非零顶层响应码。
type APIError struct {
	// Code 是腾讯接口返回的顶层错误码。
	Code int
	// Raw 是完整的解密响应，受传输层大小上限约束。
	Raw json.RawMessage
}

// Error 实现 error 接口。
func (e *APIError) Error() string {
	return fmt.Sprintf("QQ Music API returned top-level code %d", e.Code)
}

// CallQQ 调用一个 QQ 音乐模块方法并返回解密后的数据。
// Param 可以是结构体、map 或 json.RawMessage；nil 会编码为 {}。
func (c *Client) CallQQ(ctx context.Context, module, method string, param any) (*CallResult, error) {
	result, err := c.CallBatch(ctx, map[string]CallRequest{
		"req_1": {Module: module, Method: method, Param: param},
	})
	if err != nil {
		return nil, err
	}
	call, ok := result.Results["req_1"]
	if !ok {
		return nil, errors.New("QQ Music response is missing req_1")
	}
	return call, nil
}

// callMusicU 调用新版未加密的 musicu.fcg CGI 接口。
//
// 部分网页端 RPC 已从 musics.fcg 迁移到 musicu.fcg，且参数中的数字 ID
// 必须保持 JSON number 类型。该方法只供包内迁移后的接口使用，响应仍复用
// 与批量接口一致的 CallResult 结构。
func (c *Client) callMusicU(ctx context.Context, module, method string, param any) (*CallResult, error) {
	request := CallRequest{Module: module, Method: method, Param: param}
	if request.Param == nil {
		request.Param = map[string]any{}
	}
	if strings.TrimSpace(request.Module) == "" {
		return nil, errors.New("QQ Music request has an empty module")
	}
	if strings.TrimSpace(request.Method) == "" {
		return nil, errors.New("QQ Music request has an empty method")
	}

	gtk := c.session.gtkForMusicAPI()
	envelope := map[string]any{
		"comm": map[string]any{
			"ct":                24,
			"cv":                4747474,
			"platform":          "yqq.json",
			"format":            "json",
			"inCharset":         "utf-8",
			"outCharset":        "utf-8",
			"notice":            0,
			"need_new_code":     1,
			"uin":               c.session.uin,
			"g_tk":              gtk,
			"g_tk_new_20200303": gtk,
		},
		"req_0": request,
	}
	plaintext, err := marshalJSON(envelope)
	if err != nil {
		return nil, fmt.Errorf("encode QQ Music musicu request: %w", err)
	}

	endpoint := *c.endpoint
	endpoint.Path = strings.TrimRight(endpoint.Path, "/") + "/cgi-bin/musicu.fcg"
	endpoint.RawQuery = ""
	httpRequest, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint.String(), bytes.NewReader(plaintext))
	if err != nil {
		return nil, fmt.Errorf("create QQ Music musicu request: %w", err)
	}
	httpRequest.Header.Set("Cookie", c.session.cookieHeader())
	httpRequest.Header.Set("Content-Type", "application/json")
	httpRequest.Header.Set("Origin", "https://y.qq.com")
	httpRequest.Header.Set("Referer", "https://y.qq.com/")
	httpRequest.Header.Set("Accept", "application/json")
	httpRequest.Header.Set("User-Agent", c.userAgent)

	response, err := c.httpClient.Do(httpRequest)
	if err != nil {
		return nil, fmt.Errorf("send QQ Music musicu request: %w", err)
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read QQ Music musicu response: %w", err)
	}
	if len(data) > maxResponseBytes {
		return nil, fmt.Errorf("QQ Music musicu response exceeds %d bytes", maxResponseBytes)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("QQ Music musicu HTTP status %d: %s", response.StatusCode, truncateForError(data))
	}

	requests := map[string]CallRequest{"req_0": request}
	result, err := decodeBatchResponse(data, requests)
	if err != nil {
		return nil, err
	}
	call, ok := result.Results["req_0"]
	if !ok {
		return nil, errors.New("QQ Music musicu response is missing req_0")
	}
	return call, nil
}

// CallBatch 在一次加密请求中调用多个模块方法。
// 请求键通常使用 req_1、req_2 等，"comm" 为保留键。
func (c *Client) CallBatch(ctx context.Context, requests map[string]CallRequest) (*BatchResult, error) {
	if len(requests) == 0 {
		return nil, errors.New("QQ Music batch must contain at least one request")
	}
	normalized := make(map[string]CallRequest, len(requests))
	keys := make([]string, 0, len(requests))
	for key, request := range requests {
		if strings.TrimSpace(key) == "" || key == "comm" {
			return nil, fmt.Errorf("invalid QQ Music request key %q", key)
		}
		if strings.TrimSpace(request.Module) == "" {
			return nil, fmt.Errorf("request %s has an empty module", key)
		}
		if strings.TrimSpace(request.Method) == "" {
			return nil, fmt.Errorf("request %s has an empty method", key)
		}
		if request.Param == nil {
			request.Param = map[string]any{}
		}
		normalized[key] = request
		keys = append(keys, key)
	}
	sort.Strings(keys)
	envelope := make(map[string]any, len(requests)+1)
	envelope["comm"] = c.session.common()
	for _, key := range keys {
		envelope[key] = normalized[key]
	}
	plaintext, err := marshalJSON(envelope)
	if err != nil {
		return nil, fmt.Errorf("encode QQ Music request: %w", err)
	}
	signature, err := c.signer.Sign(string(plaintext))
	if err != nil {
		return nil, err
	}
	encrypted, err := qqcrypto.Encrypt(plaintext)
	if err != nil {
		return nil, fmt.Errorf("encrypt QQ Music request: %w", err)
	}
	responseBody, err := c.postEncrypted(ctx, signature, encrypted)
	if err != nil {
		return nil, err
	}
	plainResponse, err := decodeResponseBody(responseBody)
	if err != nil {
		return nil, err
	}
	return decodeBatchResponse(plainResponse, normalized)
}

func (c *Client) postEncrypted(ctx context.Context, signature, body string) ([]byte, error) {
	endpoint := *c.endpoint
	endpoint.Path = strings.TrimRight(endpoint.Path, "/") + "/cgi-bin/musics.fcg"
	query := endpoint.Query()
	query.Set("_", strconv.FormatInt(time.Now().UnixMilli(), 10))
	query.Set("encoding", "ag-1")
	query.Set("sign", signature)
	endpoint.RawQuery = query.Encode()

	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint.String(), strings.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("create QQ Music request: %w", err)
	}
	request.Header.Set("Cookie", c.session.cookieHeader())
	request.Header.Set("Content-Type", "text/plain")
	request.Header.Set("Origin", "https://y.qq.com")
	request.Header.Set("Referer", "https://y.qq.com/")
	request.Header.Set("Accept", "application/octet-stream")
	request.Header.Set("User-Agent", c.userAgent)

	response, err := c.httpClient.Do(request)
	if err != nil {
		return nil, fmt.Errorf("send QQ Music request: %w", err)
	}
	defer response.Body.Close()
	limited := io.LimitReader(response.Body, maxResponseBytes+1)
	data, err := io.ReadAll(limited)
	if err != nil {
		return nil, fmt.Errorf("read QQ Music response: %w", err)
	}
	if len(data) > maxResponseBytes {
		return nil, fmt.Errorf("QQ Music response exceeds %d bytes", maxResponseBytes)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("QQ Music HTTP status %d: %s", response.StatusCode, truncateForError(data))
	}
	return data, nil
}

func decodeResponseBody(raw []byte) ([]byte, error) {
	if len(raw) == 0 {
		return nil, errors.New("QQ Music returned an empty response")
	}
	if plain := bytes.TrimSpace(raw); json.Valid(plain) {
		return plain, nil
	}
	plain, err := qqcrypto.DecodeResponse(raw)
	if err == nil {
		plain = bytes.TrimSpace(plain)
		if json.Valid(plain) {
			return plain, nil
		}
	}
	return nil, fmt.Errorf("decrypt QQ Music response: unsupported response encoding (%d bytes, prefix %x)", len(raw), truncatedBytes(raw, 32))
}

func decodeBatchResponse(data []byte, requests map[string]CallRequest) (*BatchResult, error) {
	var rawMap map[string]json.RawMessage
	if err := json.Unmarshal(data, &rawMap); err != nil {
		return nil, fmt.Errorf("decode QQ Music response: %w", err)
	}
	var top struct {
		Code int `json:"code"`
	}
	if codeRaw, ok := rawMap["code"]; ok {
		if err := json.Unmarshal(codeRaw, &top.Code); err != nil {
			return nil, fmt.Errorf("decode QQ Music top-level code: %w", err)
		}
	}
	result := &BatchResult{
		Code:    top.Code,
		Results: make(map[string]*CallResult),
		Raw:     data,
	}
	if top.Code != 0 {
		return result, &APIError{Code: top.Code, Raw: data}
	}
	for key, request := range requests {
		raw, ok := rawMap[key]
		if !ok {
			continue
		}
		call := &CallResult{Module: request.Module, Method: request.Method, Raw: raw}
		if err := json.Unmarshal(raw, call); err != nil {
			return nil, fmt.Errorf("decode QQ Music response %s: %w", key, err)
		}
		result.Results[key] = call
	}
	return result, nil
}

func marshalJSON(value any) ([]byte, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	return bytes.TrimSpace(buffer.Bytes()), nil
}

func truncatedBytes(data []byte, limit int) []byte {
	if len(data) > limit {
		return data[:limit]
	}
	return data
}

func truncateForError(data []byte) string {
	const limit = 256
	if len(data) <= limit {
		return string(data)
	}
	return string(data[:limit]) + "..."
}
