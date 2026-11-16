package oomusic

// VipEntry 描述 QQ 音乐官方 VIP 购买入口。
type VipEntry struct {
	// Type 标识入口类型，目前为 "official-h5"。
	Type string
	// Provider 标识支付提供方，目前为 "midas"。
	Provider string
	// URL 是 QQ 音乐官方 VIP 门户地址。
	URL string
	// Note 说明 SDK 的支付功能边界。
	Note string
}

// GetOfficialVipEntry 返回 QQ 音乐官方 VIP 门户。
// 支付在腾讯官方米大师收银台完成，SDK 不创建订单，也不确认支付结果。
func (c *Client) GetOfficialVipEntry() VipEntry {
	return VipEntry{
		Type:     "official-h5",
		Provider: "midas",
		URL:      "https://y.qq.com/portal/vipportal/index.html",
		Note:     "充值/付费走腾讯米大师官方收银台；SDK 不逆向下单参数，也不自动确认支付。",
	}
}
