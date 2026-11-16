package crypto

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"testing"
)

func TestKnownEncryptVector(t *testing.T) {
	nonce, err := hex.DecodeString("fb6ca228cc541e30a165cf22")
	if err != nil {
		t.Fatal(err)
	}
	got, err := EncryptWithNonce([]byte(`{"a":1}`), nonce)
	if err != nil {
		t.Fatal(err)
	}
	const want = "+2yiKMxUHjChZc8ic8luX6xEbyRFuNb/MNO1xbV/oUJvQeo="
	if got != want {
		t.Fatalf("encrypted payload mismatch\n got: %s\nwant: %s", got, want)
	}
}

func TestRoundTrip(t *testing.T) {
	plain := []byte(`{"comm":{"ct":24},"req_1":{"module":"x","method":"y","param":{}}}`)
	encrypted, err := Encrypt(plain)
	if err != nil {
		t.Fatal(err)
	}
	decrypted, err := DecryptBase64(encrypted)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(decrypted, plain) {
		t.Fatalf("round trip mismatch: %q", decrypted)
	}
}

func TestKnownDecryptVector(t *testing.T) {
	const encoded = "+2yiKMxUHjChZc8ic8luX6xEbyRFuNb/MNO1xbV/oUJvQeo="
	wire, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatal(err)
	}
	plain, err := Decrypt(wire)
	if err != nil {
		t.Fatal(err)
	}
	if string(plain) != `{"a":1}` {
		t.Fatalf("unexpected plaintext %q", plain)
	}
}

func TestInvalidNonceLength(t *testing.T) {
	if _, err := EncryptWithNonce([]byte("x"), []byte("short")); err == nil {
		t.Fatal("expected an invalid nonce error")
	}
}
