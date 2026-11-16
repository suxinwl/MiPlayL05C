// Package notify provides optional operational notifications for the backend.
package notify

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"errors"
	"fmt"
	"mime"
	"net"
	"net/mail"
	"net/smtp"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	defaultSMTPTimeout = 30 * time.Second
	defaultSMTPPort    = 587
)

// TLSMode controls how SMTPMailer establishes an encrypted connection.
type TLSMode string

const (
	// TLSModeAuto uses STARTTLS when the SMTP server advertises it. Authentication
	// is rejected if no encrypted channel can be established.
	TLSModeAuto TLSMode = "auto"
	// TLSModeStartTLS requires STARTTLS on a plain SMTP connection.
	TLSModeStartTLS TLSMode = "starttls"
	// TLSModeImplicit uses TLS immediately, typically on port 465.
	TLSModeImplicit TLSMode = "implicit"
	// TLSModeNone uses a plaintext SMTP connection. It should only be used for a
	// trusted local relay because credentials and message content are unencrypted.
	TLSModeNone TLSMode = "none"
)

// SMTPConfig describes an SMTP relay and the notification recipients.
type SMTPConfig struct {
	// Host is the SMTP server hostname without a port.
	Host string
	// Port is the SMTP server port. It defaults to 587 when omitted.
	Port int
	// Username is the SMTP authentication username. Authentication is skipped
	// when both Username and Password are empty.
	Username string
	// Password is the SMTP authentication password or authorization code.
	Password string
	// From is the sender address used in the message header and SMTP envelope.
	From string
	// To contains one or more recipient addresses.
	To []string
	// TLSMode controls STARTTLS versus implicit TLS. It defaults to auto.
	TLSMode TLSMode
	// Timeout limits one complete SMTP operation. It defaults to 30 seconds.
	Timeout time.Duration
}

// Message is a UTF-8 plain-text email.
type Message struct {
	// To contains the recipient addresses for this message.
	To []string
	// Subject is encoded as a UTF-8 MIME header.
	Subject string
	// Text is the plain-text message body.
	Text string
}

// LoadSMTPConfigFromEnv reads SMTP settings from OO_MUSIC_* environment variables.
// configured is false when no SMTP-related variable is set, allowing the backend
// to keep running while only warning that expiry notifications are disabled.
func LoadSMTPConfigFromEnv() (config SMTPConfig, configured bool, err error) {
	values := map[string]string{
		"OO_MUSIC_SMTP_HOST":     strings.TrimSpace(os.Getenv("OO_MUSIC_SMTP_HOST")),
		"OO_MUSIC_SMTP_PORT":     strings.TrimSpace(os.Getenv("OO_MUSIC_SMTP_PORT")),
		"OO_MUSIC_SMTP_USERNAME": strings.TrimSpace(os.Getenv("OO_MUSIC_SMTP_USERNAME")),
		"OO_MUSIC_SMTP_PASSWORD": os.Getenv("OO_MUSIC_SMTP_PASSWORD"),
		"OO_MUSIC_SMTP_TLS_MODE": strings.TrimSpace(os.Getenv("OO_MUSIC_SMTP_TLS_MODE")),
		"OO_MUSIC_MAIL_FROM":     strings.TrimSpace(os.Getenv("OO_MUSIC_MAIL_FROM")),
		"OO_MUSIC_MAIL_TO":       strings.TrimSpace(os.Getenv("OO_MUSIC_MAIL_TO")),
	}
	for key, value := range values {
		if key == "OO_MUSIC_MAIL_TO" || value == "" {
			continue
		}
		configured = true
		break
	}
	// A pre-filled recipient alone does not enable SMTP; sender credentials still
	// need to be supplied. This keeps a copied .env safe to start.
	if !configured {
		return SMTPConfig{}, false, nil
	}

	config = SMTPConfig{
		Host:     values["OO_MUSIC_SMTP_HOST"],
		Username: values["OO_MUSIC_SMTP_USERNAME"],
		Password: values["OO_MUSIC_SMTP_PASSWORD"],
		From:     values["OO_MUSIC_MAIL_FROM"],
		To:       splitAddresses(values["OO_MUSIC_MAIL_TO"]),
		TLSMode:  TLSMode(strings.ToLower(values["OO_MUSIC_SMTP_TLS_MODE"])),
	}
	if config.TLSMode == "" {
		config.TLSMode = TLSModeAuto
	}
	if rawPort := values["OO_MUSIC_SMTP_PORT"]; rawPort != "" {
		port, parseErr := strconv.Atoi(rawPort)
		if parseErr != nil {
			return SMTPConfig{}, true, fmt.Errorf("OO_MUSIC_SMTP_PORT 不是有效端口: %w", parseErr)
		}
		config.Port = port
	} else if config.TLSMode == TLSModeImplicit {
		config.Port = 465
	} else {
		config.Port = defaultSMTPPort
	}
	if err := config.Validate(); err != nil {
		return SMTPConfig{}, true, err
	}
	return config, true, nil
}

