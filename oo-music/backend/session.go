package oomusic

// session contains the QQ Music web credentials used to build the common
// request fields and Cookie header. Values are intentionally unexported.
type session struct {
	uin     string
	qmKeyst string
}

// isLoggedIn reports whether the session contains both required credentials.
func (s session) isLoggedIn() bool {
	return s.uin != "" && s.qmKeyst != ""
}

// gtkForMusicAPI implements QQ Music's hash33 using qm_keyst. Anonymous mode
// returns the documented seed value 5381.
func (s session) gtkForMusicAPI() int64 {
	var value int64 = 5381
	for _, ch := range s.qmKeyst {
		value += (value << 5) + int64(ch)
	}
	return value & 0x7fffffff
}

// cookieHeader returns the browser-compatible Cookie value used by y.qq.com.
func (s session) cookieHeader() string {
	if s.uin == "" && s.qmKeyst == "" {
		return "login_type=1; tmeLoginType=2"
	}
	return "uin=" + s.uin + "; qm_keyst=" + s.qmKeyst +
		"; qqmusic_key=" + s.qmKeyst + "; login_type=1; tmeLoginType=2"
}

// comm is the common metadata object embedded in every musics.fcg request.
type comm struct {
	CV             int64  `json:"cv"`
	CT             int    `json:"ct"`
	Format         string `json:"format"`
	InCharset      string `json:"inCharset"`
	OutCharset     string `json:"outCharset"`
	Notice         int    `json:"notice"`
	Platform       string `json:"platform"`
	NeedNewCode    int    `json:"needNewCode"`
	UIN            string `json:"uin"`
	GTKNew20200303 int64  `json:"g_tk_new_20200303"`
	GTK            int64  `json:"g_tk"`
}

// common returns a newly built comm object for the current session.
func (s session) common() comm {
	gtk := s.gtkForMusicAPI()
	return comm{
		CV:             4747474,
		CT:             24,
		Format:         "json",
		InCharset:      "utf-8",
		OutCharset:     "utf-8",
		Notice:         0,
		Platform:       "yqq.json",
		NeedNewCode:    1,
		UIN:            s.uin,
		GTKNew20200303: gtk,
		GTK:            gtk,
	}
}
