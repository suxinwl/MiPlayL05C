package account

import (
	"strings"
	"testing"
)

func TestParseUserProfile(t *testing.T) {
	data := []byte(`{
		"map_userinfo": {
			"209192670": {
				"uin": 209192670,
				"nick": " 测试昵称 ",
				"headurl": "http://thirdqq.qlogo.cn/avatar.jpg"
			}
		}
	}`)

	profile, err := ParseUserProfile(data, "209192670")
	if err != nil {
		t.Fatal(err)
	}
	if profile.UIN != "209192670" {
		t.Fatalf("unexpected UIN: %+v", profile)
	}
	if profile.Nickname != "测试昵称" {
		t.Fatalf("unexpected nickname: %+v", profile)
	}
	if profile.AvatarURL != "https://thirdqq.qlogo.cn/avatar.jpg" {
		t.Fatalf("HTTP avatar URL was not upgraded: %+v", profile)
	}
}

func TestParseUserProfileUsesOnlyReturnedRecord(t *testing.T) {
	data := []byte(`{
		"map_userinfo": {
			"10001": {"uin": 10001, "nick": "其他账号", "headurl": "https://example.com/other.png"}
		}
	}`)

	profile, err := ParseUserProfile(data, "209192670")
	if err != nil {
		t.Fatal(err)
	}
	if profile.UIN != "10001" || profile.Nickname != "其他账号" {
		t.Fatalf("unexpected fallback profile: %+v", profile)
	}
}

func TestParseUserProfileRejectsMissingOrAmbiguousData(t *testing.T) {
	tests := []struct {
		name string
		data string
		want string
	}{
		{name: "empty", data: ``, want: "空数据"},
		{name: "invalid JSON", data: `{`, want: "解析"},
		{name: "no records", data: `{"map_userinfo":{}}`, want: "没有 map_userinfo"},
		{name: "empty profile", data: `{"map_userinfo":{"209192670":{"uin":209192670}}}`, want: "没有返回昵称或头像"},
		{
			name: "ambiguous UIN",
			data: `{"map_userinfo":{"10001":{"nick":"一"},"10002":{"nick":"二"}}}`,
			want: "没有返回 UIN",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := ParseUserProfile([]byte(test.data), "209192670")
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("expected error containing %q, got %v", test.want, err)
			}
		})
	}
}