// Validate checks the SMTP configuration without contacting the server.
func (c SMTPConfig) Validate() error {
	if strings.TrimSpace(c.Host) == "" {
		return errors.New("SMTP host is required")
	}
	if strings.ContainsAny(c.Host, " \t\r\n/:") {
		return errors.New("SMTP host contains invalid characters")
	}
	if c.Port == 0 {
		c.Port = defaultSMTPPort
	}
	if c.Port < 1 || c.Port > 65535 {
		return fmt.Errorf("SMTP port is out of range: %d", c.Port)
	}
	switch c.TLSMode {
	case "", TLSModeAuto, TLSModeStartTLS, TLSModeImplicit, TLSModeNone:
	default:
		return fmt.Errorf("unsupported SMTP TLS mode %q", c.TLSMode)
	}
	if _, err := envelopeAddress(c.From); err != nil {
		return fmt.Errorf("invalid mail sender: %w", err)
	}
	if len(c.To) == 0 {
		return errors.New("at least one mail recipient is required")
	}
	for _, recipient := range c.To {
		if _, err := envelopeAddress(recipient); err != nil {
			return fmt.Errorf("invalid mail recipient: %w", err)
		}
	}
	if c.Username != "" && c.Password == "" {
		return errors.New("SMTP password is required when username is set")
	}
	if c.Username == "" && c.Password != "" {
		return errors.New("SMTP username is required when password is set")
	}
	return nil
}

// SMTPMailer sends notification messages through the configured SMTP relay.
type SMTPMailer struct {
	config SMTPConfig
	now    func() time.Time
}

// NewSMTPMailer validates config and creates a reusable SMTP mailer.
func NewSMTPMailer(config SMTPConfig) (*SMTPMailer, error) {
	if config.Port == 0 {
		if config.TLSMode == TLSModeImplicit {
			config.Port = 465
		} else {
			config.Port = defaultSMTPPort
		}
	}
	if config.TLSMode == "" {
		config.TLSMode = TLSModeAuto
	}
	if config.Timeout <= 0 {
		config.Timeout = defaultSMTPTimeout
	}
	if err := config.Validate(); err != nil {
		return nil, err
	}
	return &SMTPMailer{config: config, now: time.Now}, nil
}

// Send delivers one plain-text message through SMTP.
func (m *SMTPMailer) Send(ctx context.Context, message Message) error {
	if m == nil {
		return errors.New("SMTP mailer is nil")
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if err := validateMessage(message); err != nil {
		return err
	}
	payload, err := buildMessage(m.config.From, message, m.now())
	if err != nil {
		return err
	}

	deadline := time.Now().Add(m.config.Timeout)
	if ctxDeadline, ok := ctx.Deadline(); ok && ctxDeadline.Before(deadline) {
		deadline = ctxDeadline
	}
	address := net.JoinHostPort(m.config.Host, strconv.Itoa(m.config.Port))
	dialer := &net.Dialer{Timeout: m.config.Timeout, Deadline: deadline}
	conn, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return fmt.Errorf("连接 SMTP 服务器: %w", err)
	}
	defer conn.Close()
	if err := conn.SetDeadline(deadline); err != nil {
		return fmt.Errorf("设置 SMTP 超时: %w", err)
	}

	tlsConfig := &tls.Config{ServerName: m.config.Host, MinVersion: tls.VersionTLS12}
	implicitTLS := m.config.TLSMode == TLSModeImplicit
	if implicitTLS {
		tlsConn := tls.Client(conn, tlsConfig)
		if err := tlsConn.HandshakeContext(ctx); err != nil {
			return fmt.Errorf("建立 SMTP TLS 连接: %w", err)
		}
		conn = tlsConn
	}

	client, err := smtp.NewClient(conn, m.config.Host)
	if err != nil {
		return fmt.Errorf("初始化 SMTP 客户端: %w", err)
	}
	defer client.Close()
	if err := client.Hello("localhost"); err != nil {
		return fmt.Errorf("SMTP HELO 失败: %w", err)
	}

	encrypted := implicitTLS
	if !implicitTLS {
		hasStartTLS, _ := client.Extension("STARTTLS")
		switch m.config.TLSMode {
		case TLSModeStartTLS:
			if !hasStartTLS {
				return errors.New("SMTP 服务器未提供 STARTTLS")
			}
		case TLSModeAuto:
			if !hasStartTLS && m.config.Username != "" {
				return errors.New("SMTP 服务器未提供 STARTTLS，已拒绝发送登录凭据")
			}
		}
		if hasStartTLS && (m.config.TLSMode == TLSModeAuto || m.config.TLSMode == TLSModeStartTLS) {
			if err := client.StartTLS(tlsConfig); err != nil {
				return fmt.Errorf("SMTP STARTTLS 失败: %w", err)
			}
			encrypted = true
			if err := client.Hello("localhost"); err != nil {
				return fmt.Errorf("SMTP TLS HELO 失败: %w", err)
			}
		}
	}

	if m.config.Username != "" {
		if !encrypted && m.config.TLSMode != TLSModeNone {
			return errors.New("SMTP 连接未加密，已拒绝发送登录凭据")
		}
		auth := smtp.PlainAuth("", m.config.Username, m.config.Password, m.config.Host)
		if err := client.Auth(auth); err != nil {
			return fmt.Errorf("SMTP 认证失败: %w", err)
		}
	}
	from, err := envelopeAddress(m.config.From)
	if err != nil {
		return err
	}
	if err := client.Mail(from); err != nil {
		return fmt.Errorf("SMTP MAIL FROM 失败: %w", err)
	}
	for _, recipient := range message.To {
		to, err := envelopeAddress(recipient)
		if err != nil {
			return err
		}
		if err := client.Rcpt(to); err != nil {
			return fmt.Errorf("SMTP RCPT TO 失败: %w", err)
		}
	}
	writer, err := client.Data()
	if err != nil {
		return fmt.Errorf("SMTP DATA 失败: %w", err)
	}
	if _, err := writer.Write(payload); err != nil {
		_ = writer.Close()
		return fmt.Errorf("写入 SMTP 邮件正文: %w", err)
	}
	if err := writer.Close(); err != nil {
		return fmt.Errorf("结束 SMTP 邮件正文: %w", err)
	}
	if err := client.Quit(); err != nil {
		return fmt.Errorf("结束 SMTP 会话: %w", err)
	}
	return nil
}

