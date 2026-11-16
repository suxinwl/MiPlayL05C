package crypto

import "encoding/hex"

// musics.fcg 在 encoding=ag-1 模式下对响应体使用固定 21 字节密钥循环异或，
// 请求体则使用 aes.go 中的 AES-GCM 封装，两者不是同一种格式。
const responseKeyHex = "7a3f8c1d5e9b2f0a6c4d7e8b1f3a5c9d0e2b6f4a81"

// DecodeResponse 解开 musics.fcg 原始响应体的循环异或掩码。
func DecodeResponse(wire []byte) ([]byte, error) {
	return transformResponse(wire)
}

// EncodeResponse 生成 musics.fcg 循环异或响应体，主要用于协议测试和回放。
func EncodeResponse(plaintext []byte) ([]byte, error) {
	return transformResponse(plaintext)
}

func transformResponse(input []byte) ([]byte, error) {
	key, err := hex.DecodeString(responseKeyHex)
	if err != nil {
		return nil, err
	}
	output := make([]byte, len(input))
	for index, value := range input {
		output[index] = value ^ key[index%len(key)]
	}
	return output, nil
}
