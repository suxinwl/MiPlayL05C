package account

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// UserProfile 是从 QQ 音乐用户资料接口提取出的客户端展示信息。
type UserProfile struct {
	UIN       string
	Nickname  string
	AvatarURL string
}

type userBaseInfoResponse struct {
	MapUserInfo map[string]userBaseInfo `json:"map_userinfo"`
}

type userBaseInfo struct {
	UIN      json.Number `json:"uin"`
	Nickname string      `json:"nick"`
	HeadURL  string      `json:"headurl"`
}

// ParseUserProfile 解析 userInfo.BaseUserInfoServer/get_user_baseinfo_v2
// 的 data 字段。expectedUIN 用于在接口返回多个账号时选择正确记录。
func ParseUserProfile(data []byte, expectedUIN string) (UserProfile, error) {
	if len(data) == 0 {
		return UserProfile{}, errors.New("用户资料接口返回了空数据")
	}
	var response userBaseInfoResponse
	if err := json.Unmarshal(data, &response); err != nil {
		return UserProfile{}, fmt.Errorf("解析用户资料接口响应: %w", err)
	}
	if len(response.MapUserInfo) == 0 {
		return UserProfile{}, errors.New("用户资料接口响应中没有 map_userinfo")
	}

	expectedUIN = strings.TrimSpace(expectedUIN)
	info, ok := response.MapUserInfo[expectedUIN]
	if !ok {
		if len(response.MapUserInfo) != 1 {
			return UserProfile{}, fmt.Errorf("用户资料接口没有返回 UIN %s 的资料", maskUIN(expectedUIN))
		}
		for _, value := range response.MapUserInfo {
			info = value
		}
	}

	nickname := strings.TrimSpace(info.Nickname)
	avatarURL := strings.TrimSpace(info.HeadURL)
	if strings.HasPrefix(avatarURL, "http://") {
		avatarURL = "https://" + strings.TrimPrefix(avatarURL, "http://")
	}
	if nickname == "" && avatarURL == "" {
		return UserProfile{}, errors.New("用户资料接口没有返回昵称或头像")
	}
	uin := strings.TrimSpace(info.UIN.String())
	if uin == "" {
		uin = expectedUIN
	}
	return UserProfile{UIN: uin, Nickname: nickname, AvatarURL: avatarURL}, nil
}
