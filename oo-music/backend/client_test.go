package oomusic

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	qqcrypto "github.com/rankgice/oo-music/internal/crypto"
)

func TestClientCallQQ(t *testing.T) {
	var requestBody []byte
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/cgi-bin/musics.fcg" {
			http.Error(w, "unexpected path", http.StatusNotFound)
			return
		}
		if r.URL.Query().Get("encoding") != "ag-1" || r.URL.Query().Get("sign") == "" {
			http.Error(w, "missing protocol query", http.StatusBadRequest)
			return
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		requestBody, err = qqcrypto.DecryptBase64(string(body))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		writeMaskedJSON(w, `{"code":0,"req_1":{"code":0,"data":{"answer":42}}}`)
	}))
	defer server.Close()

	client, err := NewClient(WithEndpoint(server.URL))
	if err != nil {
		t.Fatal(err)
	}
	result, err := client.CallQQ(context.Background(), "test.module", "Test.Method", map[string]any{"query": "x"})
	if err != nil {
		t.Fatal(err)
	}
	if result.Code != 0 || !strings.Contains(string(result.Data), `"answer":42`) {
		t.Fatalf("unexpected result: %+v data=%s", result, result.Data)
	}

	var envelope struct {
		Comm struct {
			CT   int    `json:"ct"`
			UIN  string `json:"uin"`
			GTK  int64  `json:"g_tk"`
			Sign int64  `json:"g_tk_new_20200303"`
		} `json:"comm"`
		Req1 CallRequest `json:"req_1"`
	}
	if err := json.Unmarshal(requestBody, &envelope); err != nil {
		t.Fatal(err)
	}
	if envelope.Comm.CT != 24 || envelope.Comm.UIN != "" || envelope.Comm.GTK != 5381 {
		t.Fatalf("unexpected comm: %+v", envelope.Comm)
	}
	if envelope.Req1.Module != "test.module" || envelope.Req1.Method != "Test.Method" {
		t.Fatalf("unexpected request: %+v", envelope.Req1)
	}
}

func TestClientCallBatch(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		plain, err := qqcrypto.DecryptBase64(string(body))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		var envelope map[string]json.RawMessage
		if err := json.Unmarshal(plain, &envelope); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if _, ok := envelope["req_1"]; !ok {
			http.Error(w, "missing req_1", http.StatusBadRequest)
			return
		}
		if _, ok := envelope["req_2"]; !ok {
			http.Error(w, "missing req_2", http.StatusBadRequest)
			return
		}
		writeMaskedJSON(w, `{"code":0,"req_1":{"code":0,"data":{"v":1}},"req_2":{"code":0,"data":{"v":2}}}`)
	}))
	defer server.Close()

	client, err := NewClient(WithEndpoint(server.URL))
	if err != nil {
		t.Fatal(err)
	}
	requests := map[string]CallRequest{
		"req_1": {Module: "m.one", Method: "One", Param: map[string]any{}},
		"req_2": {Module: "m.two", Method: "Two"},
	}
	result, err := client.CallBatch(context.Background(), requests)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Results) != 2 || result.Results["req_2"].Code != 0 {
		t.Fatalf("unexpected batch result: %+v", result)
	}
	if result.Results["req_2"].Module != "m.two" {
		t.Fatalf("request metadata missing: %+v", result.Results["req_2"])
	}
	if requests["req_2"].Param != nil {
		t.Fatal("CallBatch mutated the caller's request map")
	}
}

func TestDecodeResponseBodyDoesNotTrimWire(t *testing.T) {
	plain := []byte(`{"code":0,"req_1":{"code":0,"data":{}}}`)
	wire, err := qqcrypto.EncodeResponse(plain)
	if err != nil {
		t.Fatal(err)
	}
	padded := append([]byte(" \n"), wire...)
	padded = append(padded, '\r', '\t')
	if _, err := decodeResponseBody(padded); err == nil {
		t.Fatal("response decoder trimmed bytes before decoding the wire payload")
	}
}

func TestDecodeResponseBodyTrimsDecodedJSON(t *testing.T) {
	plain := []byte("\n\t{\"code\":0,\"req_1\":{\"code\":0,\"data\":{}}}\r\n")
	wire, err := qqcrypto.EncodeResponse(plain)
	if err != nil {
		t.Fatal(err)
	}
	got, err := decodeResponseBody(wire)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != `{"code":0,"req_1":{"code":0,"data":{}}}` {
		t.Fatalf("unexpected decoded response: %q", got)
	}
}

