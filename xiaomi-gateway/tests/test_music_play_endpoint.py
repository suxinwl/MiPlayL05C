from fastapi.testclient import TestClient

from app import main


def test_music_play_resolves_and_sends_url(monkeypatch) -> None:
    played: list[str] = []

    async def fake_resolve_mp3(_song_id: str, _source=None, quality=None, allow_fallback=None):
        return {"url": "https://example.invalid/qq-signed.mp3"}

    async def fake_play_url(url: str) -> bool:
        played.append(url)
        return True

    monkeypatch.setattr(main.music_client, "resolve_mp3", fake_resolve_mp3)
    monkeypatch.setattr(main.mi_controller, "play_url", fake_play_url)

    response = TestClient(main.app).post(
        "/v1/music/play",
        json={"song_id": "123", "quality": "320mp3"},
    )

    assert response.status_code == 200
    assert response.json()["played"] is True
    assert played == ["https://example.invalid/qq-signed.mp3"]