func splitAddresses(raw string) []string {
	parts := strings.FieldsFunc(raw, func(char rune) bool {
		return char == ',' || char == ';' || char == '\n' || char == '\r'
	})
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		if part = strings.TrimSpace(part); part != "" {
			result = append(result, part)
		}
	}
	return result
}

func envelopeAddress(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" || strings.ContainsAny(raw, "\r\n") {
		return "", errors.New("address is empty or contains a newline")
	}
	parsed, err := mail.ParseAddress(raw)
	if err != nil {
		return "", err
	}
	return parsed.Address, nil
}

func validateMessage(message Message) error {
	if strings.TrimSpace(message.Subject) == "" {
		return errors.New("mail subject is required")
	}
	if strings.ContainsAny(message.Subject, "\r\n") {
		return errors.New("mail subject contains a newline")
	}
	if len(message.To) == 0 {
		return errors.New("at least one message recipient is required")
	}
	for _, recipient := range message.To {
		if _, err := envelopeAddress(recipient); err != nil {
			return fmt.Errorf("invalid message recipient: %w", err)
		}
	}
	return nil
}

func buildMessage(from string, message Message, now time.Time) ([]byte, error) {
	if _, err := envelopeAddress(from); err != nil {
		return nil, fmt.Errorf("invalid sender: %w", err)
	}
	if err := validateMessage(message); err != nil {
		return nil, err
	}
	body := base64.StdEncoding.EncodeToString([]byte(message.Text))
	body = wrapBase64(body, 76)
	var buffer bytes.Buffer
	headers := []struct {
		name  string
		value string
	}{
		{"Date", now.Format(time.RFC1123Z)},
		{"From", from},
		{"To", strings.Join(message.To, ", ")},
		{"Subject", mime.QEncoding.Encode("UTF-8", message.Subject)},
		{"MIME-Version", "1.0"},
		{"Content-Type", `text/plain; charset="UTF-8"`},
		{"Content-Transfer-Encoding", "base64"},
	}
	for _, header := range headers {
		if strings.ContainsAny(header.value, "\r\n") {
			return nil, fmt.Errorf("mail header %s contains a newline", header.name)
		}
		fmt.Fprintf(&buffer, "%s: %s\r\n", header.name, header.value)
	}
	buffer.WriteString("\r\n")
	buffer.WriteString(body)
	buffer.WriteString("\r\n")
	return buffer.Bytes(), nil
}

func wrapBase64(value string, width int) string {
	if width <= 0 || len(value) <= width {
		return value
	}
	var builder strings.Builder
	for len(value) > width {
		builder.WriteString(value[:width])
		builder.WriteString("\r\n")
		value = value[width:]
	}
	builder.WriteString(value)
	return builder.String()
}
