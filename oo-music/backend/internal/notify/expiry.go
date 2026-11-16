package notify

import (
	"fmt"
	"strings"

	"github.com/rankgice/oo-music/internal/account"
)

// LoginExpiryMessage creates a summary email for accounts whose login state was
// explicitly reported as expired. It never includes credentials.
func LoginExpiryMessage(report account.LoginCheckReport, recipients []string) Message {
	subject := fmt.Sprintf("[oo-music] %d 个音乐账号登录态已过期", len(report.Expired))
	var body strings.Builder
	body.WriteString("oo-music 每日登录态自检发现以下账号已经失效：\r\n\r\n")
	body.WriteString(fmt.Sprintf("检查时间：%s\r\n\r\n", report.CheckedAt.Format("2006-01-02 15:04:05 MST")))
	for _, item := range report.Expired {
		accountType := item.AccountType
		if !accountType.Valid() {
			accountType = account.AccountTypeQQ
		}
		body.WriteString(fmt.Sprintf("- %s账号 %s（ID %d）", accountType.Name(), item.UINMasked, item.AccountID))
		if item.Error != "" {
			body.WriteString("：" + item.Error)
		}
		body.WriteString("\r\n")
	}
	body.WriteString("\r\n请更新对应的音乐平台登录凭据。此邮件不包含任何登录凭据。\r\n")
	return Message{
		To:      append([]string(nil), recipients...),
		Subject: subject,
		Text:    body.String(),
	}
}
