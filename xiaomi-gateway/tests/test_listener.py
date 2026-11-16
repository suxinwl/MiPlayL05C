import asyncio

from app.services.listener import GatewayListener


class FakeMi:
    def __init__(self) -> None:
        self.spoken: list[str] = []
        self.played: list[str] = []

    async def speak(self, text: str) -> bool:
        self.spoken.append(text)
        return True

    async def play_url(self, url: str) -> bool:
        self.played.append(url)
        return True


class FakeMusic:
    async def search(self, _query: str, _source: str | None = None) -> dict:
        return {"items": [{"id": 123}]}

    async def playback(self, _song_id: str, _source: str | None = None, quality: str = "320mp3") -> dict:
        return {"url": "https://example.invalid/song.mp3"}


class FakeLLM:
    async def answer(self, _text: str) -> str:
        return "测试回答"


def test_native_command_is_left_to_xiaoai() -> None:
    mi = FakeMi()
    listener = GatewayListener(mi, FakeMusic(), FakeLLM())
    assert asyncio.run(listener.handle_text("打开客厅的灯")) == "native"
    assert mi.spoken == []
    assert mi.played == []


def test_music_command_uses_resolved_url() -> None:
    mi = FakeMi()
    listener = GatewayListener(mi, FakeMusic(), FakeLLM())
    assert asyncio.run(listener.handle_text("播放晴天")) == "music"
    assert mi.played == ["https://example.invalid/song.mp3"]