func TestGetLyricDecodesBase64(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		plain, err := qqcrypto.DecryptBase64(string(body))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		var envelope struct {
			Req1 struct {
				Module string `json:"module"`
				Method string `json:"method"`
			} `json:"req_1"`
		}
		if err := json.Unmarshal(plain, &envelope); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if envelope.Req1.Module != "music.musichallSong.PlayLyricInfo" || envelope.Req1.Method != "GetPlayLyricInfo" {
			http.Error(w, "unexpected method", http.StatusBadRequest)
			return
		}
		lyric := base64.StdEncoding.EncodeToString([]byte("[00:00.00]hello"))
		trans := base64.StdEncoding.EncodeToString([]byte("[00:00.00]你好"))
		writeMaskedJSON(w, `{"code":0,"req_1":{"code":0,"data":{"songName":"Song","singerName":"Artist","lyric":"`+lyric+`","trans":"`+trans+`","roma":""}}}`)
	}))
	defer server.Close()

	client, err := NewClient(WithEndpoint(server.URL))
	if err != nil {
		t.Fatal(err)
	}
	result, err := client.GetLyric(context.Background(), LyricOptions{SongMID: "000lXvdX0uOg8F", SongID: 102321278})
	if err != nil {
		t.Fatal(err)
	}
	if result.Lyric != "[00:00.00]hello" || result.Trans != "[00:00.00]你好" {
		t.Fatalf("unexpected decoded lyric: %+v", result)
	}
	if result.Raw.Lyric == "" {
		t.Fatal("raw lyric fields were not retained")
	}
}

func TestResolvePlayableBySongLoadsQualityInfoWithCompleteMetadata(t *testing.T) {
	requestCount := 0
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/song.flac" {
			if r.Header.Get("Range") != "bytes=0-0" {
				t.Errorf("unexpected media range: %q", r.Header.Get("Range"))
			}
			w.WriteHeader(http.StatusPartialContent)
			_, _ = w.Write([]byte{0})
			return
		}
		requestCount++
		body, _ := io.ReadAll(r.Body)
		plain, err := qqcrypto.DecryptBase64(string(body))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		var envelope struct {
			Req1 struct {
				Module string `json:"module"`
				Method string `json:"method"`
			} `json:"req_1"`
		}
		if err := json.Unmarshal(plain, &envelope); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		switch envelope.Req1.Module {
		case "music.trackInfo.UniformRuleCtrl":
			writeMaskedJSON(w, `{"code":0,"req_1":{"code":0,"data":{"tracks":[{"mid":"0039MnYb0qxYhV","vs":["064YyRNb0gDV4P"],"file":{"size_flac":123456}}]}}}`)
		case "music.vkey.GetEVkey":
			writeMaskedJSON(w, fmt.Sprintf(`{"code":0,"req_1":{"code":0,"data":{"sip":[%q],"midurlinfo":[{"purl":"/song.flac"}]}}}`, server.URL))
		default:
			http.Error(w, "unexpected module "+envelope.Req1.Module, http.StatusBadRequest)
		}
	}))
	defer server.Close()

	client, err := NewClient(WithEndpoint(server.URL))
	if err != nil {
		t.Fatal(err)
	}
	result, err := client.ResolvePlayableBySong(context.Background(), ResolvePlayableBySongOptions{
		SongID:          97773,
		SongMID:         "0039MnYb0qxYhV",
		VSFirst:         "064YyRNb0gDV4P",
		PreferQualities: []Quality{QualityFLAC},
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Quality != QualityFLAC || result.URL != server.URL+"/song.flac" {
		t.Fatalf("unexpected playback result: %+v", result)
	}
	if requestCount != 2 {
		t.Fatalf("expected track and playback requests, got %d", requestCount)
	}
}

func TestResolvePlayableBySongFallsBackToMediaIdentifier(t *testing.T) {
	const songMID = "000cWQlW4F7fzD"
	tests := []struct {
		name     string
		trackVS  string
		mediaMid string
		want     string
	}{
		{name: "song vs", trackVS: "061iDovh36igWS", mediaMid: songMID, want: "M800061iDovh36igWS.mp3"},
		{name: "media mid", mediaMid: songMID, want: "M800" + songMID + ".mp3"},
		{name: "song mid", want: "M800" + songMID + ".mp3"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var requestedFilename string
			var server *httptest.Server
			server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/song.mp3" {
					w.WriteHeader(http.StatusPartialContent)
					_, _ = w.Write([]byte{0})
					return
				}
				body, _ := io.ReadAll(r.Body)
				plain, err := qqcrypto.DecryptBase64(string(body))
				if err != nil {
					http.Error(w, err.Error(), http.StatusBadRequest)
					return
				}
				var envelope struct {
					Req1 struct {
						Module string `json:"module"`
						Param  struct {
							Filename []string `json:"filename"`
						} `json:"param"`
					} `json:"req_1"`
				}
				if err := json.Unmarshal(plain, &envelope); err != nil {
					http.Error(w, err.Error(), http.StatusBadRequest)
					return
				}
				switch envelope.Req1.Module {
				case "music.trackInfo.UniformRuleCtrl":
					writeMaskedJSON(w, fmt.Sprintf(`{"code":0,"req_1":{"code":0,"data":{"tracks":[{"mid":%q,"vs":[%q],"file":{"media_mid":%q,"size_320mp3":8168167}}]}}}`, songMID, test.trackVS, test.mediaMid))
				case "music.vkey.GetEVkey":
					if len(envelope.Req1.Param.Filename) > 0 {
						requestedFilename = envelope.Req1.Param.Filename[0]
					}
					writeMaskedJSON(w, fmt.Sprintf(`{"code":0,"req_1":{"code":0,"data":{"sip":[%q],"midurlinfo":[{"purl":"/song.mp3"}]}}}`, server.URL))
				default:
					http.Error(w, "unexpected module "+envelope.Req1.Module, http.StatusBadRequest)
				}
			}))
			defer server.Close()

			client, err := NewClient(WithEndpoint(server.URL))
			if err != nil {
				t.Fatal(err)
			}
			result, err := client.ResolvePlayableBySong(context.Background(), ResolvePlayableBySongOptions{
				SongID:          279300928,
				PreferQualities: []Quality{QualityMP3320},
			})
			if err != nil {
				t.Fatal(err)
			}
			if result.Quality != QualityMP3320 || result.URL != server.URL+"/song.mp3" {
				t.Fatalf("unexpected playback result: %+v", result)
			}
			if requestedFilename != test.want || result.Filename != test.want {
				t.Fatalf("unexpected filename: requested=%q result=%q want=%q", requestedFilename, result.Filename, test.want)
			}
		})
	}
}

