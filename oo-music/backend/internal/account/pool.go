package account

import (
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"log"
	"strconv"
	"strings"
	"sync"
	"time"

	oomusic "github.com/rankgice/oo-music"
	"github.com/rankgice/oo-music/internal/netease"
)

const (
	defaultVIPRefreshInterval  = 5 * time.Minute
	defaultRequestTimeout      = 30 * time.Second
	defaultVIPClaimCooldown    = time.Hour
	neteaseRefreshLead         = 24 * time.Hour
	neteaseVIPClaimAttempts    = 3
	experienceCardResolveLimit = 3
)

var (
	// ErrAccountLoginExpired 表示上游平台明确判定当前账号登录态已经失效。
	ErrAccountLoginExpired = errors.New("music account login has expired")
	// ErrInvalidClientAuthorization 表示客户端 uin 或 accessKey 校验失败。
	ErrInvalidClientAuthorization = errors.New("client authorization failed")
)

// AccountLoginExpiredError 保留登录态失效账号的脱敏信息。
type AccountLoginExpiredError struct {
	// AccountType 是账号所属平台。
	AccountType AccountType
	// AccountID 是数据库中的账号 ID。
	AccountID int64
	// UINMasked 是脱敏后的平台账号 ID。
	UINMasked string
}

// Error 实现 error 接口。
func (e *AccountLoginExpiredError) Error() string {
	if e == nil {
		return ErrAccountLoginExpired.Error()
	}
	accountType := e.AccountType
	return fmt.Sprintf("%s account %s login has expired", accountType.Name(), e.UINMasked)
}

// Unwrap 返回稳定的登录态失效错误。
func (e *AccountLoginExpiredError) Unwrap() error {
	return ErrAccountLoginExpired
}

// LoginCheck 是单个账号的登录态检查结果。
type LoginCheck struct {
	// AccountType 是账号所属平台。
	AccountType AccountType
	// AccountID 是数据库中的账号 ID。
	AccountID int64
	// UINMasked 是脱敏后的平台账号 ID。
	UINMasked string
	// Valid 表示本次检查是否确认登录态有效。
	Valid bool
	// Expired 表示接口明确返回登录态失效。
	Expired bool
	// CheckedAt 是本次检查时间。
	CheckedAt time.Time
	// Error 是网络、协议或业务检查错误；过期账号也会填写原因。
	Error string
}

// LoginCheckReport 是一次全账号登录态自检的结果。
type LoginCheckReport struct {
	// CheckedAt 是自检开始时间。
	CheckedAt time.Time
	// Accounts 包含所有账号的检查结果。
	Accounts []LoginCheck
	// Expired 只包含接口明确返回登录态失效的账号。
	Expired []LoginCheck
}

type cachedClient struct {
	accountID  string
	credential string
	client     *oomusic.Client
}

// MediaAccountPolicy 声明共享媒体请求对服务端号池账号的要求。
type MediaAccountPolicy bool

const (
	// MediaAccountAny 允许普通账号或 VIP 账号，不因该请求触发会员领取。
	MediaAccountAny MediaAccountPolicy = false
	// MediaAccountVIP 要求优先使用 VIP 账号；号池没有 VIP 时允许触发领取。
	MediaAccountVIP MediaAccountPolicy = true
)

type vipStatusReader func(context.Context, *oomusic.Client, string) (*oomusic.CallResult, error)
type experienceCardClaimer func(context.Context, *oomusic.Client, oomusic.ExperienceCardRequest) (*oomusic.ExperienceCardClaimResult, error)
type experienceCardFeedReader func(context.Context) ([]experienceCardCandidate, error)
type experienceCardResolver func(context.Context, string) (oomusic.ExperienceCardRequest, error)
type userProfileReader func(context.Context, *oomusic.Client, string) (*oomusic.CallResult, error)
type userPlaylistReader func(context.Context, *oomusic.Client, string) ([]oomusic.UserPlaylist, error)
type clientFactory func(Account) (*oomusic.Client, error)

type neteaseAccountClient interface {
	Check(context.Context, string, string) (netease.AccountState, error)
	Refresh(context.Context, string, string) (netease.AccountState, error)
	GetVIPStatus(context.Context, string, string) (netease.VIPStatus, error)
	GetInvitationDetail(context.Context, string, string, string, string) (netease.InvitationDetail, error)
	AcceptInvitation(context.Context, string, string, string, string) (netease.InvitationAcceptResult, error)
}

type neteaseVIPFeedReader func(context.Context) ([]neteaseVIPInvitation, error)
type neteaseVIPClaimer func(context.Context, Account, neteaseVIPInvitation) (netease.InvitationAcceptResult, error)

// Pool 管理数据库中的账号，并让同一账号始终复用同一个 Client 实例。
// 每次选择账号时按有效会员等级从高到低、同等级到期时间从晚到早排序；
// 当所有可用账号都不是会员时，可配置官方体验卡链接并尝试自动领取。
type Pool struct {
	store  *Store
	logger *log.Logger

	refreshInterval time.Duration
	requestTimeout  time.Duration

	refreshMu      sync.Mutex
	selectionMu    sync.Mutex
	claimMu        sync.Mutex
	clientsMu      sync.Mutex
	neteaseClaimMu sync.Mutex

	clients      map[int64]cachedClient
	activeID     int64
	activeClient *oomusic.Client
	anonymous    *oomusic.Client
	netease      neteaseAccountClient

	experienceCards       []experienceCardCandidate
	experienceFeed        experienceCardFeedReader
	resolveExperienceCard experienceCardResolver
	claimCooldown         time.Duration
	lastClaimAt           time.Time
	lastNeteaseClaimAt    time.Time

	neteaseVIPFeed  neteaseVIPFeedReader
	claimNeteaseVIP neteaseVIPClaimer

	newClient           clientFactory
	readVipStatus       vipStatusReader
	readUserProfile     userProfileReader
	readUserPlaylists   userPlaylistReader
	claimExperienceCard experienceCardClaimer
	now                 func() time.Time
}

