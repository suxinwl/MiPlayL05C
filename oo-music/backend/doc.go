// Package oomusic 提供直连腾讯 QQ 音乐网页接口的 Go 工具包。
//
// 客户端通过 NewClient 创建，可匿名调用公开接口，也可使用用户自己的
// UIN 与 qm_keyst 访问登录态接口。所有请求都由 SDK 完成签名、AES-GCM
// 加密和响应解包，不依赖第三方 QQ 音乐 API 服务。
package oomusic
