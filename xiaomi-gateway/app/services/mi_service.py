from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from miservice import MiAccount, MiIOService, MiNAService
from miservice.biohttp import ClientSession


@dataclass(frozen=True)
class MiServiceSettings:
    user: str
    password: str
    did: str
    token_path: str = "/config/.mi.token"
    tts_command: tuple[int, int] = (5, 3)


class MiServiceController:
    """Small async wrapper around the official MiService package.

    The controller is intentionally lazy: importing the gateway does not log
    into Xiaomi. Production startup should use a pre-created token mounted at
    ``token_path``; interactive OTP entry is not suitable for a NAS
    background container.
    """

    def __init__(self, settings: MiServiceSettings) -> None:
        self.settings = settings
        self._session: Any | None = None
        self._account: MiAccount | None = None
        self._mina: MiNAService | None = None
        self._miio: MiIOService | None = None

    async def start(self) -> None:
        if self._mina is not None:
            return
        self._session = ClientSession()
        self._account = MiAccount(
            self._session,
            self.settings.user,
            self.settings.password,
            self.settings.token_path,
        )
        self._mina = MiNAService(self._account)
        self._miio = MiIOService(self._account)
        # MiNAService.mi_request loads the mounted token and only falls back
        # to account login when the token is missing or rejected.
        try:
            await self._mina.device_list()
        except Exception as exc:
            self._mina = None
            raise RuntimeError("MiService login failed; check token or Xiaomi account") from exc

    async def device_list(self) -> list[dict[str, Any]]:
        await self.start()
        assert self._mina is not None
        return await self._mina.device_list() or []

    async def latest_questions(self) -> list[dict[str, Any]]:
        await self.start()
        assert self._mina is not None
        return await self._mina.get_latest_ask(self.settings.did)

    async def play_url(self, url: str) -> bool:
        await self.start()
        assert self._mina is not None
        return await self._mina.play_by_url(self.settings.did, url, 2)

    async def speak(self, text: str) -> bool:
        await self.start()
        assert self._miio is not None
        code = await self._miio.miot_action(self.settings.did, self.settings.tts_command, [text])
        return code == 0

    async def close(self) -> None:
        if self._session is not None:
            await self._session.close()
        self._session = None
        self._account = None
        self._mina = None
        self._miio = None
