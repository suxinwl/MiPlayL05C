from dataclasses import dataclass
import os


ALLOWED_MUSIC_SOURCES = frozenset({"qq", "netease"})
ALLOWED_MUSIC_QUALITIES = frozenset({"320mp3", "128mp3"})


def _parse_command(value: str, default: tuple[int, int]) -> tuple[int, int]:
    try:
        first, second = (int(part.strip()) for part in value.split(",", 1))
        return first, second
    except (TypeError, ValueError):
        return default


def _parse_bool(value: str, default: bool = False) -> bool:
    normalized = str(value).strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    return default


@dataclass(frozen=True)
class Settings:
    host: str = os.getenv("GATEWAY_HOST", "0.0.0.0")
    port: int = int(os.getenv("GATEWAY_PORT", "58092"))
    oo_music_base_url: str = os.getenv("OO_MUSIC_BASE_URL", "http://oo-music:8787").rstrip("/")
    music_source: str = os.getenv("MUSIC_SOURCE", "qq").strip().lower()
    music_quality: str = os.getenv("MUSIC_QUALITY", "320mp3").strip().lower()
    music_allow_fallback: bool = _parse_bool(os.getenv("MUSIC_ALLOW_FALLBACK", "true"), True)
    oo_music_client_account_id: str = os.getenv("OO_MUSIC_CLIENT_ACCOUNT_ID", "").strip()
    oo_music_client_access_key: str = os.getenv("OO_MUSIC_CLIENT_ACCESS_KEY", "").strip()
    model_provider: str = os.getenv("MODEL_PROVIDER", "deepseek")
    model_name: str = os.getenv("MODEL_NAME", "deepseek-flash")
    model_base_url: str = os.getenv("MODEL_BASE_URL", "https://api.deepseek.com").rstrip("/")
    mi_user: str = os.getenv("MI_USER", "").strip()
    mi_pass: str = os.getenv("MI_PASS", "")
    mi_did: str = os.getenv("MI_DID", "").strip()
    mi_token_path: str = os.getenv("MI_TOKEN_PATH", "/config/.mi.token").strip()
    speaker_hardware: str = os.getenv("SPEAKER_HARDWARE", "L05C").strip()
    speaker_tts_command: tuple[int, int] = _parse_command(
        os.getenv("SPEAKER_TTS_COMMAND", "5,3"), (5, 3)
    )
    stream_response: bool = os.getenv("STREAM_RESPONSE", "false").lower() == "true"
    mi_listener_enabled: bool = os.getenv("MI_LISTENER_ENABLED", "false").lower() == "true"
    mi_poll_interval: float = float(os.getenv("MI_POLL_INTERVAL", "1.0"))

    def __post_init__(self) -> None:
        if self.music_source not in ALLOWED_MUSIC_SOURCES:
            raise ValueError(
                f"MUSIC_SOURCE must be one of {sorted(ALLOWED_MUSIC_SOURCES)}, got {self.music_source!r}"
            )
        if self.music_quality not in ALLOWED_MUSIC_QUALITIES:
            raise ValueError(
                f"MUSIC_QUALITY must be one of {sorted(ALLOWED_MUSIC_QUALITIES)}, got {self.music_quality!r}"
            )
        if bool(self.oo_music_client_account_id) != bool(self.oo_music_client_access_key):
            raise ValueError(
                "OO_MUSIC_CLIENT_ACCOUNT_ID and OO_MUSIC_CLIENT_ACCESS_KEY must be set together"
            )

    @property
    def oo_music_auth_configured(self) -> bool:
        return bool(self.oo_music_client_account_id and self.oo_music_client_access_key)

    @property
    def model_api_key(self) -> str:
        explicit = os.getenv("MODEL_API_KEY", "").strip()
        if explicit:
            return explicit
        provider_keys = {
            "deepseek": "DEEPSEEK_API_KEY",
            "openai": "OPENAI_API_KEY",
            "doubao": "ARK_API_KEY",
        }
        return os.getenv(provider_keys.get(self.model_provider.lower(), ""), "").strip()


settings = Settings()
