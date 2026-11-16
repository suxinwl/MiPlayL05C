package oomusic

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	experienceCardModule             = "music.vip.VipFreeCardSvr"
	experienceCardDefaultFrom        = "好友邀请赠送"
	experienceCardMethodCheckCard    = "CheckCard"
	experienceCardMethodClaimCard    = "GetCard"
	experienceCardSourceQueryADTAG   = "ADTAG"
	experienceCardSourceQueryADTAGLC = "adtag"
	experienceCardSourceQuerySource  = "source"
)

// ExperienceCardSource 是 QQ 音乐体验卡页面 ADTAG/source 参数对应的领取来源。
type ExperienceCardSource int

const (
	// ExperienceCardSourceDefault 对应普通分享链接或 yy_gnyy_hytyk 等活动来源。
	ExperienceCardSourceDefault ExperienceCardSource = 0
	// ExperienceCardSourceXQY 对应 ADTAG=xqy。
	ExperienceCardSourceXQY ExperienceCardSource = 1
	// ExperienceCardSourceCDY 对应 ADTAG=cdy。
	ExperienceCardSourceCDY ExperienceCardSource = 2
	// ExperienceCardSourcePrivilege 对应 ADTAG=privilege。
	ExperienceCardSourcePrivilege ExperienceCardSource = 3
)

// Valid 判断来源值是否为 QQ 音乐页面支持的 0 到 3。
func (s ExperienceCardSource) Valid() bool {
	return s >= ExperienceCardSourceDefault && s <= ExperienceCardSourcePrivilege
}

func (s ExperienceCardSource) String() string {
	switch s {
	case ExperienceCardSourceXQY:
		return "xqy"
	case ExperienceCardSourceCDY:
		return "cdy"
	case ExperienceCardSourcePrivilege:
		return "privilege"
	default:
		return "default"
	}
}

var (
	// ErrInvalidExperienceCard 表示体验卡 ID、来源或领取链接无效。
	ErrInvalidExperienceCard = errors.New("invalid QQ Music experience card")
	// ErrExperienceCardLoginRequired 表示当前客户端没有提供 UIN 和 qm_keyst。
	ErrExperienceCardLoginRequired = errors.New("QQ Music login credentials are required to claim an experience card")
	// ErrExperienceCardNotFound 表示体验卡不存在、已失效或服务端没有返回卡片信息。
	ErrExperienceCardNotFound = errors.New("QQ Music experience card was not found")
	// ErrExperienceCardAlreadyMember 表示当前账号仍有有效 QQ 音乐会员，不能领取非会员体验卡。
	ErrExperienceCardAlreadyMember = errors.New("the QQ Music account already has an active membership")
	// ErrExperienceCardAlreadyClaimed 表示当前账号已经领取过这张体验卡。
	ErrExperienceCardAlreadyClaimed = errors.New("the experience card has already been claimed by this account")
	// ErrExperienceCardExhausted 表示体验卡已被领完。
	ErrExperienceCardExhausted = errors.New("the experience card has no remaining quota")
	// ErrExperienceCardMonthlyLimit 表示当前账号本月已经领取过体验卡。
	ErrExperienceCardMonthlyLimit = errors.New("the account has already claimed an experience card this month")
	// ErrExperienceCardClaimFailed 表示 QQ 音乐拒绝了领取请求。
	ErrExperienceCardClaimFailed = errors.New("QQ Music rejected the experience card claim")
	// ErrExperienceCardAPI 表示体验卡接口返回了未知业务错误。
	ErrExperienceCardAPI = errors.New("QQ Music experience card API error")
)

// ExperienceCardAPIError 保留体验卡接口的方法名、业务码和原始数据，
// 同时可通过 errors.Is 判断已知的领取失败原因。
type ExperienceCardAPIError struct {
	// Method 是 CheckCard、GetCard 等 QQ 音乐方法名。
	Method string
	// Code 是 QQ 音乐返回的业务错误码。
	Code int
	// Err 是对应的稳定错误分类。
	Err error
	// Data 是接口返回的原始 data，便于上层记录诊断信息。
	Data json.RawMessage
}

// Error 实现 error 接口。
func (e *ExperienceCardAPIError) Error() string {
	if e == nil {
		return ErrExperienceCardAPI.Error()
	}
	return fmt.Sprintf("QQ Music %s failed with code %d: %v", e.Method, e.Code, e.Err)
}

// Unwrap 返回稳定的错误分类，供 errors.Is/errors.As 使用。
func (e *ExperienceCardAPIError) Unwrap() error {
	if e == nil || e.Err == nil {
		return ErrExperienceCardAPI
	}
	return e.Err
}

