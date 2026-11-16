package oomusic

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	qqcrypto "github.com/rankgice/oo-music/internal/crypto"
)

func TestParseExperienceCardLink(t *testing.T) {
	tests := []struct {
		name       string
		link       string
		wantCardID string
		wantSource ExperienceCardSource
		wantFrom   string
	}{
		{
			name:       "activity link",
			link:       "https://y.qq.com/m/basic/client/experience_card/index.html?ADTAG=yy_gnyy_hytyk&from=share&cardid=dbg2tgu3deas07kd8i40",
			wantCardID: "dbg2tgu3deas07kd8i40",
			wantSource: ExperienceCardSourceDefault,
			wantFrom:   experienceCardDefaultFrom,
		},
		{
			name:       "known ADTAG",
			link:       "https://y.qq.com/example?adtag=xqy&cardid=card-1",
			wantCardID: "card-1",
			wantSource: ExperienceCardSourceXQY,
			wantFrom:   experienceCardDefaultFrom,
		},
		{
			name:       "song share",
			link:       "https://y.qq.com/example?source=2&from=song_share&singerName=%E5%91%A8%E6%9D%B0%E4%BC%A6&songName=%E6%99%B4%E5%A4%A9&cardid=card-2",
			wantCardID: "card-2",
			wantSource: ExperienceCardSourceCDY,
			wantFrom:   "周杰伦《晴天》邀请赠送",
		},
		{
			name:       "bare card id",
			link:       "dbg2tgu3deas07kd8i40",
			wantCardID: "dbg2tgu3deas07kd8i40",
			wantSource: ExperienceCardSourceDefault,
			wantFrom:   experienceCardDefaultFrom,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ParseExperienceCardLink(test.link)
			if err != nil {
				t.Fatal(err)
			}
			if got.CardID != test.wantCardID || got.Source != test.wantSource || got.From != test.wantFrom {
				t.Fatalf("unexpected request: %+v", got)
			}
		})
	}

	if _, err := ParseExperienceCardLink("https://y.qq.com/example?from=share"); !errors.Is(err, ErrInvalidExperienceCard) {
		t.Fatalf("expected invalid card error, got %v", err)
	}
}

func TestCheckExperienceCardParsesOfficialResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		call := decryptExperienceCardTestCall(t, r)
		if call.Module != experienceCardModule || call.Method != experienceCardMethodCheckCard {
			t.Fatalf("unexpected call: %+v", call)
		}
		if got := call.Param["cardID"]; got != "card-1" {
			t.Fatalf("unexpected card ID: %v", got)
		}
		writeMaskedJSON(w, `{"code":0,"req_1":{"code":0,"data":{"cardInfo":{
			"giftID":"card-1","status":0,"sum":5,"left":1,"createTime":1700000000,"ownerUin":"20002",
			"ownerInfo":{"uin":"20002","nic":"Owner","pic":"https://example.com/owner.png","uniqueID":"owner-id","useTime":1700000001,"extra":{"from":"friend"}},
			"reciveUinList":[{"uin":"30003","nic":"Receiver","pic":"https://example.com/receiver.png","uniqueID":"receiver-id","useTime":1700000002,"extra":{"from":"friend"}}],
			"msg":{"title":"1份3天豪华绿钻会员","content":"领取体验卡","pic":"https://example.com/card.png"}
		}}}}`)
	}))
	defer server.Close()

	client := newExperienceCardTestClient(t, server.URL)
	card, err := client.CheckExperienceCard(context.Background(), ExperienceCardRequest{CardID: "card-1"})
	if err != nil {
		t.Fatal(err)
	}
	if card.CardID != "card-1" || card.Sum != 5 || card.Left != 1 || card.Owner.Nickname != "Owner" {
		t.Fatalf("unexpected card: %+v", card)
	}
	if len(card.Recipients) != 1 || card.Recipients[0].UIN != "30003" || card.HasRecipient("30003") == false {
		t.Fatalf("unexpected recipients: %+v", card.Recipients)
	}
	if card.Message.Title == "" || card.Raw == nil {
		t.Fatalf("missing message or raw data: %+v", card)
	}
}

