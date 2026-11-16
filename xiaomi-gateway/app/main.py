import asyncio
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Query
import httpx

from .config import settings
from .intent import classify
from .schemas import (
    AIAnswerRequest,
    AIAnswerResponse,
    MiDeviceResponse,
    MusicResolveRequest,
    MusicPlayRequest,
    RouteRequest,
    RouteResponse,
)
from .services.oo_music import OoMusicClient, OoMusicProtocolError
from .services.llm import LLMService
from .services.listener import GatewayListener
from .services.mi_service import MiServiceController, MiServiceSettings

music_client = OoMusicClient(
    settings.oo_music_base_url,
    source=settings.music_source,
    quality=settings.music_quality,
    allow_fallback=settings.music_allow_fallback,
    account_id=settings.oo_music_client_account_id,
    access_key=settings.oo_music_client_access_key,
)
llm_service = LLMService(settings)
mi_controller = MiServiceController(
    MiServiceSettings(
        user=settings.mi_user,
        password=settings.mi_pass,
        did=settings.mi_did,
        token_path=settings.mi_token_path,
        tts_command=settings.speaker_tts_command,
    )
)
listener_stop = asyncio.Event()
listener_task: asyncio.Task[None] | None = None


@asynccontextmanager
async def lifespan(_app: FastAPI):
    global listener_task
    if settings.mi_listener_enabled:
        listener = GatewayListener(
            mi_controller,
            music_client,
            llm_service,
            settings.mi_poll_interval,
        )
        listener_stop.clear()
        listener_task = asyncio.create_task(listener.run(listener_stop))
    try:
        yield
    finally:
        if listener_task is not None:
            listener_stop.set()
            listener_task.cancel()
            await asyncio.gather(listener_task, return_exceptions=True)
            listener_task = None
        await mi_controller.close()


app = FastAPI(title="xiaomi-gateway", version="0.1.0", lifespan=lifespan)


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok", "service": "xiaomi-gateway"}


@app.get("/v1/status")
async def status() -> dict[str, object]:
    """Return non-sensitive runtime configuration for deployment checks."""
    return {
        "service": "xiaomi-gateway",
        "speaker_hardware": settings.speaker_hardware,
        "stream_response": settings.stream_response,
        "mi_listener_enabled": settings.mi_listener_enabled,
        "mi_did_configured": bool(settings.mi_did),
        "mi_token_path": settings.mi_token_path,
        "model_provider": settings.model_provider,
        "model_name": settings.model_name,
        "model_key_configured": bool(settings.model_api_key),
        "oo_music_base_url": settings.oo_music_base_url,
        "music_source": settings.music_source,
        "music_quality": settings.music_quality,
        "music_allow_fallback": settings.music_allow_fallback,
        "oo_music_auth_configured": settings.oo_music_auth_configured,
    }


def _validate_request_source(source: str | None) -> str:
    if source is not None and source.strip().lower() != settings.music_source:
        raise HTTPException(
            status_code=400,
            detail={
                "code": "source_mismatch",
                "message": f"请求 source 必须与网关 MUSIC_SOURCE={settings.music_source} 一致",
            },
        )
    return settings.music_source


def _music_http_error(exc: Exception) -> HTTPException:
    if isinstance(exc, ValueError):
        return HTTPException(
            status_code=400,
            detail={"code": "invalid_music_request", "message": str(exc)},
        )
    if isinstance(exc, OoMusicProtocolError):
        return HTTPException(
            status_code=502,
            detail={"code": "music_protocol_error", "message": str(exc)},
        )
    if isinstance(exc, httpx.HTTPStatusError):
        status = exc.response.status_code
        if status in (401, 403):
            code = "music_auth_required"
            message = "当前音乐源登录态或客户端授权无效"
        elif status == 503:
            code = "music_source_unavailable"
            message = "当前音乐源服务暂不可用"
        else:
            code = "music_upstream_error"
            message = f"oo-music 返回 HTTP {status}"
        return HTTPException(status_code=502, detail={"code": code, "message": message})
    return HTTPException(
        status_code=502,
        detail={"code": "music_upstream_error", "message": "音乐服务暂时不可用"},
    )


