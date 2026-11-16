package api

import (
	"context"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/rankgice/oo-music/internal/account"
)

type fakePublicAPIAuthPolicy struct {
	required bool
	err      error
}

func (f fakePublicAPIAuthPolicy) PublicAPIAuthRequired(context.Context) (bool, error) {
	return f.required, f.err
}

func TestClientAuthorizationMiddlewareValidatesHeaders(t *testing.T) {
	store, err := account.Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	pool := account.NewPool(store, log.New(io.Discard, "", 0))
	saved, err := pool.Upsert(context.Background(), "209192670", "secret-qm-key")
	if err != nil {
		t.Fatal(err)
	}
	server := &Server{accounts: pool, logger: log.New(io.Discard, "", 0)}
	protected := server.requireClientAuthorization(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authorized, ok := AuthorizedClientAccount(r.Context())
		if !ok || authorized.ID != saved.ID || authorized.AccountID != saved.AccountID {
			t.Fatalf("unexpected authorized account: %+v, ok=%t", authorized, ok)
		}
		w.WriteHeader(http.StatusNoContent)
	}))

	for _, testCase := range []struct {
		name       string
		accountID  string
		accessKey  string
		wantStatus int
	}{
		{name: "missing", wantStatus: http.StatusUnauthorized},
		{name: "wrong key", accountID: saved.AccountID, accessKey: "wrong-key", wantStatus: http.StatusUnauthorized},
		{name: "valid", accountID: saved.AccountID, accessKey: saved.AccessKey, wantStatus: http.StatusNoContent},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, "/protected", nil)
			request.Header.Set(account.ClientSourceHeader, "qq")
			if testCase.accountID != "" {
				request.Header.Set(account.ClientAccountIDHeader, testCase.accountID)
			}
			if testCase.accessKey != "" {
				request.Header.Set(account.ClientAccessKeyHeader, testCase.accessKey)
			}
			response := httptest.NewRecorder()
			protected.ServeHTTP(response, request)
			if response.Code != testCase.wantStatus {
				t.Fatalf("status=%d want=%d body=%s", response.Code, testCase.wantStatus, response.Body.String())
			}
		})
	}
}

func TestPublicAPIAuthorizationFollowsRuntimeSwitch(t *testing.T) {
	store, err := account.Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	pool := account.NewPool(store, log.New(io.Discard, "", 0))
	saved, err := pool.Upsert(context.Background(), "209192670", "secret-qm-key")
	if err != nil {
		t.Fatal(err)
	}

	for _, testCase := range []struct {
		name       string
		policy     PublicAPIAuthPolicy
		accountID  string
		accessKey  string
		wantStatus int
	}{
		{name: "disabled allows anonymous", policy: fakePublicAPIAuthPolicy{}, wantStatus: http.StatusNoContent},
		{name: "enabled rejects anonymous", policy: fakePublicAPIAuthPolicy{required: true}, wantStatus: http.StatusUnauthorized},
		{name: "enabled rejects wrong key", policy: fakePublicAPIAuthPolicy{required: true}, accountID: saved.AccountID, accessKey: "wrong-key", wantStatus: http.StatusUnauthorized},
		{name: "enabled accepts valid account", policy: fakePublicAPIAuthPolicy{required: true}, accountID: saved.AccountID, accessKey: saved.AccessKey, wantStatus: http.StatusNoContent},
		{name: "policy failure does not fall through", policy: fakePublicAPIAuthPolicy{err: errors.New("database unavailable")}, wantStatus: http.StatusServiceUnavailable},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			server := &Server{
				accounts:         pool,
				logger:           log.New(io.Discard, "", 0),
				publicAuthPolicy: testCase.policy,
			}
			handler := server.withPublicAPIAuthorization(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(http.StatusNoContent)
			}))
			request := httptest.NewRequest(http.MethodGet, "/public", nil)
			request.Header.Set(account.ClientSourceHeader, "qq")
			if testCase.accountID != "" {
				request.Header.Set(account.ClientAccountIDHeader, testCase.accountID)
			}
			if testCase.accessKey != "" {
				request.Header.Set(account.ClientAccessKeyHeader, testCase.accessKey)
			}
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			if response.Code != testCase.wantStatus {
				t.Fatalf("status=%d want=%d body=%s", response.Code, testCase.wantStatus, response.Body.String())
			}
		})
	}
}

func TestPublicAPIRoutesRespectSwitchButFixedProtectedRoutesDoNot(t *testing.T) {
	store, err := account.Open(filepath.Join(t.TempDir(), "accounts.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	pool := account.NewPool(store, log.New(io.Discard, "", 0))

	handler := NewHandlerWithWebRootAndQRAndPolicy(
		pool,
		nil,
		log.New(io.Discard, "", 0),
		"",
		fakePublicAPIAuthPolicy{required: false},
	)

	search := httptest.NewRecorder()
	searchRequest := httptest.NewRequest(http.MethodGet, "/api/search", nil)
	searchRequest.Header.Set(account.ClientSourceHeader, "qq")
	handler.ServeHTTP(search, searchRequest)
	if search.Code == http.StatusUnauthorized {
		t.Fatalf("disabled public auth must not reject anonymous search: %d body=%s", search.Code, search.Body.String())
	}

	for _, path := range []string{"/api/client/account", "/api/client/playlists"} {
		response := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodGet, path, nil)
		request.Header.Set(account.ClientSourceHeader, "qq")
		handler.ServeHTTP(response, request)
		if response.Code != http.StatusUnauthorized {
			t.Fatalf("fixed protected route %s status=%d body=%s", path, response.Code, response.Body.String())
		}
	}

	liveness := httptest.NewRecorder()
	handler.ServeHTTP(liveness, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if liveness.Code != http.StatusOK {
		t.Fatalf("liveness must remain public: status=%d body=%s", liveness.Code, liveness.Body.String())
	}
}
