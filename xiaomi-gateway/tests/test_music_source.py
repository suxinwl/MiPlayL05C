import asyncio

import pytest
from fastapi.testclient import TestClient

from app import main
from app.config import Settings
from app.services import oo_music


class FakeResponse:
    status_code = 200

    def __init__(self, payload: dict):
        self._payload = payload

    def raise_for_status(self) -> None:
        return None

    def json(self) -> dict:
        return self._payload


class FakeAsyncClient:
    def __init__(self, responses: list[dict], calls: list[dict]):
        self.responses = responses
        self.calls = calls

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return None

    async def get(self, url: str, **kwargs):
        self.calls.append({"url": url, **kwargs})
        return FakeResponse(self.responses.pop(0))


def test_client_forces_netease_source_and_headers(monkeypatch) -> None:
    calls: list[dict] = []
    responses = [{"source": "netease", "query": "晴天", "items": []}]
    monkeypatch.setattr(
        oo_music.httpx,
        "AsyncClient",
        lambda **_kwargs: FakeAsyncClient(responses, calls),
    )

    client = oo_music.OoMusicClient(
        "http://oo-music:8787",
        source="netease",
        account_id="account-1",
        access_key="access-1",
    )
    result = asyncio.run(client.search("晴天"))

    assert result["source"] == "netease"
    assert calls[0]["params"]["source"] == "netease"
    assert calls[0]["headers"] == {
        "X-OO-Music-Source": "netease",
        "X-OO-Music-Account-ID": "account-1",
        "X-OO-Music-Access-Key": "access-1",
    }


def test_client_rejects_response_source_mismatch(monkeypatch) -> None:
    calls: list[dict] = []
    responses = [{"source": "qq", "query": "晴天", "items": []}]
    monkeypatch.setattr(
        oo_music.httpx,
        "AsyncClient",
        lambda **_kwargs: FakeAsyncClient(responses, calls),
    )

    client = oo_music.OoMusicClient("http://oo-music:8787", source="netease")
    with pytest.raises(oo_music.OoMusicProtocolError):
        asyncio.run(client.search("晴天"))


def test_client_resolves_mp3_with_128_fallback(monkeypatch) -> None:
    calls: list[dict] = []
    responses = [
        {
            "source": "qq",
            "songId": 123,
            "available": False,
            "quality": "320mp3",
            "url": "",
        },
        {
            "source": "qq",
            "songId": 123,
            "available": True,
            "quality": "128mp3",
            "url": "https://example.invalid/song.mp3",
        },
    ]
    monkeypatch.setattr(
        oo_music.httpx,
        "AsyncClient",
        lambda **_kwargs: FakeAsyncClient(responses, calls),
    )

    client = oo_music.OoMusicClient("http://oo-music:8787", source="qq")
    result = asyncio.run(client.resolve_mp3("123"))

    assert result["quality"] == "128mp3"
    assert len(calls) == 2
    assert calls[0]["params"]["quality"] == "320mp3"
    assert calls[1]["params"]["quality"] == "128mp3"
    assert calls[1]["params"]["allow_fallback"] == "false"


def test_settings_reject_invalid_source_and_partial_auth() -> None:
    with pytest.raises(ValueError, match="MUSIC_SOURCE"):
        Settings(music_source="kugou")
    with pytest.raises(ValueError, match="must be set together"):
        Settings(oo_music_client_account_id="account-1")


def test_play_endpoint_rejects_different_source(monkeypatch) -> None:
    called = False

    async def fake_resolve(*_args, **_kwargs):
        nonlocal called
        called = True
        return {}

    monkeypatch.setattr(main.music_client, "resolve_mp3", fake_resolve)
    response = TestClient(main.app).post(
        "/v1/music/play",
        json={"song_id": "123", "source": "netease"},
    )

    assert response.status_code == 400
    assert response.json()["detail"]["code"] == "source_mismatch"
    assert called is False


def test_play_endpoint_rejects_non_mp3_or_empty_url(monkeypatch) -> None:
    played: list[str] = []

    async def fake_resolve(*_args, **_kwargs):
        return {"source": "qq", "available": True, "quality": "flac", "url": "https://example.invalid/a.flac"}

    async def fake_play(url: str) -> bool:
        played.append(url)
        return True

    monkeypatch.setattr(main.music_client, "resolve_mp3", fake_resolve)
    monkeypatch.setattr(main.mi_controller, "play_url", fake_play)
    response = TestClient(main.app).post("/v1/music/play", json={"song_id": "123"})

    assert response.status_code == 502
    assert response.json()["detail"]["code"] == "no_playable_url"
    assert played == []
