import asyncio

import pytest

from app.services import lxserver


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
        self.calls.append({"method": "GET", "url": url, **kwargs})
        return FakeResponse(self.responses.pop(0))

    async def post(self, url: str, **kwargs):
        self.calls.append({"method": "POST", "url": url, **kwargs})
        return FakeResponse(self.responses.pop(0))


def test_lxserver_search_normalizes_song_info(monkeypatch) -> None:
    calls: list[dict] = []
    responses = [
        {
            "source": "kw",
            "list": [{"name": "晴天", "singer": "周杰伦", "songmid": "22890", "source": "kw"}],
        }
    ]
    monkeypatch.setattr(
        lxserver.httpx,
        "AsyncClient",
        lambda **_kwargs: FakeAsyncClient(responses, calls),
    )

    client = lxserver.LxServerClient("http://192.168.8.1:9527", source="kw")
    result = asyncio.run(client.search("晴天"))

    assert result["items"][0]["id"] == "22890"
    assert result["items"][0]["_lx_song_info"]["songmid"] == "22890"
    assert calls[0]["params"] == {
        "name": "晴天",
        "source": "kw",
        "type": "song",
        "limit": 10,
        "page": 1,
    }


def test_lxserver_playback_sends_full_song_info_and_maps_quality(monkeypatch) -> None:
    calls: list[dict] = []
    responses = [{"url": "https://example.invalid/song.mp3", "quality": "320k"}]
    monkeypatch.setattr(
        lxserver.httpx,
        "AsyncClient",
        lambda **_kwargs: FakeAsyncClient(responses, calls),
    )

    song_info = {"name": "晴天", "singer": "周杰伦", "source": "kw", "songmid": "22890"}
    client = lxserver.LxServerClient("http://192.168.8.1:9527", source="kw")
    result = asyncio.run(client.resolve_mp3("22890", song_info=song_info))

    assert result["available"] is True
    assert calls[0]["json"]["songInfo"] == song_info
    assert calls[0]["json"]["quality"] == "320k"
    assert calls[0]["json"]["enableAutoSwitchApiSource"] is True


def test_lxserver_requires_song_info_for_url_resolution() -> None:
    client = lxserver.LxServerClient("http://192.168.8.1:9527", source="kw")
    with pytest.raises(ValueError, match="song_info"):
        asyncio.run(client.resolve_mp3("22890"))
