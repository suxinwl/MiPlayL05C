package oomusic

import (
	"context"
	"errors"
	"strings"
)

func (c *Client) effectiveUIN(uin string) (string, error) {
	uin = firstNonEmpty(strings.TrimSpace(uin), c.session.uin)
	if uin == "" {
		return "", errors.New("QQ UIN is required")
	}
	return uin, nil
}

// GetVipStatus 调用 userInfo.VipQueryServer/SRFVipQuery_V2。
// uin 留空时使用客户端已配置的登录 UIN。
func (c *Client) GetVipStatus(ctx context.Context, uin string) (*CallResult, error) {
	uin, err := c.effectiveUIN(uin)
	if err != nil {
		return nil, err
	}
	return c.CallQQ(ctx, "userInfo.VipQueryServer", "SRFVipQuery_V2", map[string]any{
		"uin_list": []string{uin},
	})
}

// GetUserBaseInfo 调用 userInfo.BaseUserInfoServer/get_user_baseinfo_v2。
// uin 留空时使用客户端已配置的登录 UIN。
func (c *Client) GetUserBaseInfo(ctx context.Context, uin string) (*CallResult, error) {
	uin, err := c.effectiveUIN(uin)
	if err != nil {
		return nil, err
	}
	return c.CallQQ(ctx, "userInfo.BaseUserInfoServer", "get_user_baseinfo_v2", map[string]any{
		"vec_uin": []string{uin},
	})
}

// GetFavorList 调用 music.favor_system_read/get_favor_list。
// favType 为 1 时表示歌曲；userID 留空时使用客户端已配置的登录 UIN。
func (c *Client) GetFavorList(ctx context.Context, userID string, favType int) (*CallResult, error) {
	userID, err := c.effectiveUIN(userID)
	if err != nil {
		return nil, err
	}
	if favType == 0 {
		favType = 1
	}
	return c.CallQQ(ctx, "music.favor_system_read", "get_favor_list", map[string]any{
		"userid":   userID,
		"fav_type": favType,
	})
}

// GetChargeAccount 调用
// music.paycenterapi.LoginStateVerificationApi/GetChargeAccount，
// 查询当前登录账号的官方计费账户状态。
func (c *Client) GetChargeAccount(ctx context.Context) (*CallResult, error) {
	return c.CallQQ(ctx, "music.paycenterapi.LoginStateVerificationApi", "GetChargeAccount", map[string]any{
		"appid": "mlive",
	})
}