// ExperienceCardRequest 描述一次官方体验卡查询或领取请求。
// CardID 是官方链接中的 cardid；完整链接请先调用 ParseExperienceCardLink。
type ExperienceCardRequest struct {
	// CardID 是体验卡 ID；传完整官方链接时请先调用 ParseExperienceCardLink。
	CardID string
	// Source 是页面 ADTAG 对应的领取来源，普通活动链接使用 0。
	Source ExperienceCardSource
	// From 是出现在领取记录中的来源文案。
	From string
}

// ExperienceCardMessage 是体验卡展示文案。
type ExperienceCardMessage struct {
	Title   string
	Content string
	Picture string
}

// ExperienceCardPerson 是官方体验卡返回的拥有者或领取者账号数据。
type ExperienceCardPerson struct {
	UIN      string
	Nickname string
	Avatar   string
	UniqueID string
	UsedAt   *time.Time
	Extra    json.RawMessage
}

// ExperienceCard 是 QQ 音乐 VipFreeCardSvr 返回的规范化体验卡信息。
type ExperienceCard struct {
	// CardID 是官方字段 giftID。
	CardID string
	// Status 是官方卡片状态。
	Status int
	// Sum 是该卡总数量。
	Sum int
	// Left 是剩余可领取数量。
	Left int
	// CreatedAt 是卡片创建时间。
	CreatedAt *time.Time
	// OwnerUIN 是卡片分享者 UIN。
	OwnerUIN string
	// Owner 是分享者资料。
	Owner ExperienceCardPerson
	// Recipients 是已经领取过该卡的账号列表。
	Recipients []ExperienceCardPerson
	// Message 是卡片展示文案。
	Message ExperienceCardMessage
	// Raw 是 CheckCard 或 GetCard 返回的原始 data。
	Raw json.RawMessage
}

// HasRecipient 判断指定 UIN 是否已经在体验卡领取名单中。
func (c ExperienceCard) HasRecipient(uin string) bool {
	uin = strings.TrimSpace(uin)
	if uin == "" {
		return false
	}
	for _, recipient := range c.Recipients {
		if strings.TrimSpace(recipient.UIN) == uin {
			return true
		}
	}
	return false
}

// ExperienceCardEligibility 是领取前的本地资格检查结果。
// Eligible=false 不等于接口失败，调用方可直接展示对应原因。
type ExperienceCardEligibility struct {
	// Eligible 表示当前账号目前满足本地预检查。
	Eligible bool
	// VIPActive 表示当前账号仍有有效会员权益。
	VIPActive bool
	// AlreadyClaimed 表示当前账号已经在卡片领取名单中。
	AlreadyClaimed bool
	// Exhausted 表示卡片剩余数量为 0。
	Exhausted bool
	// Card 是 CheckCard 返回的卡片详情。
	Card *ExperienceCard
}

// ExperienceCardClaimResult 是一次成功领取的结果。
type ExperienceCardClaimResult struct {
	// CheckedCard 是领取前看到的卡片状态。
	CheckedCard *ExperienceCard
	// Card 是 GetCard 成功后返回的卡片状态。
	Card *ExperienceCard
	// ClaimedAt 是本地记录的成功领取时间。
	ClaimedAt time.Time
	// Request 是最终提交给官方的请求参数。
	Request ExperienceCardRequest
	// Raw 是 GetCard 的完整 req_1 原始响应。
	Raw json.RawMessage
}

