package netease

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"net/url"
	"strings"
	"testing"
)

func TestEncryptWeapiPayloadRoundTripsWithKnownSecret(t *testing.T) {
	values, err := encryptWeapiPayloadWithSecret(map[string]any{"s": "晴天", "type": 1}, "abcdefghijklmnop")
	if err != nil {
		t.Fatal(err)
	}
	first, err := decryptCBCBase64(values.Get("params"), []byte("abcdefghijklmnop"), []byte(weapiIV))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := decryptCBCBase64(string(first), []byte(weapiPresetKey), []byte(weapiIV))
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded["s"] != "晴天" {
		t.Fatalf("unexpected payload: %v", decoded)
	}
	if len(values.Get("encSecKey")) != 256 {
		t.Fatalf("unexpected encSecKey length: %d", len(values.Get("encSecKey")))
	}
}

func TestWeapiURLRewritesAPIPath(t *testing.T) {
	got, err := url.Parse(weapiURL("https://music.163.com", "/api/w/nuser/account/get"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(got.Path, "/weapi/w/nuser/account/get") {
		t.Fatalf("unexpected URL: %s", got.String())
	}
}

func decryptCBCBase64(encoded string, key, iv []byte) ([]byte, error) {
	raw, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	plain := make([]byte, len(raw))
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(plain, raw)
	padding := int(plain[len(plain)-1])
	return plain[:len(plain)-padding], nil
}
