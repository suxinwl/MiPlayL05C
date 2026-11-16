package account

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

var qqMusicLocation = time.FixedZone("Asia/Shanghai", 8*60*60)

// VipStatus 是从 QQ 音乐会员接口提取出的规范化账号权益。
type VipStatus struct {
	Level     int
	ExpiresAt *time.Time
}

type vipResponse struct {
	InfoMap map[string]vipInfo `json:"infoMap"`
}

type vipInfo struct {
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

// ParseVipStatus 解析 userInfo.VipQueryServer/SRFVipQuery_V2 的 data 字段。
// expectedUIN 用于在接口返回多个账号时选中正确记录。
func ParseVipStatus(data []byte, expectedUIN string, now time.Time) (VipStatus, error) {
	if len(data) == 0 {
		return VipStatus{}, errors.New("会员接口返回了空数据")
	}
	var response vipResponse
	if err := json.Unmarshal(data, &response); err != nil {
		return VipStatus{}, fmt.Errorf("解析会员接口响应: %w", err)
	}
	if len(response.InfoMap) == 0 {
		return VipStatus{}, errors.New("会员接口响应中没有 infoMap")
	}

	info, ok := response.InfoMap[strings.TrimSpace(expectedUIN)]
	if !ok {
		if len(response.InfoMap) != 1 {
			return VipStatus{}, fmt.Errorf("会员接口没有返回 UIN %s 的状态", maskUIN(expectedUIN))
		}
		for _, value := range response.InfoMap {
			info = value
		}
	}

	superActive, superExpiry := activeMembership(
		flagEnabled(info.ISuperVip) || flagEnabled(info.INewSuperVip),
		[]string{info.SuperEndTime, info.OverDateTime},
		now,
	)
	hugeActive, hugeExpiry := activeMembership(
		flagEnabled(info.HugeVip) || flagEnabled(info.LMFlag),
		[]string{info.HugeVipEnd, info.LMEnd},
		now,
	)
	vipActive, vipExpiry := activeMembership(
		flagEnabled(info.IVipFlag) || flagEnabled(info.INewVip),
		[]string{info.OverDateTime, info.EightEndTime},
		now,
	)

	switch {
	case superActive:
		return VipStatus{Level: VipLevelSuper, ExpiresAt: superExpiry}, nil
	case hugeActive:
		return VipStatus{Level: VipLevelHuge, ExpiresAt: hugeExpiry}, nil
	case vipActive:
		return VipStatus{Level: VipLevelVIP, ExpiresAt: vipExpiry}, nil
	default:
		return VipStatus{Level: VipLevelNone}, nil
	}
}

func flagEnabled(value json.Number) bool {
	raw := strings.TrimSpace(value.String())
	if raw == "" {
		return false
	}
	parsed, err := strconv.ParseFloat(raw, 64)
	return err == nil && parsed > 0
}

func activeMembership(enabled bool, expiryValues []string, now time.Time) (bool, *time.Time) {
	if !enabled {
		return false, nil
	}
	var latest *time.Time
	for _, raw := range expiryValues {
		parsed := parseQQMusicTime(raw)
		if parsed == nil {
			continue
		}
		if latest == nil || parsed.After(*latest) {
			latest = parsed
		}
	}
	if latest != nil && !latest.After(now) {
		return false, nil
	}
	return true, cloneTime(latest)
}

func parseQQMusicTime(raw string) *time.Time {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}
	parsed, err := time.ParseInLocation(time.DateTime, raw, qqMusicLocation)
	if err != nil {
		return nil
	}
	utc := parsed.UTC()
	return &utc
}
