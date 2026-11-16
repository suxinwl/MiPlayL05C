//go:build !windows

package account

import (
	"os"
	"testing"
)

func assertPrivateDatabasePermissions(t *testing.T, path string) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("unexpected database permissions: %o", info.Mode().Perm())
	}
}