// ParseExperienceCardLink 从 QQ 音乐官方体验卡链接中提取 cardid、ADTAG 和分享文案。
// 传入纯 cardid 也可以；完整链接缺少 cardid 时返回 ErrInvalidExperienceCard。
func ParseExperienceCardLink(raw string) (ExperienceCardRequest, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ExperienceCardRequest{}, fmt.Errorf("%w: empty link", ErrInvalidExperienceCard)
	}

	values := make(url.Values)
	if strings.ContainsAny(raw, "?#") || strings.Contains(raw, "://") {
		parsed, err := url.Parse(raw)
		if err != nil {
			return ExperienceCardRequest{}, fmt.Errorf("%w: parse link: %v", ErrInvalidExperienceCard, err)
		}
		if parsed.Scheme != "" && !strings.EqualFold(parsed.Scheme, "http") && !strings.EqualFold(parsed.Scheme, "https") {
			return ExperienceCardRequest{}, fmt.Errorf("%w: unsupported URL scheme %q", ErrInvalidExperienceCard, parsed.Scheme)
		}
		values = parsed.Query()
	}

	cardID := strings.TrimSpace(queryValueFold(values, "cardid"))
	if cardID == "" && !strings.ContainsAny(raw, "/?#&= \t\r\n") {
		cardID = raw
	}
	if cardID == "" {
		return ExperienceCardRequest{}, fmt.Errorf("%w: official link does not contain cardid", ErrInvalidExperienceCard)
	}
	if len(cardID) > 256 {
		return ExperienceCardRequest{}, fmt.Errorf("%w: cardid is too long", ErrInvalidExperienceCard)
	}

	source, err := parseExperienceCardSource(firstNonEmpty(
		queryValueFold(values, experienceCardSourceQueryADTAG),
		queryValueFold(values, experienceCardSourceQueryADTAGLC),
		queryValueFold(values, experienceCardSourceQuerySource),
	))
	if err != nil {
		return ExperienceCardRequest{}, err
	}

	from := experienceCardDefaultFrom
	if strings.EqualFold(queryValueFold(values, "from"), "song_share") {
		singer := strings.TrimSpace(queryValueFold(values, "singerName"))
		song := strings.TrimSpace(queryValueFold(values, "songName"))
		if singer != "" && song != "" {
			from = singer + "《" + song + "》邀请赠送"
		}
	}

	return ExperienceCardRequest{CardID: cardID, Source: source, From: from}, nil
}

func parseExperienceCardSource(raw string) (ExperienceCardSource, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ExperienceCardSourceDefault, nil
	}
	switch strings.ToLower(raw) {
	case "xqy":
		return ExperienceCardSourceXQY, nil
	case "cdy":
		return ExperienceCardSourceCDY, nil
	case "privilege":
		return ExperienceCardSourcePrivilege, nil
	}
	if value, err := strconv.Atoi(raw); err == nil {
		source := ExperienceCardSource(value)
		if source.Valid() {
			return source, nil
		}
	}
	return ExperienceCardSourceDefault, nil
}

func queryValueFold(values url.Values, key string) string {
	for candidate, items := range values {
		if !strings.EqualFold(candidate, key) || len(items) == 0 {
			continue
		}
		return items[0]
	}
	return ""
}

func (r ExperienceCardRequest) normalized() (ExperienceCardRequest, error) {
	r.CardID = strings.TrimSpace(r.CardID)
	r.From = strings.TrimSpace(r.From)
	if r.CardID == "" {
		return ExperienceCardRequest{}, fmt.Errorf("%w: card ID is empty", ErrInvalidExperienceCard)
	}
	if len(r.CardID) > 256 {
		return ExperienceCardRequest{}, fmt.Errorf("%w: card ID is too long", ErrInvalidExperienceCard)
	}
	if !r.Source.Valid() {
		return ExperienceCardRequest{}, fmt.Errorf("%w: unsupported source %d", ErrInvalidExperienceCard, r.Source)
	}
	if r.From == "" {
		r.From = experienceCardDefaultFrom
	}
	return r, nil
}

// CheckExperienceCard 调用 music.vip.VipFreeCardSvr/CheckCard 查询官方体验卡。
// 查询本身不会领取体验卡，但要求客户端已配置 UIN 和 qm_keyst。
func (c *Client) CheckExperienceCard(ctx context.Context, request ExperienceCardRequest) (*ExperienceCard, error) {
	request, err := request.normalized()
	if err != nil {
		return nil, err
	}
	if !c.IsLoggedIn() {
		return nil, ErrExperienceCardLoginRequired
	}
	result, err := c.CallQQ(ctx, experienceCardModule, experienceCardMethodCheckCard, map[string]any{
		"cardID": request.CardID,
	})
	if err != nil {
		return nil, err
	}
	if result.Code != 0 {
		return nil, experienceCardResultError(experienceCardMethodCheckCard, result, false)
	}
	card, err := parseExperienceCard(result.Data)
	if err != nil {
		return nil, err
	}
	return card, nil
}

// GetExperienceCardEligibility 在真正领取前检查会员状态、卡片余量和当前账号领取记录。
// 该方法只调用只读接口，不会领取体验卡。
func (c *Client) GetExperienceCardEligibility(ctx context.Context, request ExperienceCardRequest) (*ExperienceCardEligibility, error) {
	request, err := request.normalized()
	if err != nil {
		return nil, err
	}
	if !c.IsLoggedIn() {
		return nil, ErrExperienceCardLoginRequired
	}

	vipResult, err := c.GetVipStatus(ctx, "")
	if err != nil {
		return nil, err
	}
	if vipResult.Code != 0 {
		return nil, experienceCardResultError("SRFVipQuery_V2", vipResult, false)
	}
	vipActive, err := c.experienceCardVIPActive(vipResult.Data, time.Now().UTC())
	if err != nil {
		return nil, err
	}
	if vipActive {
		return &ExperienceCardEligibility{VIPActive: true}, nil
	}

	card, err := c.CheckExperienceCard(ctx, request)
	if err != nil {
		return nil, err
	}
	eligibility := &ExperienceCardEligibility{Card: card}
	switch {
	case card.HasRecipient(c.session.uin):
		eligibility.AlreadyClaimed = true
	case card.Left <= 0:
		eligibility.Exhausted = true
	default:
		eligibility.Eligible = true
	}
	return eligibility, nil
}

