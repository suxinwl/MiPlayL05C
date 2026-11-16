package oomusic

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestParseUserPlaylistsSupportsCurrentRPCFields(t *testing.T) {
	data := json.RawMessage(`{
		"v_playlist": [
			{
				"tid": "101",
				"dirId": 201,
				"dirName": "我喜欢的音乐",
				"picUrl": "https://example.com/cover-a.jpg",
				"songNum": 2
			},
			{
				"dirid": 202,
				"diss_name": "旧字段歌单",
				"diss_cover": "https://example.com/cover-b.jpg",
				"song_count": "3"
			},
			{"tid": 0, "dirId": 0, "dirName": "无 ID 应跳过"},
			{"tid": "101", "dirName": "重复歌单应跳过"}
		]
	}`)

	playlists, err := parseUserPlaylists(data)
	if err != nil {
		t.Fatal(err)
	}
	if len(playlists) != 2 {
		t.Fatalf("unexpected playlist count: %d", len(playlists))
	}
	first := playlists[0]
	if first.ID != "101" || first.DirID != "201" || first.Name != "我喜欢的音乐" || first.CoverURL != "https://example.com/cover-a.jpg" || first.SongCount != 2 {
		t.Fatalf("unexpected first playlist: %+v", first)
	}
	second := playlists[1]
	if second.ID != "202" || second.DirID != "202" || second.Name != "旧字段歌单" || second.CoverURL != "https://example.com/cover-b.jpg" || second.SongCount != 3 {
		t.Fatalf("unexpected compatibility playlist: %+v", second)
	}
}

func TestGetPlaylistDetailUsesMusicUCgiWithNumericIDs(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/cgi-bin/musicu.fcg" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		if r.Method != http.MethodPost {
			t.Errorf("unexpected method: %s", r.Method)
		}
		var envelope struct {
			Request struct {
				Module string `json:"module"`
				Method string `json:"method"`
				Param  struct {
					DisstID      json.Number `json:"disstid"`
					DirID        json.Number `json:"dirid"`
					SongBegin    json.Number `json:"song_begin"`
					SongNum      json.Number `json:"song_num"`
					OnlySongList json.Number `json:"onlysonglist"`
				} `json:"param"`
			} `json:"req_0"`
		}
		if err := json.NewDecoder(r.Body).Decode(&envelope); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		if envelope.Request.Module != "music.srfDissInfo.DissInfo" || envelope.Request.Method != "CgiGetDiss" {
			t.Errorf("unexpected request: %+v", envelope.Request)
		}
		if envelope.Request.Param.DisstID.String() != "101" || envelope.Request.Param.DirID.String() != "201" ||
			envelope.Request.Param.SongBegin.String() != "20" || envelope.Request.Param.SongNum.String() != "10" ||
			envelope.Request.Param.OnlySongList.String() != "0" {
			t.Errorf("unexpected params: %+v", envelope.Request.Param)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"code":0,"req_0":{"code":0,"data":{"songlist":[{"id":11},{"songid":"22"}],"total_song_num":2}}}`))
	}))
	defer server.Close()

	client, err := NewClient(WithEndpoint(server.URL))
	if err != nil {
		t.Fatal(err)
	}
	result, err := client.GetPlaylistDetail(context.Background(), PlaylistOptions{
		DisstID: "101",
		DirID:   "201",
		Offset:  20,
		Limit:   10,
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Code != 0 || !json.Valid(result.Data) {
		t.Fatalf("unexpected result: code=%d data=%s", result.Code, result.Data)
	}
}

func TestParsePlaylistSongIDsSupportsCurrentRPCFields(t *testing.T) {
	ids, total, err := parsePlaylistSongIDs(json.RawMessage(`{
		"songlist": [
			{"id": 11},
			{"songid": "22"},
			{"id": 0}
		],
		"total_song_num": 2
	}`))
	if err != nil {
		t.Fatal(err)
	}
	if total != 2 || len(ids) != 2 || ids[0] != 11 || ids[1] != 22 {
		t.Fatalf("unexpected song IDs: ids=%v total=%d", ids, total)
	}
}