// NewPool 创建账号池。账号选择顺序为会员等级从高到低、
// 同等级到期时间从晚到早，其余情况按数据库 ID 升序。
func NewPool(store *Store, logger *log.Logger) *Pool {
	if logger == nil {
		logger = log.Default()
	}
	pool := &Pool{
		store:           store,
		logger:          logger,
		refreshInterval: defaultVIPRefreshInterval,
		requestTimeout:  defaultRequestTimeout,
		claimCooldown:   defaultVIPClaimCooldown,
		clients:         make(map[int64]cachedClient),
		now:             time.Now,
	}
	pool.newClient = func(item Account) (*oomusic.Client, error) {
		return oomusic.NewClient(
			oomusic.WithCredentials(item.AccountID, item.Credential),
			oomusic.WithRequestTimeout(pool.requestTimeout),
		)
	}
	neteaseClient, err := netease.NewClient()
	if err != nil {
		logger.Printf("创建网易云音乐客户端失败: %v", err)
	} else {
		pool.netease = neteaseClient
	}
	pool.readVipStatus = func(ctx context.Context, client *oomusic.Client, uin string) (*oomusic.CallResult, error) {
		return client.GetVipStatus(ctx, uin)
	}
	pool.readUserProfile = func(ctx context.Context, client *oomusic.Client, uin string) (*oomusic.CallResult, error) {
		return client.GetUserBaseInfo(ctx, uin)
	}
	pool.readUserPlaylists = func(ctx context.Context, client *oomusic.Client, uin string) ([]oomusic.UserPlaylist, error) {
		return client.GetUserCreatedPlaylists(ctx, uin)
	}
	pool.claimExperienceCard = func(ctx context.Context, client *oomusic.Client, request oomusic.ExperienceCardRequest) (*oomusic.ExperienceCardClaimResult, error) {
		return client.ClaimExperienceCard(ctx, request)
	}
	neteaseVIPFeed := newNeteaseVIPFeedClient("", pool.requestTimeout, defaultNeteaseVIPFeedLimit)
	pool.neteaseVIPFeed = neteaseVIPFeed.fetch
	neteaseClaimClient := newNeteaseVIPClaimClient(pool.requestTimeout)
	pool.claimNeteaseVIP = func(ctx context.Context, item Account, invitation neteaseVIPInvitation) (netease.InvitationAcceptResult, error) {
		if pool.netease == nil {
			return netease.InvitationAcceptResult{}, errors.New("网易云音乐客户端不可用")
		}
		link, err := neteaseClaimClient.claim(ctx, invitation.ID)
		if err != nil {
			return netease.InvitationAcceptResult{}, err
		}
		detail, err := pool.netease.GetInvitationDetail(ctx, item.Credential, link.Token, "invite-cashier", link.OfficialURL)
		if err != nil {
			return netease.InvitationAcceptResult{}, err
		}
		if detail.CurrentUserRecordID > 0 {
			return netease.InvitationAcceptResult{}, netease.ErrInvitationAlreadyAccepted
		}
		return pool.netease.AcceptInvitation(ctx, item.Credential, link.Token, "invite-cashier", link.OfficialURL)
	}
	feedClient := newExperienceCardFeedClient(defaultExperienceCardFeedURL, pool.requestTimeout, defaultExperienceCardFeedLimit)
	pool.experienceFeed = feedClient.fetch
	pool.resolveExperienceCard = feedClient.resolve
	return pool
}

// SetVIPRefreshInterval 设置会员状态刷新间隔，主要用于测试或自定义部署。
func (p *Pool) SetVIPRefreshInterval(interval time.Duration) {
	if interval > 0 {
		p.refreshInterval = interval
	}
}

// SetVIPClaimCooldown 设置自动领取失败或未成功后的重试间隔。
func (p *Pool) SetVIPClaimCooldown(interval time.Duration) {
	p.claimMu.Lock()
	defer p.claimMu.Unlock()
	if interval >= 0 {
		p.claimCooldown = interval
	}
}

// SetUserProfileReader 替换 QQ 用户资料读取函数，主要用于测试。
func (p *Pool) SetUserProfileReader(reader func(context.Context, *oomusic.Client, string) (*oomusic.CallResult, error)) {
	if reader != nil {
		p.readUserProfile = reader
	}
}

// SetUserPlaylistReader 替换 QQ 音乐歌单读取函数，主要用于测试。
func (p *Pool) SetUserPlaylistReader(reader func(context.Context, *oomusic.Client, string) ([]oomusic.UserPlaylist, error)) {
	if reader != nil {
		p.readUserPlaylists = reader
	}
}

// SetExperienceCardURLs 配置一个或多个 QQ 音乐官方体验卡链接。
// 所有链接都会先解析，任意一个无效时整组配置都不会生效。
func (p *Pool) SetExperienceCardURLs(urls []string) error {
	candidates := make([]experienceCardCandidate, 0, len(urls))
	for _, raw := range urls {
		request, err := oomusic.ParseExperienceCardLink(raw)
		if err != nil {
			return fmt.Errorf("解析体验卡链接: %w", err)
		}
		candidates = append(candidates, experienceCardCandidate{Request: request})
	}
	p.claimMu.Lock()
	defer p.claimMu.Unlock()
	p.experienceCards = candidates
	return nil
}

// Upsert 将账号写入数据库，并仅在 qm_keyst 真正变化后使旧客户端缓存失效。
func (p *Pool) Upsert(ctx context.Context, uin, qmKeyst string) (Account, error) {
	previous, lookupErr := p.store.accountByUIN(ctx, uin)
	if lookupErr != nil && !errors.Is(lookupErr, ErrNoAccount) {
		return Account{}, lookupErr
	}
	item, err := p.store.UpsertCredentials(ctx, uin, qmKeyst)
	if err != nil {
		return Account{}, err
	}
	credentialsChanged := errors.Is(lookupErr, ErrNoAccount) || previous.Credential != item.Credential
	if credentialsChanged {
		p.clientsMu.Lock()
		delete(p.clients, item.ID)
		if p.activeID == item.ID {
			p.activeID = 0
			p.activeClient = nil
		}
		p.clientsMu.Unlock()
	}
	return item, nil
}

// UpsertNetease 保存已经完成扫码校验的网易云音乐账号。
func (p *Pool) UpsertNetease(ctx context.Context, uid, cookie string, expiresAt *time.Time, nickname, avatarURL string) (Account, error) {
	item, err := p.store.UpsertNeteaseCredentials(ctx, uid, cookie, expiresAt)
	if err != nil {
		return Account{}, err
	}
	if nickname != "" || avatarURL != "" {
		if err := p.store.UpdateProfile(ctx, item.ID, nickname, avatarURL); err != nil {
			p.logger.Printf("刷新网易云音乐账号 %s 资料失败: %v", maskAccountID(item.Type, item.AccountID), err)
			return item, nil
		}
		item.Nickname = nickname
		item.AvatarURL = avatarURL
	}
	if err := p.syncNeteaseVIP(ctx, item, cookie, p.now().UTC()); err != nil {
		p.logger.Printf("刷新网易云音乐账号 %s 会员状态失败: %v", maskAccountID(item.Type, item.AccountID), err)
	}
	if refreshed, lookupErr := p.store.AccountByID(ctx, item.ID); lookupErr == nil {
		item = refreshed
	}
	return item, nil
}

// CreateManualAccount 手动添加 QQ 音乐或网易云音乐账号。
// 网易云音乐必须先通过 Cookie 校验；网络异常时不会写入未经确认的凭据。
func (p *Pool) CreateManualAccount(ctx context.Context, accountType AccountType, uid, credential string) (PublicAccount, string, error) {
	switch accountType {
	case AccountTypeQQ:
		item, err := p.Upsert(ctx, uid, credential)
		if err != nil {
			return PublicAccount{}, "", err
		}
		warning := ""
		if profile, profileErr := p.RefreshProfile(ctx, item.AccountID); profileErr == nil {
			item = profile
		} else {
			warning = fmt.Sprintf("qm_keyst 已保存，但登录态验证失败: %v", profileErr)
		}
		return item.Public(), warning, nil
	case AccountTypeNetease:
		if p.netease == nil {
			return PublicAccount{}, "", errors.New("网易云音乐客户端不可用")
		}
		state, err := p.netease.Check(ctx, credential, uid)
		if err != nil {
			return PublicAccount{}, "", err
		}
		canonicalUID := strconv.FormatInt(state.UID, 10)
		item, err := p.store.UpsertNeteaseCredentials(ctx, canonicalUID, state.Cookie, state.ExpiresAt)
		if err != nil {
			return PublicAccount{}, "", err
		}
		if state.Nickname != "" || state.AvatarURL != "" {
			if err := p.store.UpdateProfile(ctx, item.ID, state.Nickname, state.AvatarURL); err != nil {
				return item.Public(), "Cookie 已保存，但账号资料缓存失败", nil
			}
			item.Nickname = state.Nickname
			item.AvatarURL = state.AvatarURL
		}
		warning := ""
		if err := p.syncNeteaseVIP(ctx, item, state.Cookie, p.now().UTC()); err != nil {
			warning = fmt.Sprintf("Cookie 已保存，但网易云会员状态查询失败: %v", err)
		}
		if refreshed, lookupErr := p.store.AccountByID(ctx, item.ID); lookupErr == nil {
			item = refreshed
		}
		return item.Public(), warning, nil
	default:
		return PublicAccount{}, "", errors.New("不支持的账号类型")
	}
}

