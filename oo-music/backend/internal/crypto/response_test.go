package crypto

import (
	"bytes"
	"encoding/json"
	"os"
	"testing"
)

func TestDecodeKnownResponse(t *testing.T) {
	wire, err := os.ReadFile("testdata/live_search_response.bin")
	if err != nil {
		t.Fatal(err)
	}
	plain, err := DecodeResponse(wire)
	if err != nil {
		t.Fatal(err)
	}
	if !json.Valid(plain) || !bytes.HasPrefix(plain, []byte(`{"code":0,`)) {
		t.Fatalf("unexpected decoded response: %q", plain)
	}
}

func TestResponseRoundTrip(t *testing.T) {
	plain := []byte(`{"code":0,"req_1":{"code":0,"data":{"ok":true}}}`)
	wire, err := EncodeResponse(plain)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(wire, plain) {
		t.Fatal("response mask did not change the payload")
	}
	decoded, err := DecodeResponse(wire)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(decoded, plain) {
		t.Fatalf("response round trip mismatch: %q", decoded)
	}
}
