package account

import (
	"os"
	"path/filepath"
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

func assertPrivateDatabasePermissions(t *testing.T, path string) {
	t.Helper()
	assertDatabaseACL(t, path, false)
}

func assertDatabaseACL(t *testing.T, path string, directory bool) {
	t.Helper()
	actual, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		t.Fatal(err)
	}
	control, _, err := actual.Control()
	if err != nil {
		t.Fatal(err)
	}
	if control&windows.SE_DACL_PROTECTED == 0 {
		t.Fatal("database ACL unexpectedly inherits unrelated parent permissions")
	}
	expected, err := privateDatabaseDescriptor(directory)
	if err != nil {
		t.Fatal(err)
	}
	assertSameDatabaseACEs(t, actual, expected, false)
}

// Compare ACEs, not the descriptor's auto-inheritance bookkeeping flags.
func assertSameDatabaseACEs(t *testing.T, actual, expected *windows.SECURITY_DESCRIPTOR, inherited bool) {
	t.Helper()
	actualACL, _, err := actual.DACL()
	if err != nil || actualACL == nil {
		t.Fatal("database must not have a missing or null DACL")
	}
	expectedACL, _, err := expected.DACL()
	if err != nil {
		t.Fatal(err)
	}
	if actualACL.AceCount != expectedACL.AceCount {
		t.Fatal("database ACL contains an unexpected principal")
	}
	for i := uint32(0); i < uint32(actualACL.AceCount); i++ {
		var actualACE, expectedACE *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(actualACL, i, &actualACE); err != nil {
			t.Fatal(err)
		}
		if err := windows.GetAce(expectedACL, i, &expectedACE); err != nil {
			t.Fatal(err)
		}
		actualSID := (*windows.SID)(unsafe.Pointer(&actualACE.SidStart))
		expectedSID := (*windows.SID)(unsafe.Pointer(&expectedACE.SidStart))
		flags := expectedACE.Header.AceFlags
		if inherited {
			flags |= windows.INHERITED_ACE
		}
		if actualACE.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE ||
			actualACE.Header.AceFlags != flags || actualACE.Mask != expectedACE.Mask ||
			!actualSID.Equals(expectedSID) {
			t.Fatal("database ACL must grant access only to the current user, SYSTEM, and administrators")
		}
	}
}

func TestNewDatabaseDirectoryHasPrivateInheritableACL(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "private-data")
	path := filepath.Join(directory, "accounts.db")
	store, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	assertDatabaseACL(t, directory, true)
	assertDatabaseACL(t, path, false)
	// Sidecars inherit the private new directory, not a broad project ACL.
	for _, suffix := range []string{"-wal", "-shm"} {
		if _, err := os.Stat(path + suffix); err != nil {
			t.Fatalf("SQLite sidecar missing: %v", err)
		}
		descriptor, err := windows.GetNamedSecurityInfo(path+suffix, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
		if err != nil {
			t.Fatal(err)
		}
		expected, err := privateDatabaseDescriptor(false)
		if err != nil {
			t.Fatal(err)
		}
		assertSameDatabaseACEs(t, descriptor, expected, true)
	}
}

func TestDatabaseOpenDoesNotChangeExistingParentACL(t *testing.T) {
	directory := t.TempDir()
	before, err := windows.GetNamedSecurityInfo(directory, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		t.Fatal(err)
	}
	store, err := Open(filepath.Join(directory, "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	after, err := windows.GetNamedSecurityInfo(directory, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		t.Fatal(err)
	}
	if before.String() != after.String() {
		t.Fatal("opening a database must not change an existing parent directory ACL")
	}
}