@app.post("/v1/route", response_model=RouteResponse)
async def route(request: RouteRequest) -> RouteResponse:
    intent = classify(request.text)
    if intent.kind == "native":
        # 重要：未命中网关前缀的内容必须交给小爱原生能力，例如米家灯控。
        return RouteResponse(
            intent="native",
            text=request.text,
            handled=False,
            passthrough=True,
            reason=intent.reason,
        )
    if intent.kind == "music":
        return RouteResponse(
            intent="music",
            text=request.text,
            handled=False,
            passthrough=False,
            source=_validate_request_source(request.source),
            reason="music adapter placeholder; next step calls oo-music then MiService",
        )
    return RouteResponse(
        intent="ai",
        text=request.text,
        handled=False,
        passthrough=False,
        reason="LLM adapter placeholder; next step calls configured provider and L05C TTS",
    )


@app.post("/v1/music/resolve")
async def resolve_music(request: MusicResolveRequest) -> dict[str, object]:
    """Resolve a fresh playback URL from oo-music.

    The URL is intentionally resolved just in time because QQ/NetEase URLs
    can be signed and expire. MiService playback will be added after this
    HTTP boundary is validated against the L05C.
    """
    source = _validate_request_source(request.source)
    try:
        result = await music_client.resolve_mp3(
            request.song_id,
            source,
            quality=request.quality,
            allow_fallback=settings.music_allow_fallback,
        )
    except Exception as exc:
        raise _music_http_error(exc) from exc
    return {
        "source": source,
        "song_id": request.song_id,
        "quality": result.get("quality") or request.quality or settings.music_quality,
        "result": result,
    }


@app.get("/v1/mi/devices", response_model=MiDeviceResponse)
async def mi_devices() -> MiDeviceResponse:
    """Verify MiService credentials/token and return the account devices."""
    return MiDeviceResponse(devices=await mi_controller.device_list())


@app.post("/v1/music/play")
async def play_music(request: MusicPlayRequest) -> dict[str, object]:
    """Resolve a fresh URL from oo-music and send it to the L05C."""
    source = _validate_request_source(request.source)
    try:
        result = await music_client.resolve_mp3(
            request.song_id,
            source,
            quality=request.quality,
            allow_fallback=settings.music_allow_fallback,
        )
    except Exception as exc:
        raise _music_http_error(exc) from exc
    url = result.get("url") or result.get("playbackUrl") or result.get("playback_url")
    if not music_client.is_playable(result) or not isinstance(url, str) or not url:
        raise HTTPException(
            status_code=502,
            detail={"code": "no_playable_url", "message": "oo-music returned no playable MP3 URL"},
        )
    played = await mi_controller.play_url(url)
    return {
        "source": source,
        "song_id": request.song_id,
        "quality": result.get("quality") or request.quality or settings.music_quality,
        "played": played,
    }


@app.get("/v1/music/search")
async def search_music(
    q: str = Query(min_length=1, max_length=200),
    source: str | None = Query(default=None),
) -> dict[str, object]:
    """Search the configured music backend without touching the speaker."""
    configured_source = _validate_request_source(source)
    try:
        result = await music_client.search(q, configured_source)
    except Exception as exc:
        raise _music_http_error(exc) from exc
    return {"source": configured_source, "query": q, "result": result}


@app.post("/v1/ai/answer", response_model=AIAnswerResponse)
async def ai_answer(request: AIAnswerRequest) -> AIAnswerResponse:
    answer = await llm_service.answer(request.text)
    return AIAnswerResponse(
        provider=settings.model_provider,
        model=settings.model_name,
        answer=answer,
    )
