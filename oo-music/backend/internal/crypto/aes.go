// Package crypto 实现 QQ 音乐 musics.fcg 使用的请求 AES-GCM 封装
// 与响应循环异或解包。
package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
)

const (
	keyHex     = "bd305f10d0ff74b6ef54dab835b5e1cf"
	nonceSize  = 12
	tagSize    = 16
	minWireLen = nonceSize + tagSize
)

// Encrypt 使用新的 12 字节 nonce 加密明文，返回
// base64(nonce || ciphertext || tag)。
func Encrypt(plaintext []byte) (string, error) {
	nonce := make([]byte, nonceSize)
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return "", fmt.Errorf("generate AES-GCM nonce: %w", err)
	}
	return EncryptWithNonce(plaintext, nonce)
}

// EncryptWithNonce 使用指定的 12 字节 nonce 加密明文，
// 主要用于可复现的协议测试。
func EncryptWithNonce(plaintext, nonce []byte) (string, error) {
	if len(nonce) != nonceSize {
		return "", fmt.Errorf("invalid AES-GCM nonce length %d", len(nonce))
	}
	aead, err := newGCM()
	if err != nil {
		return "", err
	}
	sealed := aead.Seal(nil, nonce, plaintext, nil)
	wire := make([]byte, 0, len(nonce)+len(sealed))
	wire = append(wire, nonce...)
	wire = append(wire, sealed...)
	return base64.StdEncoding.EncodeToString(wire), nil
}

// Decrypt 解密 musics.fcg 请求侧的 nonce || ciphertext || tag 字节。
func Decrypt(wire []byte) ([]byte, error) {
	if len(wire) < minWireLen {
		return nil, fmt.Errorf("encrypted response too short: %d bytes", len(wire))
	}
	aead, err := newGCM()
	if err != nil {
		return nil, err
	}
	nonce := wire[:nonceSize]
	ciphertext := wire[nonceSize:]
	plaintext, err := aead.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return nil, fmt.Errorf("decrypt AES-GCM response: %w", err)
	}
	return plaintext, nil
}

// DecryptBase64 解码并解密 base64(nonce || ciphertext || tag)。
func DecryptBase64(encoded string) ([]byte, error) {
	wire, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, fmt.Errorf("decode AES-GCM payload: %w", err)
	}
	return Decrypt(wire)
}

func newGCM() (cipher.AEAD, error) {
	key, err := hex.DecodeString(keyHex)
	if err != nil {
		return nil, errors.New("invalid embedded AES key")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("create AES cipher: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("create AES-GCM cipher: %w", err)
	}
	return aead, nil
}
