// Package signer 运行从 numb747/qq-music-api-Reverse 提取的 QQ 音乐网页签名函数。
// JavaScript VM 已内嵌，运行时不需要安装 Node.js。
package signer

import (
	_ "embed"
	"errors"
	"fmt"
	"sync"

	"github.com/dop251/goja"
)

const (
	defaultUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/146.0.0.0"
	prelude          = `var e=globalThis, ne=globalThis, oe=globalThis, self=globalThis, window=globalThis;
var re=function(e){return e&&"undefined"!=typeof Symbol&&e.constructor===Symbol?"symbol":typeof e};
`
)

//go:embed sign_vmp.js
var signSource string

// Signer 是内嵌 VMP 签名函数的并发安全封装。
// goja Runtime 不支持并发使用，因此保留单个 VM 并通过互斥锁串行调用。
type Signer struct {
	mu       sync.Mutex
	vm       *goja.Runtime
	signFunc goja.Callable
}

// New 创建签名器，并注入 VMP 代码所需的浏览器环境。
func New(userAgent string) (*Signer, error) {
	if userAgent == "" {
		userAgent = defaultUserAgent
	}
	vm := goja.New()
	if err := installBrowserEnvironment(vm, userAgent); err != nil {
		return nil, err
	}
	if _, err := vm.RunString(prelude + signSource); err != nil {
		return nil, fmt.Errorf("initialize QQ Music signer: %w", err)
	}
	fn, ok := goja.AssertFunction(vm.Get("_getSecuritySign"))
	if !ok {
		return nil, errors.New("initialize QQ Music signer: _getSecuritySign is not callable")
	}
	return &Signer{vm: vm, signFunc: fn}, nil
}

// Sign 为完全一致的明文请求体计算 QQ 音乐安全签名。
func (s *Signer) Sign(plaintext string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	value, err := s.signFunc(s.vm.GlobalObject(), s.vm.ToValue(plaintext))
	if err != nil {
		return "", fmt.Errorf("compute QQ Music security signature: %w", err)
	}
	signature := value.String()
	if signature == "" {
		return "", errors.New("compute QQ Music security signature: empty result")
	}
	return signature, nil
}

func installBrowserEnvironment(vm *goja.Runtime, userAgent string) error {
	if err := vm.Set("navigator", map[string]any{
		"userAgent": userAgent,
		"platform":  "Win32",
	}); err != nil {
		return fmt.Errorf("install signer navigator: %w", err)
	}
	if err := vm.Set("location", map[string]any{
		"href":     "https://y.qq.com/",
		"protocol": "https:",
		"host":     "y.qq.com",
	}); err != nil {
		return fmt.Errorf("install signer location: %w", err)
	}

	element := vm.NewObject()
	document := vm.NewObject()
	if err := document.Set("createElement", func() *goja.Object { return element }); err != nil {
		return fmt.Errorf("install signer document.createElement: %w", err)
	}
	if err := document.Set("documentElement", element); err != nil {
		return fmt.Errorf("install signer document.documentElement: %w", err)
	}
	if err := document.Set("body", element); err != nil {
		return fmt.Errorf("install signer document.body: %w", err)
	}
	if err := document.Set("getElementsByTagName", func() []*goja.Object { return []*goja.Object{element} }); err != nil {
		return fmt.Errorf("install signer document.getElementsByTagName: %w", err)
	}
	if err := document.Set("addEventListener", func() {}); err != nil {
		return fmt.Errorf("install signer document.addEventListener: %w", err)
	}
	if err := vm.Set("document", document); err != nil {
		return fmt.Errorf("install signer document: %w", err)
	}
	return nil
}