// ClaimExperienceCard 显式领取一张官方体验卡。
// 该方法只会使用当前 Client 已配置的单个账号，不会遍历或切换账号。
// 调用前会先执行只读资格检查；会员账号、已领取账号和已领完卡片不会发起 GetCard。
func (c *Client) ClaimExperienceCard(ctx context.Context, request ExperienceCardRequest) (*ExperienceCardClaimResult, error) {
	request, err := request.normalized()
	if err != nil {
		return nil, err
	}
	eligibility, err := c.GetExperienceCardEligibility(ctx, request)
	if err != nil {
		return nil, err
	}
	switch {
	case eligibility.VIPActive:
		return nil, ErrExperienceCardAlreadyMember
	case eligibility.AlreadyClaimed:
		return nil, ErrExperienceCardAlreadyClaimed
	case eligibility.Exhausted:
		return nil, ErrExperienceCardExhausted
	case !eligibility.Eligible || eligibility.Card == nil:
		return nil, ErrExperienceCardClaimFailed
	}

	result, err := c.CallQQ(ctx, experienceCardModule, experienceCardMethodClaimCard, map[string]any{
		"cardID": request.CardID,
		"source": int(request.Source),
		"extra": map[string]any{
			"from": request.From,
		},
	})
	if err != nil {
		return nil, err
	}
	if result.Code != 0 {
		return nil, experienceCardResultError(experienceCardMethodClaimCard, result, true)
	}
	card, err := parseExperienceCard(result.Data)
	if err != nil {
		return nil, err
	}
	return &ExperienceCardClaimResult{
		CheckedCard: eligibility.Card,
		Card:        card,
		ClaimedAt:   time.Now().UTC(),
		Request:     request,
		Raw:         cloneRawMessage(result.Raw),
	}, nil
}

// ClaimExperienceCardByLink 解析官方体验卡链接并执行一次显式领取。
// 这是 ClaimExperienceCard 的便捷入口，同样只操作当前 Client 的单个账号。
func (c *Client) ClaimExperienceCardByLink(ctx context.Context, link string) (*ExperienceCardClaimResult, error) {
	request, err := ParseExperienceCardLink(link)
	if err != nil {
		return nil, err
	}
	return c.ClaimExperienceCard(ctx, request)
}

type experienceCardInfo struct {
	GiftID     string                    `json:"giftID"`
	Status     int                       `json:"status"`
	Sum        int                       `json:"sum"`
	Left       int                       `json:"left"`
	CreateTime int64                     `json:"createTime"`
	OwnerUIN   string                    `json:"ownerUin"`
	OwnerInfo  experienceCardPersonRaw   `json:"ownerInfo"`
	Recipients []experienceCardPersonRaw `json:"reciveUinList"`
	Message    experienceCardMessageRaw  `json:"msg"`
}

type experienceCardPersonRaw struct {
	UIN      string          `json:"uin"`
	Nickname string          `json:"nic"`
	Avatar   string          `json:"pic"`
	UniqueID string          `json:"uniqueID"`
	UseTime  int64           `json:"useTime"`
	Extra    json.RawMessage `json:"extra"`
}

type experienceCardMessageRaw struct {
	Title   string `json:"title"`
	Content string `json:"content"`
	Picture string `json:"pic"`
}

