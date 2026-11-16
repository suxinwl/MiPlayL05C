from __future__ import annotations

from typing import Any

import httpx


LX_SOURCES = frozenset({"kw", "kg", "tx", "wy", "mg"})
QUALITY_MAP = {"320mp3": "320k", "128mp3": "128k"}


class LxServerProtocolError(RuntimeError):
    """Raised when lxserver returns a response incompatible with the gateway contract."""


class LxServerClient:
    """Adapter for LX Music Server's native search and URL APIs.

    lxserver search results contain the complete ``songInfo`` object required by
    ``POST /api/music/url``. The gateway keeps that object beside the normalized
    string ID so voice playback never has to reconstruct a platform-specific ID.
    """

    def __init__(
        self,
        base_url: str,
        source: str = "kw",
        quality: str = "320mp3",
        allow_fallback: bool = True,
        user_name: str = "",
        user_token: str = "",
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.source = self._validate_source(source)
        self.quality = self._validate_quality(quality)
        self.allow_fallback = bool(allow_fallback)
        self.user_name = user_name.strip()
        self.user_token = user_token.strip()

    @staticmethod
    def _validate_source(source: str) -> str:
        normalized = str(source).strip().lower()
        if normalized not in LX_SOURCES:
            raise ValueError(f"unsupported lxserver source: {source!r}")
        return normalized

    @staticmethod
    def _validate_quality(quality: str) -> str:
        normalized = str(quality).strip().lower()
        if normalized not in QUALITY_MAP:
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

    def _headers(self) -> dict[str, str]:
        headers = {"Accept": "application/json"}
        if self.user_name:
            headers["X-User-Name"] = self.user_name
        if self.user_token:
            headers["X-User-Token"] = self.user_token
        return headers

    @staticmethod
    def _song_id(item: dict[str, Any]) -> str:
        for key in ("songmid", "songId", "id", "mid", "hash", "copyrightId"):
            value = item.get(key)
            if value is not None and str(value).strip():
                return str(value).strip()
        return ""

    @staticmethod
    def is_playable(payload: dict[str, Any]) -> bool:
        if payload.get("available") is False or payload.get("success") is False:
            return False
        url = payload.get("url") or payload.get("playbackUrl") or payload.get("playback_url")
        if not isinstance(url, str) or not url.strip():
            return False
        return url.startswith(("http://", "https://"))

    async def search(self, query: str, source: str | None = None) -> dict[str, Any]:
        selected_source = self._requested_source(source)
        params = {
            "name": query,
            "source": selected_source,
            "type": "song",
            "limit": 10,
            "page": 1,
        }
        async with httpx.AsyncClient(timeout=20) as client:
            response = await client.get(
                f"{self.base_url}/api/music/search",
                params=params,
                headers=self._headers(),
            )
            response.raise_for_status()
            payload = response.json()

        if not isinstance(payload, dict):
            raise LxServerProtocolError("lxserver search response is not an object")
        raw_items = payload.get("list")
        if not isinstance(raw_items, list):
            raise LxServerProtocolError("lxserver search response has no list")

        items: list[dict[str, Any]] = []
        for raw_item in raw_items:
            if not isinstance(raw_item, dict):
                continue
            item = dict(raw_item)
            item_id = self._song_id(item)
            if not item_id:
                continue
            item["id"] = item_id
            item["source"] = str(item.get("source") or selected_source).strip().lower()
            item["_lx_song_info"] = dict(raw_item)
            items.append(item)

        actual_source = str(payload.get("source") or selected_source).strip().lower()
        if actual_source != selected_source:
            raise LxServerProtocolError(
                f"lxserver response source mismatch: expected {selected_source!r}, got {actual_source!r}"
            )
        return {
            "source": selected_source,
            "items": items,
            "total": payload.get("total"),
            "has_more": payload.get("hasMore"),
            "raw": payload,
        }

    async def playback(
        self,
        song_id: str,
        source: str | None = None,
        quality: str | None = None,
        allow_fallback: bool | None = None,
        song_info: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        selected_source = self._requested_source(source)
        selected_quality = self._validate_quality(quality or self.quality)
        selected_fallback = self.allow_fallback if allow_fallback is None else bool(allow_fallback)
        info = dict(song_info or {})
        if not info:
            raise ValueError(
                "lxserver playback requires song_info from /v1/music/search; do not pass only a song ID"
            )
        info.setdefault("source", selected_source)
        info.setdefault("songmid", str(song_id))
        body = {
            "songInfo": info,
            "quality": QUALITY_MAP[selected_quality],
            "enableAutoSwitchApiSource": selected_fallback,
        }
        async with httpx.AsyncClient(timeout=30) as client:
            response = await client.post(
                f"{self.base_url}/api/music/url",
                json=body,
                headers=self._headers(),
            )
            response.raise_for_status()
            payload = response.json()

        if not isinstance(payload, dict):
            raise LxServerProtocolError("lxserver playback response is not an object")
        result = dict(payload)
        result["source"] = selected_source
        result["quality"] = result.get("quality") or selected_quality
        result["song_id"] = str(song_id)
        result["available"] = self.is_playable(result)
        return result

    async def resolve_mp3(
        self,
        song_id: str,
        source: str | None = None,
        quality: str | None = None,
        allow_fallback: bool | None = None,
        song_info: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        selected_quality = self._validate_quality(quality or self.quality)
        preferred = await self.playback(
            song_id,
            source,
            selected_quality,
            allow_fallback=allow_fallback,
            song_info=song_info,
        )
        if self.is_playable(preferred) or selected_quality == "128mp3":
            return preferred
        return await self.playback(
            song_id,
            source,
            "128mp3",
            allow_fallback=False,
            song_info=song_info,
        )
