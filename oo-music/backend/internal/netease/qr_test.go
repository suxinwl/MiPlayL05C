package netease

import (
	"context"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func TestQRServiceCompletesAfterScanAndVerifiesAccount(t *testing.T) {
	var polls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/weapi/login/qrcode/unikey":
			_, _ = w.Write([]byte(`{"code":200,"unikey":"qr-key"}`))
		case "/weapi/login/qrcode/client/login":
			if polls.Add(1) == 1 {
				_, _ = w.Write([]byte(`{"code":801}`))
				return
			}
			http.SetCookie(w, &http.Cookie{Name: "MUSIC_U", Value: "qr-cookie", Path: "/", MaxAge: 3600})
			_, _ = w.Write([]byte(`{"code":803}`))
		case "/weapi/w/nuser/account/get":
			cookie, err := r.Cookie("MUSIC_U")
			if err != nil || cookie.Value != "qr-cookie" {
				t.Errorf("QR cookie was not used: cookie=%v err=%v", cookie, err)
			}
			_, _ = w.Write([]byte(`{"code":200,"account":{"id":24680},"profile":{"nickname":"扫码用户"}}`))
		default:
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
	}))
	defer server.Close()

	client, err := NewClient(WithBaseURL(server.URL))
	if err != nil {
		t.Fatal(err)
	}
	service, err := NewQRService(client, log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	started, err := service.Start(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(started.ImagePNG) == 0 || started.Status != QRStatusWaiting {
		t.Fatalf("unexpected QR start: %+v", started)
	}
	waiting, err := service.Poll(context.Background(), started.ID)
	if err != nil {
		t.Fatal(err)
	}
	if waiting.Status != QRStatusWaiting {
		t.Fatalf("expected waiting status, got %+v", waiting)
	}
	completed, err := service.Poll(context.Background(), started.ID)
	if err != nil {
		t.Fatal(err)
	}
	if completed.Status != QRStatusCompleted || completed.UID != 24680 || completed.Cookie == "" {
		t.Fatalf("unexpected completed QR result: %+v", completed)
	}
}
