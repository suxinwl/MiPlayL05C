package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseEnvLine(t *testing.T) {
	tests := []struct {
		name      string
		line      string
		wantKey   string
		wantValue string
		wantOK    bool
		wantError bool
	}{
		{name: "plain", line: "OO_MUSIC_TEST_VALUE=12345", wantKey: "OO_MUSIC_TEST_VALUE", wantValue: "12345", wantOK: true},
		{name: "export and comment", line: `export TOKEN="abc=123" # note`, wantKey: "TOKEN", wantValue: "abc=123", wantOK: true},
		{name: "single quotes", line: "TOKEN='abc # 123'", wantKey: "TOKEN", wantValue: "abc # 123", wantOK: true},
		{name: "comment", line: "# ignored"},
		{name: "missing equals", line: "INVALID", wantError: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			key, value, ok, err := parseEnvLine(test.line)
			if (err != nil) != test.wantError {
				t.Fatalf("unexpected error: %v", err)
			}
			if key != test.wantKey || value != test.wantValue || ok != test.wantOK {
				t.Fatalf("got key=%q value=%q ok=%v", key, value, ok)
			}
		})
	}
}

func TestLoadEnvFileDoesNotOverwriteExistingValue(t *testing.T) {
	const key = "OO_MUSIC_TEST_ENV_VALUE"
	t.Setenv(key, "from-process")
	path := filepath.Join(t.TempDir(), ".env")
	if err := os.WriteFile(path, []byte(key+"=from-file\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := loadEnvFile(path); err != nil {
		t.Fatal(err)
	}
	if got := os.Getenv(key); got != "from-process" {
		t.Fatalf("environment was overwritten: %q", got)
	}
}