// AuthorizeSource 校验指定平台客户端持有的账号 ID 和 accessKey。
// 校验失败时统一返回 ErrInvalidClientAuthorization，避免泄露账号是否存在。
func (p *Pool) AuthorizeSource(ctx context.Context, accountType AccountType, accountID, accessKey string) (AuthorizedAccount, error) {
	accountID = strings.TrimSpace(accountID)
	accessKey = strings.TrimSpace(accessKey)
	if !accountType.Valid() || accountID == "" || accessKey == "" {
		return AuthorizedAccount{}, ErrInvalidClientAuthorization
	}
	item, err := p.store.accountByTypeAndID(ctx, accountType, accountID)
	if err != nil || !item.LoginValid || item.AccessKey == "" {
		return AuthorizedAccount{}, ErrInvalidClientAuthorization
	}
	if subtle.ConstantTimeCompare([]byte(item.AccessKey), []byte(accessKey)) != 1 {
		return AuthorizedAccount{}, ErrInvalidClientAuthorization
	}
	return AuthorizedAccount{
		ID:        item.ID,
		Type:      item.Type,
		AccountID: item.AccountID,
		Nickname:  item.Nickname,
		AvatarURL: item.AvatarURL,
	}, nil
}

// ClientForAuthorizedAccount 返回指定 QQ 音乐授权账号的客户端实例。
// 该方法不会切换账号池当前活动账号，也不会创建匿名客户端。
func (p *Pool) ClientForAuthorizedAccount(ctx context.Context, authorized AuthorizedAccount) (*oomusic.Client, error) {
	if authorized.Type != AccountTypeQQ {
		return nil, errors.New("只有 QQ 音乐账号可以创建 QQ 客户端")
	}
	item, err := p.store.accountByTypeAndID(ctx, authorized.Type, authorized.AccountID)
	if err != nil {
		return nil, err
	}
	if !item.LoginValid || strings.TrimSpace(item.Credential) == "" {
		return nil, &AccountLoginExpiredError{
			AccountType: item.Type,
			AccountID:   item.ID,
			UINMasked:   maskAccountID(item.Type, item.AccountID),
		}
	}
	return p.clientFor(item)
}

// CredentialForAccount 返回指定平台账号的原始登录凭据，仅供后端内部请求上游使用。
func (p *Pool) CredentialForAccount(ctx context.Context, accountType AccountType, accountID string) (Account, error) {
	if !accountType.Valid() {
		return Account{}, errors.New("账号类型不合法")
	}
	item, err := p.store.accountByTypeAndID(ctx, accountType, accountID)
	if err != nil {
		return Account{}, err
	}
	if !item.LoginValid || strings.TrimSpace(item.Credential) == "" {
		return Account{}, &AccountLoginExpiredError{
			AccountType: item.Type,
			AccountID:   item.ID,
			UINMasked:   maskAccountID(item.Type, item.AccountID),
		}
	}
	return item, nil
}

// SelectedCredential 返回指定平台当前优先级最高的可用账号。
// 没有可用账号时返回 ok=false，由调用方按匿名模式请求上游。
func (p *Pool) SelectedCredential(ctx context.Context, accountType AccountType) (Account, bool, error) {
	if !accountType.Valid() {
		return Account{}, false, errors.New("账号类型不合法")
	}
	if err := p.store.ExpireVIPAccounts(ctx, p.now().UTC()); err != nil {
		return Account{}, false, err
	}
	item, err := p.store.SelectAccountByType(ctx, accountType)
	if errors.Is(err, ErrNoAccount) {
		return Account{}, false, nil
	}
	if err != nil {
		return Account{}, false, err
	}
	return item, true, nil
}

// SelectedCredentialForMedia 从指定平台服务端账号池选择共享媒体请求使用的凭据。
// 网易云 VIP 播放要求 policy=MediaAccountVIP；此时池中没有有效 VIP 会先尝试领取。
// 领取失败不会阻止请求回退到当前可用的普通账号，由上游决定内容是否可用。
func (p *Pool) SelectedCredentialForMedia(ctx context.Context, accountType AccountType, policy MediaAccountPolicy) (Account, bool, error) {
	if policy == MediaAccountVIP && accountType == AccountTypeNetease {
		if _, err := p.ensureNeteaseVIP(ctx); err != nil {
			p.logger.Printf("自动补充网易云音乐会员失败: %v", err)
		}
	}
	return p.SelectedCredential(ctx, accountType)
}

// RefreshProfile 查询并缓存 QQ 用户昵称和头像。
// 该操作不会生成或轮换 accessKey；资料接口失败时返回错误，由调用方决定是否忽略。
func (p *Pool) RefreshProfile(ctx context.Context, uin string) (Account, error) {
	uin = strings.TrimSpace(uin)
	if uin == "" {
		return Account{}, ErrNoAccount
	}
	item, err := p.store.accountByUIN(ctx, uin)
	if err != nil {
		return Account{}, err
	}
	if item.Type != AccountTypeQQ {
		return Account{}, errors.New("当前资料接口只支持 QQ 音乐账号")
	}
	client, err := p.clientFor(item)
	if err != nil {
		return Account{}, fmt.Errorf("创建账号 %s 客户端: %w", maskUIN(item.AccountID), err)
	}
	result, err := p.readUserProfile(ctx, client, item.AccountID)
	if err != nil {
		return Account{}, fmt.Errorf("查询账号 %s 资料: %w", maskUIN(item.AccountID), err)
	}
	if result == nil {
		return Account{}, errors.New("用户资料接口没有返回结果")
	}
	if result.Code == 1000 {
		checkedAt := p.now().UTC()
		_ = p.store.UpdateLoginStatus(ctx, item.ID, false, checkedAt)
		return Account{}, &AccountLoginExpiredError{AccountType: item.Type, AccountID: item.ID, UINMasked: maskUIN(item.AccountID)}
	}
	if result.Code != 0 {
		return Account{}, fmt.Errorf("查询账号 %s 资料返回业务码 %d", maskUIN(item.AccountID), result.Code)
	}
	profile, err := ParseUserProfile(result.Data, item.AccountID)
	if err != nil {
		return Account{}, fmt.Errorf("解析账号 %s 资料: %w", maskUIN(item.AccountID), err)
	}
	if err := p.store.UpdateProfile(ctx, item.ID, profile.Nickname, profile.AvatarURL); err != nil {
		return Account{}, err
	}
	item.Nickname = profile.Nickname
	item.AvatarURL = profile.AvatarURL
	return item, nil
}