func TestClaimExperienceCardSuccess(t *testing.T) {
	var calls []experienceCardTestCall
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		call := decryptExperienceCardTestCall(t, r)
		calls = append(calls, call)
		switch call.Method {
		case "SRFVipQuery_V2":
			writeMaskedJSON(w, inactiveVIPResponse("10001"))
		case experienceCardMethodCheckCard:
			writeMaskedJSON(w, checkableCardResponse("10001"))
		case experienceCardMethodClaimCard:
			if source, ok := call.Param["source"].(float64); !ok || source != 0 {
				t.Fatalf("unexpected source: %#v", call.Param["source"])
			}
			extra, ok := call.Param["extra"].(map[string]any)
			if !ok || extra["from"] != experienceCardDefaultFrom {
				t.Fatalf("unexpected extra: %#v", call.Param["extra"])
			}
			writeMaskedJSON(w, claimedCardResponse("10001"))
		default:
			t.Fatalf("unexpected method: %s", call.Method)
		}
	}))
	defer server.Close()

	client := newExperienceCardTestClient(t, server.URL)
	result, err := client.ClaimExperienceCardByLink(context.Background(), "https://y.qq.com/example?ADTAG=yy_gnyy_hytyk&cardid=card-1")
	if err != nil {
		t.Fatal(err)
	}
	if result.Card == nil || result.Card.CardID != "card-1" || !result.Card.HasRecipient("10001") {
		t.Fatalf("unexpected claim result: %+v", result)
	}
	if result.CheckedCard == nil || result.ClaimedAt.IsZero() || result.Raw == nil {
		t.Fatalf("missing claim metadata: %+v", result)
	}
	gotMethods := make([]string, 0, len(calls))
	for _, call := range calls {
		gotMethods = append(gotMethods, call.Method)
	}
	wantMethods := []string{"SRFVipQuery_V2", experienceCardMethodCheckCard, experienceCardMethodClaimCard}
	if !reflect.DeepEqual(gotMethods, wantMethods) {
		t.Fatalf("unexpected call sequence: %v", gotMethods)
	}
}

func TestClaimExperienceCardStopsForActiveMember(t *testing.T) {
	callCount := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		call := decryptExperienceCardTestCall(t, r)
		if call.Method != "SRFVipQuery_V2" {
			t.Fatalf("claim should stop before method %s", call.Method)
		}
		writeMaskedJSON(w, activeVIPResponse("10001"))
	}))
	defer server.Close()

	client := newExperienceCardTestClient(t, server.URL)
	_, err := client.ClaimExperienceCard(context.Background(), ExperienceCardRequest{CardID: "card-1"})
	if !errors.Is(err, ErrExperienceCardAlreadyMember) {
		t.Fatalf("expected active member error, got %v", err)
	}
	if callCount != 1 {
		t.Fatalf("expected one preflight call, got %d", callCount)
	}
}

func TestClaimExperienceCardStopsForAlreadyClaimedAccount(t *testing.T) {
	callCount := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		callCount++
		call := decryptExperienceCardTestCall(t, r)
		switch call.Method {
		case "SRFVipQuery_V2":
			writeMaskedJSON(w, inactiveVIPResponse("10001"))
		case experienceCardMethodCheckCard:
			writeMaskedJSON(w, alreadyClaimedCardResponse("10001"))
		default:
			t.Fatalf("claim should stop before method %s", call.Method)
		}
	}))
	defer server.Close()

	client := newExperienceCardTestClient(t, server.URL)
	_, err := client.ClaimExperienceCard(context.Background(), ExperienceCardRequest{CardID: "card-1"})
	if !errors.Is(err, ErrExperienceCardAlreadyClaimed) {
		t.Fatalf("expected already claimed error, got %v", err)
	}
	if callCount != 2 {
		t.Fatalf("expected two preflight calls, got %d", callCount)
	}
}

