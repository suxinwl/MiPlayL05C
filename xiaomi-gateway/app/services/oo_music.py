from typing import Any

import httpx

from ..config import ALLOWED_MUSIC_QUALITIES, ALLOWED_MUSIC_SOURCES


class OoMusicProtocolError(RuntimeError):
    """Raised when oo-music returns a response incompatible with its contract."""


class OoMusicClient:
    def __init__(
        self,
        base_url: str,
        source: str = "qq",
        quality: str = "320mp3",
        allow_fallback: bool = True,
        account_id: str = "",
        access_key: str = "",
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.source = self._validate_source(source)
        self.quality = self._validate_quality(quality)
        self.allow_fallback = bool(allow_fallback)
        self.account_id = account_id.strip()
        self.access_key = access_key.strip()
        if bool(self.account_id) != bool(self.access_key):
            raise ValueError("oo-music client account ID and access key must be set together")

    @staticmethod
    def _validate_source(source: str) -> str:
        normalized = str(source).strip().lower()
        if normalized not in ALLOWED_MUSIC_SOURCES:
            raise ValueError(f"unsupported oo-music source: {source!r}")
        return normalized

    @staticmethod
    def _validate_quality(quality: str) -> str:
        normalized = str(quality).strip().lower()
        if normalized not in ALLOWED_MUSIC_QUALITIES:
            raise ValueError(f"unsupported L05C music quality: {quality!r}")
        return normalized

    def _requested_source(self, source: str | None) -> str:
        if source is None or not str(source).strip():
            return self.source
        normalized = self._validate_source(source)
        if normalized != self.source:
            raise ValueError(
                f"requested music source {normalized!r} does not match configured source {self.source!r}"
            )
        return normalized

    def _headers(self, source: str) -> dict[str, str]:
        headers = {"X-OO-Music-Source": source}
        if self.account_id and self.access_key:
            headers["X-OO-Music-Account-ID"] = self.account_id
            headers["X-OO-Music-Access-Key"] = self.access_key
        return headers

    def _validate_payload_source(self, payload: dict[str, Any], source: str) -> dict[str, Any]:
        actual = str(payload.get("source") or "").strip().lower()
        if actual != source:
            raise OoMusicProtocolError(
                f"oo-music response source mismatch: expected {source!r}, got {actual or '<missing>'!r}"
            )
        return payload

    @staticmethod
    def is_playable(payload: dict[str, Any]) -> bool:
        if payload.get("available") is False:
            return False
        url = payload.get("url") or payload.get("playbackUrl") or payload.get("playback_url")
        if not isinstance(url, str) or not url.strip():
            return False
        quality = str(payload.get("quality") or "").strip().lower()
        if quality and not quality.endswith("mp3"):
            return False
        if not quality and ".mp3" not in url.lower().split("?", 1)[0]:
            return False
        return True

    async def search(self, query: str, source: str | None = None) -> dict[str, Any]:
        source = self._requested_source(source)
        params: dict[str, Any] = {"source": source, "q": query, "page": 1, "page_size": 10}
        async with httpx.AsyncClient(timeout=20) as client:
            response = await client.get(
                f"{self.base_url}/api/search", params=params, headers=self._headers(source)
            )
            response.raise_for_status()
            payload = self._validate_payload_source(response.json(), source)
            items = payload.get("items")
            if not isinstance(items, list):
                raise OoMusicProtocolError("oo-music search response has no items list")
            for item in items:
                if not isinstance(item, dict):
                    raise OoMusicProtocolError("oo-music search response contains an invalid item")
                item_source = str(item.get("source") or "").strip().lower()
                if item_source != source:
                    raise OoMusicProtocolError(
                        f"oo-music search item source mismatch: expected {source!r}, got {item_source or '<missing>'!r}"
                    )
            return payload

    async def playback(
        self,
        song_id: str,
        source: str | None = None,
        quality: str | None = None,
        allow_fallback: bool | None = None,
    ) -> dict[str, Any]:
        if not str(song_id).strip():
            raise ValueError("song_id must not be empty")
        source = self._requested_source(source)
        selected_quality = self._validate_quality(quality or self.quality)
        selected_fallback = self.allow_fallback if allow_fallback is None else bool(allow_fallback)
        params: dict[str, Any] = {
            "source": source,
            "song_id": song_id,
            "quality": selected_quality,
            "allow_fallback": str(selected_fallback).lower(),
        }
        async with httpx.AsyncClient(timeout=20) as client:
            response = await client.get(
                f"{self.base_url}/api/playback", params=params, headers=self._headers(source)
            )
            response.raise_for_status()
            return self._validate_payload_source(response.json(), source)

    async def resolve_mp3(
        self,
        song_id: str,
        source: str | None = None,
        quality: str | None = None,
        allow_fallback: bool | None = None,
    ) -> dict[str, Any]:
        """Resolve a fresh MP3 URL, trying the configured quality then 128 kbps."""
        source = self._requested_source(source)
        preferred_quality = self._validate_quality(quality or self.quality)
        preferred = await self.playback(
            song_id, source, preferred_quality, allow_fallback=allow_fallback
        )
        if self.is_playable(preferred):
            return preferred
        if preferred_quality != "128mp3":
            fallback = await self.playback(song_id, source, "128mp3", allow_fallback=False)
            if self.is_playable(fallback):
                return fallback
            return fallback
        return preferred
