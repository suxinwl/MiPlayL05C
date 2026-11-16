package api

import (
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestAccountPoolDiagnosticsAreNotExposedToClients(t *testing.T) {
	handler := NewHandler(nil, log.New(io.Discard, "", 0))
	for _, path := range []string{"/api/health", "/api/account/status"} {
		request := httptest.NewRequest(http.MethodGet, path, nil)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)

		if response.Code != http.StatusNotFound {
			t.Fatalf("%s must not be exposed: status=%d body=%s", path, response.Code, response.Body.String())
		}
	}
}
