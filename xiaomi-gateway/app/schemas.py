from typing import Any, Literal

from pydantic import BaseModel, Field


IntentKind = Literal["music", "ai", "native"]


class RouteRequest(BaseModel):
    text: str = Field(min_length=1, max_length=2000)
    source: str | None = Field(default=None, description="兼容字段，必须匹配网关 MUSIC_SOURCE")


class RouteResponse(BaseModel):
    intent: IntentKind
    text: str
    handled: bool
    passthrough: bool
    reason: str
    source: str | None = None


class MusicResolveRequest(BaseModel):
    song_id: str = Field(min_length=1, max_length=128)
    source: str | None = Field(default=None, description="兼容字段，必须匹配网关 MUSIC_SOURCE")
    quality: str | None = Field(default=None, pattern=r"^[A-Za-z0-9_-]+$")
    song_info: dict[str, Any] | None = Field(
        default=None,
        description="lxserver /api/music/url 所需的完整歌曲信息，来自 /v1/music/search 结果",
    )


class AIAnswerRequest(BaseModel):
    text: str = Field(min_length=1, max_length=2000)


class AIAnswerResponse(BaseModel):
    provider: str
    model: str
    answer: str


class MusicPlayRequest(MusicResolveRequest):
    """Resolve a source URL and send it to the configured Xiaomi speaker."""


class MiDeviceResponse(BaseModel):
    devices: list[dict[str, object]]