// ReadAccountPlaylists 使用指定 UIN 的授权账号读取 QQ 音乐创建歌单。
//
// 该方法只获取该账号对应的 Client，不调用 activate，因此不会改变账号池
// 当前用于搜索、播放等业务请求的活动实例。QQ 音乐明确返回业务码 1000 时，
// 会清除该账号的登录态和 accessKey，并返回 ErrAccountLoginExpired。
func (p *Pool) ReadAccountPlaylists(ctx context.Context, uin string) ([]oomusic.UserPlaylist, error) {
	uin = strings.TrimSpace(uin)
	if uin == "" {
		return nil, ErrNoAccount
	}
	item, err := p.store.accountByUIN(ctx, uin)
	if err != nil {
		return nil, err
	}
	if item.Type != AccountTypeQQ {
		return nil, errors.New("当前歌单接口只支持 QQ 音乐账号")
	}
	if !item.LoginValid {
		return nil, &AccountLoginExpiredError{AccountType: item.Type, AccountID: item.ID, UINMasked: maskUIN(item.AccountID)}
	}
	client, err := p.clientFor(item)
	if err != nil {
		return nil, fmt.Errorf("创建账号 %s 客户端: %w", maskUIN(item.AccountID), err)
	}
	playlists, err := p.readUserPlaylists(ctx, client, item.AccountID)
	if err != nil {
		var apiErr *oomusic.APIError
		if errors.As(err, &apiErr) && apiErr.Code == 1000 {
			checkedAt := p.now().UTC()
			_ = p.store.UpdateLoginStatus(ctx, item.ID, false, checkedAt)
			return nil, &AccountLoginExpiredError{AccountType: item.Type, AccountID: item.ID, UINMasked: maskUIN(item.AccountID)}
		}
		return nil, fmt.Errorf("读取账号 %s 歌单: %w", maskUIN(item.AccountID), err)
	}
	return playlists, nil
}

// ListBoundAccounts 返回所有绑定账号的脱敏视图，供后台管理接口使用。
func (p *Pool) ListBoundAccounts(ctx context.Context) ([]PublicAccount, error) {
	items, err := p.store.ListAccounts(ctx)
	if err != nil {
		return nil, err
	}
	result := make([]PublicAccount, 0, len(items))
	for _, item := range items {
		result = append(result, item.Public())
	}
	return result, nil
}

// UpdateAccountQMKeyst 手动替换指定绑定账号的 qm_keyst。
// 更新成功后立即丢弃该账号的旧 Client；凭据验证失败只作为 warning 返回，
// 已保存的新凭据仍可在后续请求中重试。
func (p *Pool) UpdateAccountQMKeyst(ctx context.Context, id int64, qmKeyst string) (PublicAccount, string, error) {
	p.selectionMu.Lock()
	item, err := p.store.UpdateCredentialsByID(ctx, id, qmKeyst)
	if err != nil {
		p.selectionMu.Unlock()
		return PublicAccount{}, "", err
	}
	p.clientsMu.Lock()
	delete(p.clients, item.ID)
	if p.activeID == item.ID {
		p.activeID = 0
		p.activeClient = nil
	}
	p.clientsMu.Unlock()
	p.selectionMu.Unlock()

	warning := ""
	checkedAt := p.now().UTC()
	if err := p.refreshAccount(ctx, item, checkedAt); err != nil {
		warning = fmt.Sprintf("qm_keyst 已保存，但登录态验证失败: %v", err)
	}
	refreshed, err := p.store.AccountByID(ctx, item.ID)
	if err != nil {
		return item.Public(), warning, nil
	}
	return refreshed.Public(), warning, nil
}

// UpdateAccountCredential 根据账号类型替换 QQ 音乐 qm_keyst 或网易云音乐 Cookie。
func (p *Pool) UpdateAccountCredential(ctx context.Context, id int64, credential string) (PublicAccount, string, error) {
	item, err := p.store.AccountByID(ctx, id)
	if err != nil {
		return PublicAccount{}, "", err
	}
	if item.Type == AccountTypeQQ {
		return p.UpdateAccountQMKeyst(ctx, id, credential)
	}
	if item.Type != AccountTypeNetease {
		return PublicAccount{}, "", errors.New("不支持的账号类型")
	}
	if p.netease == nil {
		return PublicAccount{}, "", errors.New("网易云音乐客户端不可用")
	}
	uid := item.AccountID
	updated, err := p.store.UpdateNeteaseCookieByID(ctx, id, credential, nil)
	if err != nil {
		return PublicAccount{}, "", err
	}
	checkedAt := p.now().UTC()
	state, checkErr := p.netease.Check(ctx, updated.Credential, uid)
	if checkErr != nil {
		warning := fmt.Sprintf("网易云音乐 Cookie 已保存，但登录态验证失败: %v", checkErr)
		if errors.Is(checkErr, netease.ErrUnauthorized) || errors.Is(checkErr, netease.ErrUIDMismatch) {
			if updateErr := p.store.UpdateNeteaseSession(ctx, id, updated.Credential, false, time.Time{}, checkedAt); updateErr != nil {
				return updated.Public(), warning, updateErr
			}
		} else if updateErr := p.store.MarkLoginCheckAttempt(ctx, id, checkedAt); updateErr != nil {
			return updated.Public(), warning, updateErr
		}
		refreshed, lookupErr := p.store.AccountByID(ctx, id)
		if lookupErr != nil {
			return updated.Public(), warning, lookupErr
		}
		return refreshed.Public(), warning, nil
	}
	expiresAt := time.Time{}
	if state.ExpiresAt != nil {
		expiresAt = *state.ExpiresAt
	}
	if err := p.store.UpdateNeteaseSession(ctx, id, state.Cookie, true, expiresAt, checkedAt); err != nil {
		return updated.Public(), "", err
	}
	if state.Nickname != "" || state.AvatarURL != "" {
		_ = p.store.UpdateProfile(ctx, id, state.Nickname, state.AvatarURL)
	}
	warning := ""
	if err := p.syncNeteaseVIP(ctx, updated, state.Cookie, checkedAt); err != nil {
		warning = fmt.Sprintf("Cookie 已更新，但网易云会员状态查询失败: %v", err)
	}
	refreshed, err := p.store.AccountByID(ctx, id)
	if err != nil {
		return updated.Public(), "", err
	}
	return refreshed.Public(), warning, nil
}

// DeleteBoundAccount 删除指定绑定账号并清理其缓存 Client。
func (p *Pool) DeleteBoundAccount(ctx context.Context, id int64) error {
	p.selectionMu.Lock()
	defer p.selectionMu.Unlock()
	if err := p.store.DeleteAccountByID(ctx, id); err != nil {
		return err
	}
	p.clientsMu.Lock()
	delete(p.clients, id)
	if p.activeID == id {
		p.activeID = 0
		p.activeClient = nil
	}
	p.clientsMu.Unlock()
	return nil
}

// RefreshBoundAccount 立即检查指定绑定账号的登录态和会员状态。
func (p *Pool) RefreshBoundAccount(ctx context.Context, id int64) (PublicAccount, error) {
	item, err := p.store.AccountByID(ctx, id)
	if err != nil {
		return PublicAccount{}, err
	}
	checkedAt := p.now().UTC()
	var refreshErr error
	if item.Type == AccountTypeNetease {
		refreshErr = p.refreshNeteaseAccount(ctx, item, true, checkedAt)
	} else {
		refreshErr = p.refreshAccount(ctx, item, checkedAt)
	}
	refreshed, lookupErr := p.store.AccountByID(ctx, id)
	if lookupErr != nil {
		return item.Public(), refreshErr
	}
	return refreshed.Public(), refreshErr
}

