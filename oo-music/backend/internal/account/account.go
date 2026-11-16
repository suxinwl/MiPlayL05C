// Package account 提供音乐平台账号的 SQLite 持久化和账号池选择。
package account

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"time"
)

// ErrNoAccount 表示数据库中没有找到目标账号。
var ErrNoAccount = errors.New("no music account configured")

// AccountType 表示绑定账号所属的音乐平台。
type AccountType string

const (
	// AccountTypeQQ 表示 QQ 音乐账号。
	AccountTypeQQ AccountType = "qq"
	// AccountTypeNetease 表示网易云音乐账号。
	AccountTypeNetease AccountType = "netease"
)

// Valid 判断账号类型是否受支持。
func (t AccountType) Valid() bool {
	return t == AccountTypeQQ || t == AccountTypeNetease
}

// Name 返回用于后台展示的账号类型名称。
func (t AccountType) Name() string {
	switch t {
	case AccountTypeQQ:
		return "QQ 音乐"
	case AccountTypeNetease:
		return "网易云音乐"
	default:
		return "未知平台"
	}
}

const (
	// ClientAccountIDHeader 是客户端请求受保护接口时携带平台账号 ID 的请求头。
	ClientAccountIDHeader = "X-OO-Music-Account-ID"
	// ClientSourceHeader 指定账号和媒体请求使用的平台。
	ClientSourceHeader = "X-OO-Music-Source"
	// ClientAccessKeyHeader 是客户端请求受保护接口时携带授权密钥的请求头。
	ClientAccessKeyHeader = "X-OO-Music-Access-Key"
)

// 会员等级使用递增整数表示，数值越大优先级越高。
const (
	// VipLevelNone 表示没有有效会员。
	VipLevelNone = 0
	// VipLevelVIP 表示基础 VIP 权益。
	VipLevelVIP = 1
	// VipLevelHuge 表示高级会员权益。
	VipLevelHuge = 2
	// VipLevelSuper 表示超级会员权益。
	VipLevelSuper = 3
)

// Account 是账号持久化记录。凭据字段只允许在进程内部使用，
// 不应直接写入日志或返回给前端。
type Account struct {
	ID                  int64
	Type                AccountType
	AccountID           string
	Credential          string
	AccessKey           string
	Nickname            string
	AvatarURL           string
	VipLevel            int
	VipExpiresAt        *time.Time
	VipCheckedAt        *time.Time
	LoginValid          bool
	LoginCheckedAt      *time.Time
	LoginExpiresAt      *time.Time
	CredentialUpdatedAt *time.Time
	CreatedAt           time.Time
	UpdatedAt           time.Time
}

// AuthorizedAccount 是客户端授权校验成功后返回的最小账号身份。
type AuthorizedAccount struct {
	ID        int64
	Type      AccountType
	AccountID string
	Nickname  string
	AvatarURL string
}

// accessKeyLength 是客户端授权密钥的随机字节数。Base64 URL 编码后为 43 个字符。
const accessKeyLength = 32

