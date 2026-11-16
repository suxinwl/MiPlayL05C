package admin

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestAuthLoginAuthenticateLogoutAndExpiry(t *testing.T) {
	store := openAdminTestStore(t)
	ctx := context.Background()
	hash, err := HashPassword("correct-password")
	if err != nil {
		t.Fatal(err)
	}
	user, err := store.CreateUser(ctx, "admin", hash)
	if err != nil {
		t.Fatal(err)
	}

	auth, err := NewAuthService(store, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 27, 8, 0, 0, 0, time.UTC)
	auth.now = func() time.Time { return now }

	session, err := auth.Login(ctx, "ADMIN", "correct-password")
	if err != nil {
		t.Fatal(err)
	}
	if session.Token == "" || session.User.ID != user.ID || !session.ExpiresAt.Equal(now.Add(time.Hour)) {
		t.Fatalf("unexpected session: %+v", session)
	}
	authenticated, err := auth.Authenticate(session.Token)
	if err != nil {
		t.Fatal(err)
	}
	if authenticated.User.ID != user.ID {
		t.Fatalf("authenticated wrong user: %+v", authenticated)
	}
	if _, err := auth.Login(ctx, "admin", "wrong-password"); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("expected invalid credentials, got %v", err)
	}
	if _, err := auth.Login(ctx, "missing", "wrong-password"); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("expected generic invalid credentials, got %v", err)
	}

	auth.Logout(session.Token)
	if _, err := auth.Authenticate(session.Token); !errors.Is(err, ErrInvalidSession) {
		t.Fatalf("expected logged out session to be invalid, got %v", err)
	}

	expiring, err := auth.Login(ctx, "admin", "correct-password")
	if err != nil {
		t.Fatal(err)
	}
	now = now.Add(time.Hour)
	if _, err := auth.Authenticate(expiring.Token); !errors.Is(err, ErrInvalidSession) {
		t.Fatalf("expected expired session to be invalid, got %v", err)
	}
}

func TestPasswordHashesAreSaltedAndVerifiable(t *testing.T) {
	first, err := HashPassword("same-password")
	if err != nil {
		t.Fatal(err)
	}
	second, err := HashPassword("same-password")
	if err != nil {
		t.Fatal(err)
	}
	if first == second {
		t.Fatal("password hashes must use different random salts")
	}
	valid, err := VerifyPassword(first, "same-password")
	if err != nil || !valid {
		t.Fatalf("expected password to verify: valid=%v err=%v", valid, err)
	}
	valid, err = VerifyPassword(first, "wrong-password")
	if err != nil || valid {
		t.Fatalf("wrong password unexpectedly verified: valid=%v err=%v", valid, err)
	}
}