// RefreshAll 立即刷新所有账号的会员和登录状态。单个账号失败不会阻止其他账号刷新。
func (p *Pool) RefreshAll(ctx context.Context) error {
	accounts, err := p.store.ListAccounts(ctx)
	if err != nil {
		return err
	}
	var errs []error
	for _, item := range accounts {
		checkedAt := p.now().UTC()
		var refreshErr error
		switch item.Type {
		case AccountTypeNetease:
			if !item.LoginValid {
				continue
			}
			refreshErr = p.refreshNeteaseAccount(ctx, item, false, checkedAt)
		default:
			refreshErr = p.refreshAccount(ctx, item, checkedAt)
		}
		if refreshErr != nil {
			errs = append(errs, refreshErr)
		}
	}
	return errors.Join(errs...)
}

// EnsureMemberships 保证 QQ 音乐和网易云音乐各有一个可用会员账号。
// 已经存在有效会员时不会领取新福利；领取成功后立即停止并可进入冷却时间。
func (p *Pool) EnsureMemberships(ctx context.Context) error {
	var errs []error
	if _, err := p.SelectedStatus(ctx); err != nil {
		errs = append(errs, fmt.Errorf("确保 QQ 音乐会员账号: %w", err))
	}
	if _, err := p.ensureNeteaseVIP(ctx); err != nil {
		errs = append(errs, fmt.Errorf("确保网易云音乐会员账号: %w", err))
	}
	return errors.Join(errs...)
}

func (p *Pool) ensureNeteaseVIP(ctx context.Context) (*Account, error) {
	p.neteaseClaimMu.Lock()
	defer p.neteaseClaimMu.Unlock()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := p.store.ExpireVIPAccounts(ctx, p.now().UTC()); err != nil {
		return nil, err
	}
	accounts, err := p.store.ListUsableAccountsByType(ctx, AccountTypeNetease)
	if err != nil {
		return nil, err
	}
	now := p.now().UTC()
	var errs []error
	for index := range accounts {
		if accounts[index].VipLevel == VipLevelNone {
			continue
		}
		if accounts[index].VipCheckedAt != nil && now.Sub(*accounts[index].VipCheckedAt) < p.refreshInterval {
			return &accounts[index], nil
		}
		if err := p.syncNeteaseVIP(ctx, accounts[index], accounts[index].Credential, now); err != nil {
			errs = append(errs, fmt.Errorf("账号 %s 刷新会员状态: %w", maskAccountID(accounts[index].Type, accounts[index].AccountID), err))
			continue
		}
		refreshed, lookupErr := p.store.AccountByID(ctx, accounts[index].ID)
		if lookupErr != nil {
			errs = append(errs, lookupErr)
			continue
		}
		accounts[index] = refreshed
		if refreshed.VipLevel != VipLevelNone {
			return &refreshed, nil
		}
	}
	if len(accounts) == 0 {
		return nil, nil
	}
	hasCandidate := false
	for _, item := range accounts {
		if item.VipLevel == VipLevelNone {
			hasCandidate = true
			break
		}
	}
	if !hasCandidate {
		return nil, errors.Join(errs...)
	}
	if !p.lastNeteaseClaimAt.IsZero() && now.Sub(p.lastNeteaseClaimAt) < p.claimCooldown {
		return nil, nil
	}
	p.lastNeteaseClaimAt = now
	if p.neteaseVIPFeed == nil || p.claimNeteaseVIP == nil || p.netease == nil {
		return nil, errors.New("网易云会员领取服务不可用")
	}
	invitations, feedErr := p.neteaseVIPFeed(ctx)
	if len(invitations) == 0 {
		return nil, errors.Join(append(errs, feedErr)...)
	}
	errs = append(errs, feedErr)
	for _, item := range accounts {
		if err := ctx.Err(); err != nil {
			return nil, errors.Join(append(errs, err)...)
		}
		if item.VipLevel != VipLevelNone {
			continue
		}
		// 领取前强制刷新一次，避免数据库仍显示普通用户但账号实际已有会员。
		if err := p.syncNeteaseVIP(ctx, item, item.Credential, now); err != nil {
			errs = append(errs, fmt.Errorf("账号 %s 领取前查询会员状态: %w", maskAccountID(item.Type, item.AccountID), err))
			continue
		}
		refreshed, lookupErr := p.store.AccountByID(ctx, item.ID)
		if lookupErr != nil {
			errs = append(errs, lookupErr)
			continue
		}
		if refreshed.VipLevel != VipLevelNone {
			return &refreshed, nil
		}
		item = refreshed
		attempts := min(len(invitations), neteaseVIPClaimAttempts)
		for index := 0; index < attempts; index++ {
			if err := ctx.Err(); err != nil {
				return nil, errors.Join(append(errs, err)...)
			}
			_, claimErr := p.claimNeteaseVIP(ctx, item, invitations[index])
			if claimErr != nil {
				if errors.Is(claimErr, netease.ErrUnauthorized) {
					_ = p.store.UpdateLoginStatus(ctx, item.ID, false, p.now().UTC())
					errs = append(errs, fmt.Errorf("账号 %s 登录态已失效: %w", maskAccountID(item.Type, item.AccountID), claimErr))
					break
				}
				if errors.Is(claimErr, netease.ErrInvitationRisk) {
					if syncErr := p.syncNeteaseVIP(ctx, item, item.Credential, p.now().UTC()); syncErr == nil {
						if updated, lookupErr := p.store.AccountByID(ctx, item.ID); lookupErr == nil && updated.VipLevel != VipLevelNone {
							return &updated, nil
						}
					}
					return nil, errors.Join(append(errs, claimErr)...)
				}
				errs = append(errs, fmt.Errorf("账号 %s 领取网易云邀请 %s: %w", maskAccountID(item.Type, item.AccountID), invitations[index].ID, claimErr))
				if errors.Is(claimErr, netease.ErrInvitationAlreadyAccepted) {
					if syncErr := p.syncNeteaseVIP(ctx, item, item.Credential, p.now().UTC()); syncErr == nil {
						if updated, lookupErr := p.store.AccountByID(ctx, item.ID); lookupErr == nil && updated.VipLevel != VipLevelNone {
							return &updated, nil
						}
					}
					break
				}
				continue
			}

			checkedAt := p.now().UTC()
			if err := p.store.UpdateLoginStatus(ctx, item.ID, true, checkedAt); err != nil {
				errs = append(errs, err)
			}
			vipErr := p.syncNeteaseVIP(ctx, item, item.Credential, checkedAt)
			if vipErr != nil {
				errs = append(errs, fmt.Errorf("账号 %s 领取后刷新会员状态: %w", maskAccountID(item.Type, item.AccountID), vipErr))
			}
			updated, lookupErr := p.store.AccountByID(ctx, item.ID)
			if lookupErr == nil && updated.VipLevel != VipLevelNone {
				p.logger.Printf("网易云音乐账号 %s 已成功领取会员权益", maskAccountID(item.Type, item.AccountID))
				return &updated, nil
			}
			// 会员状态可能存在传播延迟；先以本地状态保证当前进程只保留一个会员账号。
			if err := p.store.UpdateVipStatus(ctx, item.ID, VipLevelVIP, time.Time{}, checkedAt); err != nil {
				errs = append(errs, err)
			}
			item.VipLevel = VipLevelVIP
			item.VipExpiresAt = nil
			item.VipCheckedAt = &checkedAt
			p.logger.Printf("网易云音乐账号 %s 已领取会员权益，等待状态传播", maskAccountID(item.Type, item.AccountID))
			return &item, nil
		}
	}
	return nil, errors.Join(errs...)
}

