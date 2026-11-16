package netease

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"net/url"
	"strings"
)

const (
	weapiPresetKey = "0CoJUm6Qyw8W8jud"
	weapiIV        = "0102030405060708"
	weapiSecretLen = 16
)

var weapiRSAExponent = big.NewInt(65537)

var weapiRSAModulus = mustBigInt("00e0b509f6259df8642dbc3566290147" +
	"7df22677ec152b5ff68ace615bb7b725" +
	"152b3ab17a876aea8a5aa76d2e417629" +
	"ec4ee341f56135fccf695280104e0312" +
	"ecbda92557c93870114af6c9d05c4f7f" +
	"0c3685b7a46bee255932575cce10b424" +
	"d813cfe4875d3e82047b97ddef52741d" +
	"546b8e289dc6935b3ece0462db0a22b8e7")

func mustBigInt(value string) *big.Int {
	parsed, ok := new(big.Int).SetString(strings.TrimSpace(value), 16)
	if !ok {
		panic("invalid NetEase RSA modulus")
	}
	return parsed
}

func encryptWeapiPayload(data map[string]any) (url.Values, error) {
	secret, err := randomSecretKey(weapiSecretLen)
	if err != nil {
		return nil, err
	}
	return encryptWeapiPayloadWithSecret(data, secret)
}

func encryptWeapiPayloadWithSecret(data map[string]any, secret string) (url.Values, error) {
	if len(secret) != weapiSecretLen {
		return nil, fmt.Errorf("weapi secret length must be %d", weapiSecretLen)
	}
	raw, err := json.Marshal(data)
	if err != nil {
		return nil, fmt.Errorf("encode weapi payload: %w", err)
	}
	first, err := aesCBCBase64(raw, []byte(weapiPresetKey), []byte(weapiIV))
	if err != nil {
		return nil, err
	}
	params, err := aesCBCBase64([]byte(first), []byte(secret), []byte(weapiIV))
	if err != nil {
		return nil, err
	}
	encSecKey, err := rsaEncryptSecret(secret)
	if err != nil {
		return nil, err
	}
	return url.Values{
		"params":    []string{params},
		"encSecKey": []string{encSecKey},
	}, nil
}

func aesCBCBase64(plain, key, iv []byte) (string, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", fmt.Errorf("create weapi AES cipher: %w", err)
	}
	padded := pkcs7Pad(plain, block.BlockSize())
	ciphertext := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(ciphertext, padded)
	return base64.StdEncoding.EncodeToString(ciphertext), nil
}

func pkcs7Pad(value []byte, blockSize int) []byte {
	padding := blockSize - len(value)%blockSize
	return append(append([]byte(nil), value...), bytes.Repeat([]byte{byte(padding)}, padding)...)
}

func rsaEncryptSecret(secret string) (string, error) {
	reversed := []byte(secret)
	for left, right := 0, len(reversed)-1; left < right; left, right = left+1, right-1 {
		reversed[left], reversed[right] = reversed[right], reversed[left]
	}
	encrypted := new(big.Int).Exp(new(big.Int).SetBytes(reversed), weapiRSAExponent, weapiRSAModulus)
	return fmt.Sprintf("%0256s", hex.EncodeToString(encrypted.Bytes())), nil
}

func randomSecretKey(length int) (string, error) {
	const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	result := make([]byte, length)
	limit := big.NewInt(int64(len(alphabet)))
	for index := range result {
		value, err := rand.Int(rand.Reader, limit)
		if err != nil {
			return "", fmt.Errorf("generate weapi secret: %w", err)
		}
		result[index] = alphabet[value.Int64()]
	}
	return string(result), nil
}
