package notify

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"io"
	"mime"
	"net"
	"net/mail"
	"strings"
	"testing"
	"time"

	"github.com/rankgice/oo-music/internal/account"
)

func TestBuildMessageUsesUTF8HeadersAndBase64Body(t *testing.T) {
	payload, err := buildMessage(
		"oo-music <sender@example.com>",
		Message{
			To:      []string{"ops@example.com"},
			Subject: "账号登录态已过期",
			Text:    "请更新凭据。\r\n第二行",
		},
		time.Date(2026, 10, 27, 11, 0, 0, 0, time.FixedZone("CST", 8*60*60)),
	)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := mail.ReadMessage(bytes.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Header.Get("To") != "ops@example.com" {
		t.Fatalf("unexpected To header: %q", parsed.Header.Get("To"))
	}
	subject, err := new(mime.WordDecoder).DecodeHeader(parsed.Header.Get("Subject"))
	if err != nil {
		t.Fatal(err)
	}
	if subject != "账号登录态已过期" {
		t.Fatalf("unexpected subject: %q", subject)
	}
	encodedBody, err := io.ReadAll(parsed.Body)
	if err != nil {
		t.Fatal(err)
	}
	body, err := base64.StdEncoding.DecodeString(strings.ReplaceAll(string(encodedBody), "\r\n", ""))
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "请更新凭据。\r\n第二行" {
		t.Fatalf("unexpected body: %q", body)
	}
}

func TestBuildMessageRejectsHeaderInjection(t *testing.T) {
	_, err := buildMessage(
		"sender@example.com",
		Message{To: []string{"receiver@example.com"}, Subject: "hello\r\nBcc: victim@example.com", Text: "body"},
		time.Now(),
	)
	if err == nil {
		t.Fatal("expected header injection to be rejected")
	}
}

func TestLoadSMTPConfigFromEnv(t *testing.T) {
	for _, key := range []string{
		"OO_MUSIC_SMTP_HOST",
		"OO_MUSIC_SMTP_PORT",
		"OO_MUSIC_SMTP_USERNAME",
		"OO_MUSIC_SMTP_PASSWORD",
		"OO_MUSIC_SMTP_TLS_MODE",
		"OO_MUSIC_MAIL_FROM",
		"OO_MUSIC_MAIL_TO",
	} {
		t.Setenv(key, "")
	}
	if _, configured, err := LoadSMTPConfigFromEnv(); err != nil || configured {
		t.Fatalf("expected disabled configuration, configured=%v err=%v", configured, err)
	}

	t.Setenv("OO_MUSIC_MAIL_TO", "ops@example.com")
	if _, configured, err := LoadSMTPConfigFromEnv(); err != nil || configured {
		t.Fatalf("recipient alone should not enable SMTP, configured=%v err=%v", configured, err)
	}

	t.Setenv("OO_MUSIC_SMTP_HOST", "smtp.example.com")
	t.Setenv("OO_MUSIC_SMTP_USERNAME", "user")
	t.Setenv("OO_MUSIC_SMTP_PASSWORD", "secret")
	t.Setenv("OO_MUSIC_SMTP_TLS_MODE", "starttls")
	t.Setenv("OO_MUSIC_MAIL_FROM", "sender@example.com")
	t.Setenv("OO_MUSIC_MAIL_TO", "ops@example.com,second@example.com")
	config, configured, err := LoadSMTPConfigFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if !configured || config.Port != defaultSMTPPort || len(config.To) != 2 {
		t.Fatalf("unexpected config: %+v configured=%v", config, configured)
	}
}

func TestLoginExpiryMessageDoesNotIncludeCredentials(t *testing.T) {
	message := LoginExpiryMessage(account.LoginCheckReport{
		CheckedAt: time.Date(2026, 10, 27, 3, 0, 0, 0, time.UTC),
		Expired: []account.LoginCheck{{
			AccountID: 7,
			UINMasked: "1000****01",
			Error:     "QQ 音乐登录态已过期",
		}},
	}, []string{"ops@example.com"})
	if !strings.Contains(message.Subject, "1 个") || !strings.Contains(message.Text, "1000****01") {
		t.Fatalf("unexpected expiry message: %+v", message)
	}
	if strings.Contains(strings.ToLower(message.Text), "qm_keyst=") || strings.Contains(message.Text, "secret-key") {
		t.Fatalf("message leaked credential-like content: %v", message.Text)
	}
}

func TestSMTPMailerSendsPlainTextThroughRelay(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	messages := make(chan string, 1)
	serverErrors := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			serverErrors <- err
			return
		}
		defer conn.Close()
		reader := bufio.NewReader(conn)
		writer := bufio.NewWriter(conn)
		write := func(value string) error {
			if _, err := writer.WriteString(value); err != nil {
				return err
			}
			return writer.Flush()
		}
		if err := write("220 localhost ESMTP\r\n"); err != nil {
			serverErrors <- err
			return
		}
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				serverErrors <- err
				return
			}
			command := strings.ToUpper(strings.TrimSpace(line))
			switch {
			case strings.HasPrefix(command, "EHLO"), strings.HasPrefix(command, "HELO"):
				if err := write("250-localhost\r\n250 OK\r\n"); err != nil {
					serverErrors <- err
					return
				}
			case strings.HasPrefix(command, "MAIL FROM:"), strings.HasPrefix(command, "RCPT TO:"):
				if err := write("250 OK\r\n"); err != nil {
					serverErrors <- err
					return
				}
			case command == "DATA":
				if err := write("354 End data with <CR><LF>.<CR><LF>\r\n"); err != nil {
					serverErrors <- err
					return
				}
				var data strings.Builder
				for {
					line, err := reader.ReadString('\n')
					if err != nil {
						serverErrors <- err
						return
					}
					if line == ".\r\n" {
						break
					}
					data.WriteString(line)
				}
				messages <- data.String()
				if err := write("250 Queued\r\n"); err != nil {
					serverErrors <- err
					return
				}
			case command == "QUIT":
				_ = write("221 Bye\r\n")
				serverErrors <- nil
				return
			default:
				if err := write("250 OK\r\n"); err != nil {
					serverErrors <- err
					return
				}
			}
		}
	}()

	address := listener.Addr().(*net.TCPAddr)
	mailer, err := NewSMTPMailer(SMTPConfig{
		Host:    "127.0.0.1",
		Port:    address.Port,
		From:    "sender@example.com",
		To:      []string{"ops@example.com"},
		TLSMode: TLSModeNone,
		Timeout: 2 * time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := mailer.Send(context.Background(), Message{
		To:      []string{"ops@example.com"},
		Subject: "登录态告警",
		Text:    "account expired",
	}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-serverErrors:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("SMTP server did not finish")
	}
	select {
	case message := <-messages:
		if !strings.Contains(message, "To: ops@example.com") || !strings.Contains(message, "Subject:") {
			t.Fatalf("unexpected SMTP message: %q", message)
		}
	case <-time.After(time.Second):
		t.Fatal("SMTP message was not captured")
	}
}