// Client 返回本次请求应使用的 QQ 音乐客户端。
// 同一账号会复用同一个 Client；账号过期或优先级变化时只切换已缓存的实例。
// 数据库为空或所有账号登录态失效时返回匿名客户端。
func (p *Pool) Client(ctx context.Context) (*oomusic.Client, error) {
	return p.ClientForMedia(ctx, MediaAccountVIP)
}

// ClientForMedia 从 QQ 音乐服务端账号池选择媒体请求使用的客户端。
// MediaAccountVIP 时，如果池中没有 VIP 会先尝试补充；MediaAccountAny 时只刷新和选择，
// 不因为一次搜索或元数据请求而触发领卡。
func (p *Pool) ClientForMedia(ctx context.Context, policy MediaAccountPolicy) (*oomusic.Client, error) {
	p.selectionMu.Lock()
	defer p.selectionMu.Unlock()

	item, err := p.selectCurrentAccount(ctx, policy == MediaAccountVIP)
	if errors.Is(err, ErrNoAccount) {
		return p.anonymousClient()
	}
	if err != nil {
		return nil, err
	}
	return p.activate(item)
}

// SelectedStatus 返回当前优先级最高账号的脱敏状态。
// 当所有可用账号都不是会员时，会先尝试一次受冷却时间限制的官方体验卡领取。
func (p *Pool) SelectedStatus(ctx context.Context) (PublicAccount, error) {
	p.selectionMu.Lock()
	defer p.selectionMu.Unlock()

	item, err := p.selectCurrentAccount(ctx, true)
	if errors.Is(err, ErrNoAccount) {
		return PublicAccount{
			AccountType:     AccountTypeQQ,
			AccountTypeName: AccountTypeQQ.Name(),
			Available:       false,
			LoggedIn:        false,
			VipLevel:        VipLevelNone,
			VipLevelName:    vipLevelName(VipLevelNone),
			LoginValid:      false,
		}, nil
	}
	if err != nil {
		return PublicAccount{}, err
	}
	return item.Public(), nil
}

// CheckAllLogins 检查数据库内所有账号的登录态。QQ 音乐只做状态检测；
// 网易云音乐会在临近授权到期时先尝试续期，明确失效后标记过期并在后续任务中跳过。
func (p *Pool) CheckAllLogins(ctx context.Context) (LoginCheckReport, error) {
	p.refreshMu.Lock()
	defer p.refreshMu.Unlock()

	report := LoginCheckReport{CheckedAt: p.now().UTC()}
	accounts, err := p.store.ListAccounts(ctx)
	if err != nil {
		return report, err
	}

	var errs []error
	for _, item := range accounts {
		check := LoginCheck{
			AccountType: item.Type,
			AccountID:   item.ID,
			UINMasked:   maskAccountID(item.Type, item.AccountID),
			CheckedAt:   p.now().UTC(),
		}
		if item.Type == AccountTypeNetease {
			if !item.LoginValid {
				check.Error = "账号登录态已过期，跳过刷新"
				report.Accounts = append(report.Accounts, check)
				continue
			}
			neteaseCheck, checkErr := p.checkNeteaseAccount(ctx, item, false, check.CheckedAt)
			report.Accounts = append(report.Accounts, neteaseCheck)
			if neteaseCheck.Expired {
				report.Expired = append(report.Expired, neteaseCheck)
			}
			if checkErr != nil {
				errs = append(errs, fmt.Errorf("检查网易云音乐账号 %s 登录态: %w", neteaseCheck.UINMasked, checkErr))
			}
			continue
		}
		client, err := p.clientFor(item)
		if err != nil {
			check.Error = err.Error()
			report.Accounts = append(report.Accounts, check)
			errs = append(errs, fmt.Errorf("创建账号 %s 客户端: %w", check.UINMasked, err))
			continue
		}
		result, err := p.readVipStatus(ctx, client, "")
		if err != nil {
			check.Error = err.Error()
			_ = p.store.MarkLoginCheckAttempt(ctx, item.ID, check.CheckedAt)
			report.Accounts = append(report.Accounts, check)
			errs = append(errs, fmt.Errorf("检查账号 %s 登录态: %w", check.UINMasked, err))
			continue
		}
		if result.Code == 1000 {
			check.Expired = true
			check.Error = "QQ 音乐登录态已过期"
			if err := p.store.UpdateLoginStatus(ctx, item.ID, false, check.CheckedAt); err != nil {
				errs = append(errs, fmt.Errorf("保存账号 %s 登录失效状态: %w", check.UINMasked, err))
			}
			if err := p.store.UpdateVipStatus(ctx, item.ID, VipLevelNone, time.Time{}, check.CheckedAt); err != nil {
				errs = append(errs, fmt.Errorf("清除账号 %s 会员状态: %w", check.UINMasked, err))
			}
			report.Accounts = append(report.Accounts, check)
			report.Expired = append(report.Expired, check)
			continue
		}
		if result.Code != 0 {
			check.Error = fmt.Sprintf("QQ 音乐返回业务码 %d", result.Code)
			_ = p.store.MarkLoginCheckAttempt(ctx, item.ID, check.CheckedAt)
			report.Accounts = append(report.Accounts, check)
			errs = append(errs, fmt.Errorf("检查账号 %s 登录态: %s", check.UINMasked, check.Error))
			continue
		}
		status, err := ParseVipStatus(result.Data, item.AccountID, check.CheckedAt)
		if err != nil {
			check.Error = err.Error()
			_ = p.store.MarkLoginCheckAttempt(ctx, item.ID, check.CheckedAt)
			report.Accounts = append(report.Accounts, check)
			errs = append(errs, fmt.Errorf("解析账号 %s 登录状态: %w", check.UINMasked, err))
			continue
		}
		check.Valid = true
		expiresAt := time.Time{}
		if status.ExpiresAt != nil {
			expiresAt = *status.ExpiresAt
		}
		if err := p.store.UpdateLoginStatus(ctx, item.ID, true, check.CheckedAt); err != nil {
			errs = append(errs, err)
		}
		if err := p.store.UpdateVipStatus(ctx, item.ID, status.Level, expiresAt, check.CheckedAt); err != nil {
			errs = append(errs, err)
		}
		report.Accounts = append(report.Accounts, check)
	}
	return report, errors.Join(errs...)
}

// RefreshStale 立即刷新超过既定间隔未检查的账号，定时任务也可调用。
func (p *Pool) RefreshStale(ctx context.Context) error {
	return p.refreshStale(ctx)
}

