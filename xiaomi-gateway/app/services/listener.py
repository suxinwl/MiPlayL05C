from __future__ import annotations

import asyncio
import logging
import re
from typing import Any

from ..intent import classify
from .llm import LLMService
from .mi_service import MiServiceController
from .oo_music import OoMusicClient

LOGGER = logging.getLogger("xiaomi-gateway.listener")


class GatewayListener:
    """Single MiNA polling loop which preserves native XiaoAI commands."""

    def __init__(
        self,
        mi: MiServiceController,
        music: OoMusicClient,
        llm: LLMService,
        poll_interval: float = 1.0,
    ) -> None:
        self.mi = mi
        self.music = music
        self.llm = llm
        self.poll_interval = max(0.5, poll_interval)
        self._seen: set[str] = set()
        self._initialized = False

    async def run(self, stop_event: asyncio.Event) -> None:
        while not stop_event.is_set():
            try:
                messages = await self.mi.latest_questions()
                await self._process(messages)
            except asyncio.CancelledError:
                raise
            except Exception:
                LOGGER.exception("MiNA listener poll failed")
            try:
                await asyncio.wait_for(stop_event.wait(), timeout=self.poll_interval)
            except asyncio.TimeoutError:
                pass

    async def _process(self, messages: list[dict[str, Any]]) -> None:
        fresh: list[dict[str, Any]] = []
        for message in messages:
            key = self._message_key(message)
            if not key or key in self._seen:
                continue
            self._seen.add(key)
            fresh.append(message)

        # Do not replay the existing conversation history after startup.
        if not self._initialized:
            self._initialized = True
            return

        for message in sorted(fresh, key=lambda item: item.get("timestamp_ms", 0)):
            text = self._question_text(message)
            if not text:
                continue
            await self.handle_text(text)

        # Keep memory bounded while retaining enough recent request IDs.
        if len(self._seen) > 500:
            self._seen = set(list(self._seen)[-250:])

    async def handle_text(self, text: str) -> str:
        intent = classify(text)
        if intent.kind == "native":
            # Do not mute or answer this branch. XiaoAI handles Mi Home
            # commands such as "打开客厅的灯" natively.
            return "native"
        if intent.kind == "music":
            await self._handle_music(text)
            return "music"
        answer = await self.llm.answer(text)
        await self.mi.speak(answer)
        return "ai"

    async def _handle_music(self, text: str) -> None:
        query = self._music_query(text)
        if not query:
            return
        try:
            search = await self.music.search(query)
        except Exception:
            LOGGER.exception("music search failed")
            await self.mi.speak("音乐服务暂时不可用")
            return
        items = search.get("items")
        if not isinstance(items, list) or not items:
            await self.mi.speak("没有找到这首歌")
            return
        first = items[0]
        if not isinstance(first, dict):
            await self.mi.speak("没有找到可播放的歌曲")
            return
        song_id = first.get("id")
        if song_id is None:
            await self.mi.speak("歌曲信息不完整")
            return
        try:
            if hasattr(self.music, "resolve_mp3"):
                playback = await self.music.resolve_mp3(str(song_id))
            else:
                playback = await self.music.playback(str(song_id), quality="320mp3")
        except Exception:
            LOGGER.exception("music playback resolution failed")
            await self.mi.speak("音乐服务暂时不可用")
            return
        playable = (
            self.music.is_playable(playback)
            if hasattr(self.music, "is_playable")
            else self._is_playable(playback)
        )
        if not playable:
            await self.mi.speak("这首歌暂时没有可播放地址")
            return
        url = playback.get("url") or playback.get("playbackUrl") or playback.get("playback_url")
        if not isinstance(url, str) or not url:
            await self.mi.speak("这首歌暂时没有可播放地址")
            return
        if not await self.mi.play_url(url):
            await self.mi.speak("播放失败，请稍后再试")

    @staticmethod
    def _is_playable(payload: dict[str, Any]) -> bool:
        if payload.get("available") is False:
            return False
        url = payload.get("url") or payload.get("playbackUrl") or payload.get("playback_url")
        return isinstance(url, str) and bool(url.strip())

    @staticmethod
    def _music_query(text: str) -> str:
        normalized = " ".join(text.strip().split())
        for prefix in ("播放歌曲", "播放歌单", "播放电台", "在线播放", "播放", "放"):
            if normalized.startswith(prefix):
                return re.sub(r"^[\s音乐]+", "", normalized[len(prefix) :]).strip()
        return normalized

    @staticmethod
    def _message_key(message: dict[str, Any]) -> str:
        request_id = str(message.get("request_id") or "").strip()
        if request_id:
            return request_id
        return f"{message.get('timestamp_ms', '')}:{GatewayListener._question_text(message)}"

    @staticmethod
    def _question_text(message: dict[str, Any]) -> str:
        response = message.get("response")
        if not isinstance(response, dict):
            return ""
        answers = response.get("answer")
        if not isinstance(answers, list):
            return ""
        for answer in answers:
            if isinstance(answer, dict):
                question = str(answer.get("question") or "").strip()
                if question:
                    return question
        return ""