func TestResolvePlayableBySongRejectsCDNNotFound(t *testing.T) {
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/missing.mp3" {
			http.Error(w, `{"errorcode":-46628,"errormsg":"file not exist"}`, http.StatusNotFound)
			return
		}
		body, _ := io.ReadAll(r.Body)
		plain, err := qqcrypto.DecryptBase64(string(body))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		var envelope struct {
			Req1 struct {
				Module string `json:"module"`
			} `json:"req_1"`
		}
		if err := json.Unmarshal(plain, &envelope); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		switch envelope.Req1.Module {
		case "music.trackInfo.UniformRuleCtrl":
			writeMaskedJSON(w, `{"code":0,"req_1":{"code":0,"data":{"tracks":[{"mid":"0045t6kl1RS40K","vs":["0045t6kl1RS40K"],"file":{"size_128mp3":3217245}}]}}}`)
		case "music.vkey.GetEVkey":
			writeMaskedJSON(w, fmt.Sprintf(`{"code":0,"req_1":{"code":0,"data":{"sip":[%q],"midurlinfo":[{"purl":"/missing.mp3"}]}}}`, server.URL))
		default:
			http.Error(w, "unexpected module "+envelope.Req1.Module, http.StatusBadRequest)
		}
	}))
	defer server.Close()

	client, err := NewClient(WithEndpoint(server.URL))
	if err != nil {
		t.Fatal(err)
	}
	result, err := client.ResolvePlayableBySong(context.Background(), ResolvePlayableBySongOptions{
		SongID:          469571981,
		PreferQualities: []Quality{QualityMP3128},
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.URL != "" || result.Quality != "" {
		t.Fatalf("expected unavailable playback result, got %+v", result)
	}
	if result.Reason != "NO_VALID_AUDIO_SOURCE" {
		t.Fatalf("unexpected reason: %s", result.Reason)
	}
	if len(result.Tried) != 1 || result.Tried[0].Reason != "cdn-http-404" {
		t.Fatalf("unexpected attempts: %+v", result.Tried)
	}
}

func TestBuildFilename(t *testing.T) {
	got, err := BuildFilename("063RB2qa2HHyA1", QualityMaster)
	if err != nil {
		t.Fatal(err)
	}
	if got != "RS02063RB2qa2HHyA1.mp3" {
		t.Fatalf("unexpected filename %q", got)
	}
	if _, err := BuildFilename("", QualityFLAC); err != ErrMissingFilename {
		t.Fatalf("unexpected missing filename error: %v", err)
	}
}

func TestSessionAnonymousComm(t *testing.T) {
	got := (session{}).common()
	if got.GTK != 5381 || got.GTKNew20200303 != 5381 || got.UIN != "" {
		t.Fatalf("unexpected anonymous comm: %+v", got)
	}
	if (session{}).cookieHeader() != "login_type=1; tmeLoginType=2" {
		t.Fatal("unexpected anonymous cookie")
	}
}

func writeMaskedJSON(w http.ResponseWriter, jsonText string) {
	wire, err := qqcrypto.EncodeResponse([]byte(jsonText))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	_, _ = w.Write(wire)
}