func (p *Pool) selectCurrentAccount(ctx context.Context, requireVIP bool) (Account, error) {
	if err := p.refreshStale(ctx); err != nil {
		p.logger.Printf("刷新账号状态失败，将使用数据库中的最近状态: %v", err)
	}
	if err := p.store.ExpireVIPAccounts(ctx, p.now().UTC()); err != nil {
		p.logger.Printf("更新过期会员状态失败: %v", err)
	}

	item, err := p.store.SelectAccount(ctx)
	if err != nil {
		return Account{}, err
	}
	if item.VipLevel != VipLevelNone {
		return item, nil
	}
	if !requireVIP {
		return item, nil
	}

	claimed, claimErr := p.claimVIP(ctx)
	if claimErr != nil {
		p.logger.Printf("自动领取体验卡失败: %v", claimErr)
	}
	if claimed != nil {
		return *claimed, nil
	}
	return item, nil
}

func (p *Pool) claimVIP(ctx context.Context) (*Account, error) {
	p.claimMu.Lock()
	defer p.claimMu.Unlock()

	if err := ctx.Err(); err != nil {
		return nil, err
	}

	now := p.now().UTC()
	if !p.lastClaimAt.IsZero() && now.Sub(p.lastClaimAt) < p.claimCooldown {
		return nil, nil
	}
	p.lastClaimAt = now

	candidates, feedErr := p.experienceCardCandidates(ctx)
	if len(candidates) == 0 {
		return nil, feedErr
	}

	accounts, err := p.store.ListUsableAccounts(ctx)
	if err != nil {
		return nil, err
	}
	if len(accounts) == 0 {
		return nil, nil
	}

	errs := []error{feedErr}
	resolvedFeedCards := make(map[string]oomusic.ExperienceCardRequest)
	feedResolveErrors := make(map[string]error)
	feedResolves := 0
	for _, item := range accounts {
		if err := ctx.Err(); err != nil {
			return nil, errors.Join(append(errs, err)...)
		}
		if item.VipLevel != VipLevelNone {
			continue
		}
		client, err := p.clientFor(item)
		if err != nil {
			errs = append(errs, fmt.Errorf("创建账号 %s 客户端: %w", maskUIN(item.AccountID), err))
			continue
		}
		for _, candidate := range candidates {
			request := candidate.Request
			if candidate.FeedID != "" {
				if cached, ok := resolvedFeedCards[candidate.FeedID]; ok {
					request = cached
				} else {
					if _, failed := feedResolveErrors[candidate.FeedID]; failed {
						continue
					}
					if p.resolveExperienceCard == nil {
						feedResolveErrors[candidate.FeedID] = errors.New("体验卡链接解析服务不可用")
						errs = append(errs, feedResolveErrors[candidate.FeedID])
						continue
					}
					if feedResolves >= experienceCardResolveLimit {
						continue
					}
					feedResolves++
					resolved, resolveErr := p.resolveExperienceCard(ctx, candidate.FeedID)
					if resolveErr != nil {
						resolvedErr := fmt.Errorf("解析体验卡候选 %s: %w", candidate.FeedID, resolveErr)
						feedResolveErrors[candidate.FeedID] = resolvedErr
						errs = append(errs, resolvedErr)
						continue
					}
					resolvedFeedCards[candidate.FeedID] = resolved
					request = resolved
				}
			}
			if strings.TrimSpace(request.CardID) == "" {
				errs = append(errs, fmt.Errorf("账号 %s 的体验卡候选没有 cardid", maskUIN(item.AccountID)))
				continue
			}
			result, err := p.claimExperienceCard(ctx, client, request)
			if err != nil {
				if errors.Is(err, oomusic.ErrExperienceCardAlreadyMember) {
					if refreshErr := p.refreshAccount(ctx, item, p.now().UTC()); refreshErr != nil {
						errs = append(errs, refreshErr)
					}
					selected, selectErr := p.store.SelectAccount(ctx)
					if selectErr == nil && selected.VipLevel != VipLevelNone {
						return &selected, nil
					}
				}
				errs = append(errs, fmt.Errorf("账号 %s 领取体验卡 %s: %w", maskUIN(item.AccountID), request.CardID, err))
				continue
			}
			if result == nil {
				errs = append(errs, fmt.Errorf("账号 %s 领取体验卡 %s 返回空结果", maskUIN(item.AccountID), request.CardID))
				continue
			}

			checkedAt := p.now().UTC()
			if err := p.store.UpdateLoginStatus(ctx, item.ID, true, checkedAt); err != nil {
				errs = append(errs, fmt.Errorf("账号 %s 领取成功后更新登录状态: %w", maskUIN(item.AccountID), err))
			}
			refreshErr := p.refreshAccount(ctx, item, checkedAt)
			if refreshErr != nil {
				errs = append(errs, fmt.Errorf("账号 %s 领取成功后刷新会员状态: %w", maskUIN(item.AccountID), refreshErr))
			}

			refreshed, lookupErr := p.store.accountByTypeAndID(ctx, item.Type, item.AccountID)
			if lookupErr != nil {
				errs = append(errs, fmt.Errorf("读取账号 %s 领取后的状态: %w", maskUIN(item.AccountID), lookupErr))
			} else {
				item = refreshed
			}
			// 领取已经成功时，即使会员状态有短暂传播延迟，也应让当前进程先使用该账号。
			if item.VipLevel == VipLevelNone {
				if err := p.store.UpdateVipStatus(ctx, item.ID, VipLevelVIP, time.Time{}, checkedAt); err != nil {
					errs = append(errs, fmt.Errorf("账号 %s 写入领取后的 VIP 状态: %w", maskUIN(item.AccountID), err))
				}
				item.VipLevel = VipLevelVIP
				item.VipExpiresAt = nil
				item.VipCheckedAt = &checkedAt
			}
			p.logger.Printf("账号 %s 已成功领取体验卡 %s", maskUIN(item.AccountID), request.CardID)
			return &item, nil
		}
	}
	return nil, errors.Join(errs...)
}

func (p *Pool) experienceCardCandidates(ctx context.Context) ([]experienceCardCandidate, error) {
	candidates := append([]experienceCardCandidate(nil), p.experienceCards...)
	var feedErr error
	if p.experienceFeed != nil {
		liveCandidates, err := p.experienceFeed(ctx)
		if err != nil {
			feedErr = fmt.Errorf("实时获取体验卡链接: %w", err)
		} else {
			candidates = append(candidates, liveCandidates...)
		}
	}

	seen := make(map[string]struct{}, len(candidates))
	deduplicated := candidates[:0]
	for _, candidate := range candidates {
		key := candidate.Request.CardID
		if key != "" {
			key = "card:" + key
		} else if candidate.FeedID != "" {
			key = "feed:" + candidate.FeedID
		} else {
			continue
		}
		if _, exists := seen[key]; exists {
			continue
		}
		seen[key] = struct{}{}
		deduplicated = append(deduplicated, candidate)
	}
	return deduplicated, feedErr
}

func (p *Pool) refreshStale(ctx context.Context) error {
	p.refreshMu.Lock()
	defer p.refreshMu.Unlock()

	staleBefore := p.now().UTC().Add(-p.refreshInterval)
	accounts, err := p.store.ListStaleAccounts(ctx, staleBefore)
	if err != nil {
		return err
	}
	return p.refreshAccounts(ctx, accounts)
}

