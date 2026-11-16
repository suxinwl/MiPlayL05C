package admin

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

const (
	passwordAlgorithm  = "pbkdf2-sha256"
	passwordIterations = 210_000
	passwordSaltBytes  = 16
	passwordKeyBytes   = 32
)

// HashPassword 使用 PBKDF2-HMAC-SHA256 和随机盐生成不可逆密码摘要。
// 返回值可以直接保存到数据库，格式不会包含明文密码。
func HashPassword(password string) (string, error) {
	if len(password) < 8 {
		return "", errors.New("后台用户密码至少需要 8 个字符")
	}
	if len(password) > 128 {
		return "", errors.New("后台用户密码不能超过 128 个字符")
	}
	salt := make([]byte, passwordSaltBytes)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("生成密码随机盐: %w", err)
	}
	key := pbkdf2SHA256([]byte(password), salt, passwordIterations, passwordKeyBytes)
	return fmt.Sprintf(
		"%s$%d$%s$%s",
		passwordAlgorithm,
		passwordIterations,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(key),
	), nil
}

// VerifyPassword 使用常量时间比较验证密码摘要，避免直接比较明文密码。
func VerifyPassword(encoded, password string) (bool, error) {
	parts := strings.Split(encoded, "$")
	if len(parts) != 4 || parts[0] != passwordAlgorithm {
		return false, errors.New("不支持的密码摘要格式")
	}
	iterations, err := strconv.Atoi(parts[1])
	if err != nil || iterations < 10_000 || iterations > 2_000_000 {
		return false, errors.New("密码摘要迭代次数不合法")
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[2])
	if err != nil || len(salt) < 8 {
		return false, errors.New("密码摘要随机盐不合法")
	}
	expected, err := base64.RawStdEncoding.DecodeString(parts[3])
	if err != nil || len(expected) < 16 {
		return false, errors.New("密码摘要不合法")
	}
	actual := pbkdf2SHA256([]byte(password), salt, iterations, len(expected))
	return subtle.ConstantTimeCompare(actual, expected) == 1, nil
}

func pbkdf2SHA256(password, salt []byte, iterations, keyLength int) []byte {
	hashLength := sha256.Size
	blockCount := (keyLength + hashLength - 1) / hashLength
	result := make([]byte, 0, blockCount*hashLength)
	block := make([]byte, 4)
	for blockIndex := 1; blockIndex <= blockCount; blockIndex++ {
		block[0] = byte(blockIndex >> 24)
		block[1] = byte(blockIndex >> 16)
		block[2] = byte(blockIndex >> 8)
		block[3] = byte(blockIndex)
		mac := hmac.New(sha256.New, password)
		_, _ = mac.Write(salt)
		_, _ = mac.Write(block)
		u := mac.Sum(nil)
		t := append([]byte(nil), u...)
		for iteration := 1; iteration < iterations; iteration++ {
			mac = hmac.New(sha256.New, password)
			_, _ = mac.Write(u)
			u = mac.Sum(nil)
			for index := range t {
				t[index] ^= u[index]
			}
		}
		result = append(result, t...)
	}
	return result[:keyLength]
}