// newAccessKey 生成仅供客户端使用的不透明授权密钥。
func newAccessKey() (string, error) {
	value := make([]byte, accessKeyLength)
	if _, err := rand.Read(value); err != nil {
		return "", fmt.Errorf("生成客户端授权密钥: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}

// PublicAccount 是账号的脱敏视图，可安全返回给桌面客户端。
type PublicAccount struct {
	ID                  int64       `json:"id"`
	AccountType         AccountType `json:"accountType"`
	AccountTypeName     string      `json:"accountTypeName"`
	Available           bool        `json:"available"`
	LoggedIn            bool        `json:"loggedIn"`
	UINMasked           string      `json:"uinMasked,omitempty"`
	Nickname            string      `json:"nickname,omitempty"`
	AvatarURL           string      `json:"avatarUrl,omitempty"`
	VipLevel            int         `json:"vipLevel"`
	VipLevelName        string      `json:"vipLevelName"`
	VipExpiresAt        *time.Time  `json:"vipExpiresAt,omitempty"`
	VipCheckedAt        *time.Time  `json:"vipCheckedAt,omitempty"`
	LoginValid          bool        `json:"loginValid"`
	LoginCheckedAt      *time.Time  `json:"loginCheckedAt,omitempty"`
	LoginExpiresAt      *time.Time  `json:"loginExpiresAt,omitempty"`
	CredentialUpdatedAt *time.Time  `json:"credentialUpdatedAt,omitempty"`
}

// Public 将账号转换为不含登录凭据的公开视图。
func (a Account) Public() PublicAccount {
	accountType := a.Type
	loggedIn := a.AccountID != "" && a.Credential != ""
	vipLevelName := vipLevelName(a.VipLevel)
	if accountType == AccountTypeNetease && a.VipLevel > VipLevelNone {
		vipLevelName = "黑胶 VIP"
	}
	return PublicAccount{
		ID:                  a.ID,
		AccountType:         accountType,
		AccountTypeName:     accountType.Name(),
		Available:           true,
		LoggedIn:            loggedIn,
		UINMasked:           maskAccountID(accountType, a.AccountID),
		Nickname:            a.Nickname,
		AvatarURL:           a.AvatarURL,
		VipLevel:            a.VipLevel,
		VipLevelName:        vipLevelName,
		VipExpiresAt:        cloneTime(a.VipExpiresAt),
		VipCheckedAt:        cloneTime(a.VipCheckedAt),
		LoginValid:          a.LoginValid,
		LoginCheckedAt:      cloneTime(a.LoginCheckedAt),
		LoginExpiresAt:      cloneTime(a.LoginExpiresAt),
		CredentialUpdatedAt: cloneTime(a.CredentialUpdatedAt),
	}
}

func maskAccountID(_ AccountType, accountID string) string {
	return maskUIN(accountID)
}

func maskUIN(uin string) string {
	uin = strings.TrimSpace(uin)
	switch {
	case uin == "":
		return ""
	case len(uin) <= 2:
		return strings.Repeat("*", len(uin))
	case len(uin) <= 6:
		return uin[:1] + "****" + uin[len(uin)-1:]
	default:
		return uin[:4] + "****" + uin[len(uin)-2:]
	}
}

func vipLevelName(level int) string {
	switch level {
	case VipLevelSuper:
		return "超级会员"
	case VipLevelHuge:
		return "高级会员"
	case VipLevelVIP:
		return "VIP"
	default:
		return "普通用户"
	}
}

func cloneTime(value *time.Time) *time.Time {
	if value == nil {
		return nil
	}
	copied := value.UTC()
	return &copied
}

func validateCredentials(uin, qmKeyst string) (string, string, error) {
	uin = strings.TrimSpace(uin)
	qmKeyst = strings.TrimSpace(qmKeyst)
	if (uin == "") != (qmKeyst == "") {
		return "", "", errors.New("uin and qmKeyst must be provided together")
	}
	if uin == "" {
		return "", "", errors.New("QQ Music credentials are empty")
	}
	return uin, qmKeyst, nil
}

const maxNeteaseCookieLength = 16384

func normalizeCookieInput(cookie string) string {
	cookie = strings.TrimSpace(cookie)
	if strings.HasPrefix(strings.ToLower(cookie), "cookie:") {
		cookie = strings.TrimSpace(cookie[len("cookie:"):])
	}
	return cookie
}

func validateNeteaseCredentials(uid, cookie string) (string, string, error) {
	uid = strings.TrimSpace(uid)
	cookie = normalizeCookieInput(cookie)
	if uid == "" {
		return "", "", errors.New("网易云音乐账号 ID 不能为空")
	}
	for _, char := range uid {
		if char < '0' || char > '9' {
			return "", "", errors.New("网易云音乐账号 ID 必须是数字")
		}
	}
	if cookie == "" {
		return "", "", errors.New("网易云音乐 Cookie 不能为空")
	}
	if !strings.Contains(cookie, "MUSIC_U=") {
		return "", "", errors.New("网易云音乐 Cookie 缺少 MUSIC_U")
	}
	if len(cookie) > maxNeteaseCookieLength {
		return "", "", errors.New("网易云音乐 Cookie 长度不合法")
	}
	return uid, cookie, nil
}

func timePtr(value time.Time) *time.Time {
	if value.IsZero() {
		return nil
	}
	value = value.UTC()
	return &value
}

func unixPtr(value *time.Time) any {
	if value == nil || value.IsZero() {
		return nil
	}
	return value.UTC().Unix()
}

func parseUnixPointer(value *int64) *time.Time {
	if value == nil || *value == 0 {
		return nil
	}
	parsed := time.Unix(*value, 0).UTC()
	return &parsed
}

func accountScanError(id int64, err error) error {
	return fmt.Errorf("读取账号 %d: %w", id, err)
}