func (p *Pool) refreshAccounts(ctx context.Context, accounts []Account) error {
	var errs []error
	for _, item := range accounts {
		checkedAt := p.now().UTC()
		if err := p.refreshAccount(ctx, item, checkedAt); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

func (p *Pool) refreshNeteaseAccount(ctx context.Context, item Account, forceRefresh bool, checkedAt time.Time) error {
	check, err := p.checkNeteaseAccount(ctx, item, forceRefresh, checkedAt)
	if err != nil {
		return err
	}
	if check.Expired {
		return &AccountLoginExpiredError{
			AccountType: AccountTypeNetease,
			AccountID:   item.ID,
			UINMasked:   check.UINMasked,
		}
	}
	return nil
}

func (p *Pool) checkNeteaseAccount(ctx context.Context, item Account, forceRefresh bool, checkedAt time.Time) (LoginCheck, error) {
	check := LoginCheck{
		AccountType: AccountTypeNetease,
		AccountID:   item.ID,
		UINMasked:   maskAccountID(item.Type, item.AccountID),
		CheckedAt:   checkedAt.UTC(),
	}
	if p.netease == nil {
		check.Error = "网易云音乐客户端不可用"
		return check, errors.New(check.Error)
	}
	if !item.LoginValid {
		check.Expired = true
		check.Error = "账号登录态已过期，跳过刷新"
		return check, nil
	}

	uid := item.AccountID
	shouldRefresh := forceRefresh || item.LoginExpiresAt == nil || !item.LoginExpiresAt.After(checkedAt.Add(neteaseRefreshLead))
	var (
		state netease.AccountState
		err   error
	)
	if shouldRefresh {
		state, err = p.netease.Refresh(ctx, item.Credential, uid)
		if err != nil && !errors.Is(err, netease.ErrUnauthorized) && !errors.Is(err, netease.ErrUIDMismatch) {
			// 刷新接口失败不直接判死，继续做一次普通登录态检测。
			state, err = p.netease.Check(ctx, item.Credential, uid)
		}
	} else {
		state, err = p.netease.Check(ctx, item.Credential, uid)
	}
	if err != nil {
		check.Error = err.Error()
		if errors.Is(err, netease.ErrUnauthorized) || errors.Is(err, netease.ErrUIDMismatch) {
			check.Expired = true
			if saveErr := p.store.UpdateNeteaseSession(ctx, item.ID, item.Credential, false, time.Time{}, checkedAt); saveErr != nil {
				return check, errors.Join(err, saveErr)
			}
			return check, nil
		}
		_ = p.store.MarkLoginCheckAttempt(ctx, item.ID, checkedAt)
		return check, err
	}

	expiresAt := time.Time{}
	if state.ExpiresAt != nil {
		expiresAt = *state.ExpiresAt
	} else if item.LoginExpiresAt != nil {
		expiresAt = *item.LoginExpiresAt
	}
	if err := p.store.UpdateNeteaseSession(ctx, item.ID, state.Cookie, true, expiresAt, checkedAt); err != nil {
		return check, err
	}
	if state.Nickname != "" || state.AvatarURL != "" {
		_ = p.store.UpdateProfile(ctx, item.ID, state.Nickname, state.AvatarURL)
	}
	vipErr := p.syncNeteaseVIP(ctx, item, state.Cookie, checkedAt)
	check.Valid = true
	if vipErr != nil {
		check.Error = vipErr.Error()
	}
	return check, vipErr
}

func (p *Pool) syncNeteaseVIP(ctx context.Context, item Account, cookie string, checkedAt time.Time) error {
	if p.netease == nil {
		return errors.New("网易云音乐客户端不可用")
	}
	uid := item.AccountID
	status, err := p.netease.GetVIPStatus(ctx, cookie, uid)
	if err != nil {
		_ = p.store.MarkVipCheckAttempt(ctx, item.ID, checkedAt)
		return err
	}
	level := VipLevelNone
	expiresAt := time.Time{}
	if status.Active {
		level = status.Level
		if status.ExpiresAt != nil {
			expiresAt = *status.ExpiresAt
		}
	}
	return p.store.UpdateVipStatus(ctx, item.ID, level, expiresAt, checkedAt)
}

func (p *Pool) refreshAccount(ctx context.Context, item Account, checkedAt time.Time) error {
	if item.Type != AccountTypeQQ {
		return errors.New("非 QQ 音乐账号不能使用 QQ 会员刷新")
	}
	client, err := p.clientFor(item)
	if err != nil {
		return fmt.Errorf("创建账号 %s 客户端: %w", maskUIN(item.AccountID), err)
	}
	result, err := p.readVipStatus(ctx, client, "")
	if err != nil {
		_ = p.store.MarkVipCheckAttempt(ctx, item.ID, checkedAt)
		_ = p.store.MarkLoginCheckAttempt(ctx, item.ID, checkedAt)
		return fmt.Errorf("查询账号 %s 会员状态: %w", maskUIN(item.AccountID), err)
	}
	if result.Code == 1000 {
		_ = p.store.UpdateLoginStatus(ctx, item.ID, false, checkedAt)
		_ = p.store.UpdateVipStatus(ctx, item.ID, VipLevelNone, time.Time{}, checkedAt)
		return &AccountLoginExpiredError{AccountType: item.Type, AccountID: item.ID, UINMasked: maskUIN(item.AccountID)}
	}
	if result.Code != 0 {
		_ = p.store.MarkVipCheckAttempt(ctx, item.ID, checkedAt)
		_ = p.store.MarkLoginCheckAttempt(ctx, item.ID, checkedAt)
		return fmt.Errorf("查询账号 %s 会员状态返回业务码 %d", maskUIN(item.AccountID), result.Code)
	}
	status, err := ParseVipStatus(result.Data, item.AccountID, checkedAt)
	if err != nil {
		_ = p.store.MarkVipCheckAttempt(ctx, item.ID, checkedAt)
		_ = p.store.MarkLoginCheckAttempt(ctx, item.ID, checkedAt)
		return fmt.Errorf("解析账号 %s 会员状态: %w", maskUIN(item.AccountID), err)
	}
	expiresAt := time.Time{}
	if status.ExpiresAt != nil {
		expiresAt = *status.ExpiresAt
	}
	if err := p.store.UpdateLoginStatus(ctx, item.ID, true, checkedAt); err != nil {
		return err
	}
	if err := p.store.UpdateVipStatus(ctx, item.ID, status.Level, expiresAt, checkedAt); err != nil {
		return err
	}
	return nil
}

func (p *Pool) clientFor(item Account) (*oomusic.Client, error) {
	p.clientsMu.Lock()
	defer p.clientsMu.Unlock()

	if cached, ok := p.clients[item.ID]; ok && cached.accountID == item.AccountID && cached.credential == item.Credential {
		return cached.client, nil
	}
	client, err := p.newClient(item)
	if err != nil {
		return nil, err
	}
	p.clients[item.ID] = cachedClient{
		accountID:  item.AccountID,
		credential: item.Credential,
		client:     client,
	}
	return client, nil
}

func (p *Pool) activate(item Account) (*oomusic.Client, error) {
	client, err := p.clientFor(item)
	if err != nil {
		return nil, err
	}
	p.clientsMu.Lock()
	p.activeID = item.ID
	p.activeClient = client
	p.clientsMu.Unlock()
	return client, nil
}

func (p *Pool) anonymousClient() (*oomusic.Client, error) {
	p.clientsMu.Lock()
	defer p.clientsMu.Unlock()
	if p.anonymous != nil {
		return p.anonymous, nil
	}
	client, err := p.newClient(Account{})
	if err != nil {
		return nil, err
	}
	p.anonymous = client
	return client, nil
}