func parseExperienceCard(data json.RawMessage) (*ExperienceCard, error) {
	var payload struct {
		CardInfo *experienceCardInfo `json:"cardInfo"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, fmt.Errorf("decode QQ Music experience card: %w", err)
	}
	if payload.CardInfo == nil {
		return nil, ErrExperienceCardNotFound
	}
	info := payload.CardInfo
	card := &ExperienceCard{
		CardID:     info.GiftID,
		Status:     info.Status,
		Sum:        info.Sum,
		Left:       info.Left,
		CreatedAt:  unixTime(info.CreateTime),
		OwnerUIN:   info.OwnerUIN,
		Owner:      info.OwnerInfo.public(),
		Recipients: make([]ExperienceCardPerson, 0, len(info.Recipients)),
		Message: ExperienceCardMessage{
			Title:   info.Message.Title,
			Content: info.Message.Content,
			Picture: info.Message.Picture,
		},
		Raw: cloneRawMessage(data),
	}
	for _, recipient := range info.Recipients {
		card.Recipients = append(card.Recipients, recipient.public())
	}
	return card, nil
}

func (p experienceCardPersonRaw) public() ExperienceCardPerson {
	return ExperienceCardPerson{
		UIN:      p.UIN,
		Nickname: p.Nickname,
		Avatar:   p.Avatar,
		UniqueID: p.UniqueID,
		UsedAt:   unixTime(p.UseTime),
		Extra:    cloneRawMessage(p.Extra),
	}
}

func unixTime(seconds int64) *time.Time {
	if seconds <= 0 {
		return nil
	}
	value := time.Unix(seconds, 0).UTC()
	return &value
}

func cloneRawMessage(value json.RawMessage) json.RawMessage {
	if len(value) == 0 {
		return nil
	}
	return append(json.RawMessage(nil), value...)
}

func experienceCardResultError(method string, result *CallResult, claim bool) error {
	classification := ErrExperienceCardAPI
	if claim {
		classification = ErrExperienceCardClaimFailed
	}
	switch result.Code {
	case 1000:
		classification = ErrExperienceCardLoginRequired
	case 100205:
		classification = ErrExperienceCardMonthlyLimit
	case 100206:
		classification = ErrExperienceCardAlreadyMember
	case 100210:
		classification = ErrExperienceCardAlreadyClaimed
	case 100211:
		classification = ErrExperienceCardClaimFailed
	}
	return &ExperienceCardAPIError{
		Method: method,
		Code:   result.Code,
		Err:    classification,
		Data:   cloneRawMessage(result.Data),
	}
}

type experienceCardVIPResponse struct {
	InfoMap map[string]experienceCardVIPInfo `json:"infoMap"`
}

type experienceCardVIPInfo struct {
	IVipFlag     json.Number `json:"iVipFlag"`
	INewVip      json.Number `json:"iNewVip"`
	ISuperVip    json.Number `json:"iSuperVip"`
	INewSuperVip json.Number `json:"iNewSuperVip"`
	HugeVip      json.Number `json:"HugeVip"`
	LMFlag       json.Number `json:"LMFlag"`
	SuperEndTime string      `json:"superEndTime"`
	OverDateTime string      `json:"sOverDateTime"`
	HugeVipEnd   string      `json:"HugeVipEnd"`
	LMEnd        string      `json:"LMEnd"`
	EightEndTime string      `json:"eightEndTime"`
}

func (c *Client) experienceCardVIPActive(data []byte, now time.Time) (bool, error) {
	var response experienceCardVIPResponse
	if err := json.Unmarshal(data, &response); err != nil {
		return false, fmt.Errorf("decode QQ Music VIP status: %w", err)
	}
	info, ok := response.InfoMap[c.session.uin]
	if !ok {
		if len(response.InfoMap) != 1 {
			return false, errors.New("QQ Music VIP status did not contain the current account")
		}
		for _, value := range response.InfoMap {
			info = value
		}
	}

	if experienceCardFlagEnabled(info.ISuperVip) || experienceCardFlagEnabled(info.INewSuperVip) {
		if experienceCardMembershipActive([]string{info.SuperEndTime, info.OverDateTime}, now) {
			return true, nil
		}
	}
	if experienceCardFlagEnabled(info.HugeVip) || experienceCardFlagEnabled(info.LMFlag) {
		if experienceCardMembershipActive([]string{info.HugeVipEnd, info.LMEnd}, now) {
			return true, nil
		}
	}
	if experienceCardFlagEnabled(info.IVipFlag) || experienceCardFlagEnabled(info.INewVip) {
		if experienceCardMembershipActive([]string{info.OverDateTime, info.EightEndTime}, now) {
			return true, nil
		}
	}
	return false, nil
}

func experienceCardFlagEnabled(value json.Number) bool {
	raw := strings.TrimSpace(value.String())
	if raw == "" {
		return false
	}
	parsed, err := strconv.ParseFloat(raw, 64)
	return err == nil && parsed > 0
}

func experienceCardMembershipActive(expiryValues []string, now time.Time) bool {
	var latest *time.Time
	for _, raw := range expiryValues {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		parsed, err := time.ParseInLocation(time.DateTime, raw, time.FixedZone("Asia/Shanghai", 8*60*60))
		if err != nil {
			continue
		}
		value := parsed.UTC()
		if latest == nil || value.After(*latest) {
			latest = &value
		}
	}
	return latest == nil || latest.After(now)
}
