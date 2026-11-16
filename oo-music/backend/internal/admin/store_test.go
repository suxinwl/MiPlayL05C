package admin

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
)

func openAdminTestStore(t *testing.T) *Store {
	t.Helper()
	store, err := Open(filepath.Join(t.TempDir(), "admin.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := store.Close(); err != nil {
			t.Errorf("close admin store: %v", err)
		}
	})
	return store
}

func TestEnsureInitialUserOnlyCreatesWhenTableIsEmpty(t *testing.T) {
	store := openAdminTestStore(t)
	ctx := context.Background()

	created, first, err := store.EnsureInitialUser(ctx, "admin", "strong-password")
	if err != nil {
		t.Fatal(err)
	}
	if !created || first.ID <= 0 || first.Username != "admin" {
		t.Fatalf("unexpected initial user result: created=%v user=%+v", created, first)
	}

	created, user, err := store.EnsureInitialUser(ctx, "another-admin", "another-password")
	if err != nil {
		t.Fatal(err)
	}
	if created || user.ID != 0 {
		t.Fatalf("must not create another user when table has data: created=%v user=%+v", created, user)
	}
	count, err := store.CountUsers(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("unexpected admin count: %d", count)
	}
}

func TestCreateUserUsesCaseInsensitiveUniqueUsername(t *testing.T) {
	store := openAdminTestStore(t)
	ctx := context.Background()
	hash, err := HashPassword("strong-password")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.CreateUser(ctx, "Admin", hash); err != nil {
		t.Fatal(err)
	}
	_, err = store.CreateUser(ctx, "admin", hash)
	if !errors.Is(err, ErrUsernameExists) {
		t.Fatalf("expected case-insensitive duplicate error, got %v", err)
	}
}

func TestDeleteUserIfNotLastProtectsFinalAdministrator(t *testing.T) {
	store := openAdminTestStore(t)
	ctx := context.Background()
	hash, err := HashPassword("strong-password")
	if err != nil {
		t.Fatal(err)
	}
	first, err := store.CreateUser(ctx, "admin-one", hash)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.DeleteUserIfNotLast(ctx, first.ID); !errors.Is(err, ErrLastAdmin) {
		t.Fatalf("expected ErrLastAdmin, got %v", err)
	}
	second, err := store.CreateUser(ctx, "admin-two", hash)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.DeleteUserIfNotLast(ctx, first.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.UserByID(ctx, first.ID); !errors.Is(err, ErrUserNotFound) {
		t.Fatalf("expected deleted user to disappear, got %v", err)
	}
	if err := store.DeleteUserIfNotLast(ctx, second.ID); !errors.Is(err, ErrLastAdmin) {
		t.Fatalf("expected final administrator protection, got %v", err)
	}
}

func TestPublicAPIAuthSettingDefaultsToDisabledAndPersistsChanges(t *testing.T) {
	store := openAdminTestStore(t)
	ctx := context.Background()

	required, err := store.PublicAPIAuthRequired(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if required {
		t.Fatal("public API authentication must default to disabled")
	}

	if err := store.SetPublicAPIAuthRequired(ctx, true); err != nil {
		t.Fatal(err)
	}
	required, err = store.PublicAPIAuthRequired(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !required {
		t.Fatal("public API authentication setting was not persisted")
	}

	if err := store.SetPublicAPIAuthRequired(ctx, false); err != nil {
		t.Fatal(err)
	}
	required, err = store.PublicAPIAuthRequired(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if required {
		t.Fatal("public API authentication setting was not disabled")
	}
}