func TestClaimExperienceCardMapsMonthlyLimit(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		call := decryptExperienceCardTestCall(t, r)
		switch call.Method {
		case "SRFVipQuery_V2":
			writeMaskedJSON(w, inactiveVIPResponse("10001"))
		case experienceCardMethodCheckCard:
			writeMaskedJSON(w, checkableCardResponse("10001"))
		case experienceCardMethodClaimCard:
			writeMaskedJSON(w, `{"code":0,"req_1":{"code":100205,"data":{"msg":"monthly limit"}}}`)
		default:
			t.Fatalf("unexpected method: %s", call.Method)
		}
	}))
	defer server.Close()

	client := newExperienceCardTestClient(t, server.URL)
	_, err := client.ClaimExperienceCard(context.Background(), ExperienceCardRequest{CardID: "card-1"})
	if !errors.Is(err, ErrExperienceCardMonthlyLimit) {
		t.Fatalf("expected monthly limit error, got %v", err)
	}
	var apiErr *ExperienceCardAPIError
	if !errors.As(err, &apiErr) || apiErr.Code != 100205 || apiErr.Method != experienceCardMethodClaimCard {
		t.Fatalf("unexpected API error: %#v", err)
	}
}

func TestClaimExperienceCardRequiresLogin(t *testing.T) {
	client, err := NewClient()
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.ClaimExperienceCard(context.Background(), ExperienceCardRequest{CardID: "card-1"})
	if !errors.Is(err, ErrExperienceCardLoginRequired) {
		t.Fatalf("expected login error, got %v", err)
	}
}

type experienceCardTestCall struct {
	Module string         `json:"module"`
	Method string         `json:"method"`
	Param  map[string]any `json:"param"`
}

func decryptExperienceCardTestCall(t *testing.T, r *http.Request) experienceCardTestCall {
	t.Helper()
	body, err := io.ReadAll(r.Body)
	if err != nil {
		t.Fatal(err)
	}
	plain, err := qqcrypto.DecryptBase64(string(body))
	if err != nil {
		t.Fatal(err)
	}
	var envelope struct {
		Req1 experienceCardTestCall `json:"req_1"`
	}
	if err := json.Unmarshal(plain, &envelope); err != nil {
		t.Fatal(err)
	}
	return envelope.Req1
}

func newExperienceCardTestClient(t *testing.T, endpoint string) *Client {
	t.Helper()
	client, err := NewClient(
		WithCredentials("10001", "test-key"),
		WithEndpoint(endpoint),
	)
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func inactiveVIPResponse(uin string) string {
	return `{"code":0,"req_1":{"code":0,"data":{"infoMap":{"` + uin + `":{"iVipFlag":0,"iNewVip":0,"iSuperVip":0,"iNewSuperVip":0,"HugeVip":0,"LMFlag":0}}}}}`
}

func activeVIPResponse(uin string) string {
	return `{"code":0,"req_1":{"code":0,"data":{"infoMap":{"` + uin + `":{"iVipFlag":1,"iNewVip":0,"iSuperVip":0,"iNewSuperVip":0,"HugeVip":0,"LMFlag":0,"sOverDateTime":"2099-12-31 23:59:59"}}}}}`
}

func checkableCardResponse(uin string) string {
	return `{"code":0,"req_1":{"code":0,"data":{"cardInfo":{"giftID":"card-1","status":0,"sum":5,"left":1,"createTime":1700000000,"ownerUin":"20002","ownerInfo":{"uin":"20002","nic":"Owner"},"reciveUinList":[{"uin":"30003","nic":"Other"}],"msg":{"title":"1份3天豪华绿钻会员","content":"领取体验卡"}}}}}`
}

func alreadyClaimedCardResponse(uin string) string {
	return `{"code":0,"req_1":{"code":0,"data":{"cardInfo":{"giftID":"card-1","status":0,"sum":5,"left":1,"createTime":1700000000,"ownerUin":"20002","ownerInfo":{"uin":"20002","nic":"Owner"},"reciveUinList":[{"uin":"` + uin + `","nic":"Current"}],"msg":{"title":"1份3天豪华绿钻会员"}}}}}`
}

func claimedCardResponse(uin string) string {
	return `{"code":0,"req_1":{"code":0,"data":{"cardInfo":{"giftID":"card-1","status":0,"sum":5,"left":0,"createTime":1700000000,"ownerUin":"20002","ownerInfo":{"uin":"20002","nic":"Owner"},"reciveUinList":[{"uin":"30003","nic":"Other"},{"uin":"` + uin + `","nic":"Current"}],"msg":{"title":"1份3天豪华绿钻会员"}}}}}`
}
