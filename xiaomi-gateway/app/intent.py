from dataclasses import dataclass


@dataclass(frozen=True)
class Intent:
    kind: str
    reason: str


# 这些词必须保持足够明确，避免抢走“打开客厅的灯”等原生米家指令。
MUSIC_PREFIXES = ("播放", "暂停", "停止播放", "下一首", "上一首", "继续播放", "播放歌单", "播放电台")
AI_PREFIXES = ("请问", "帮我", "解释", "什么是", "为什么", "如何", "总结", "告诉我")
NATIVE_CONTROL_PREFIXES = (
    "请打开",
    "请关闭",
    "请开启",
    "请关掉",
    "帮我打开",
    "帮我关闭",
    "帮我开启",
    "帮我关掉",
)


def classify(text: str) -> Intent:
    normalized = " ".join(text.strip().split())
    if normalized.startswith(NATIVE_CONTROL_PREFIXES):
        return Intent("native", "matched explicit native smart-home control prefix")
    if normalized.startswith(MUSIC_PREFIXES):
        return Intent("music", "matched music command prefix")
    if normalized.startswith(AI_PREFIXES):
        return Intent("ai", "matched explicit AI prefix")
    return Intent("native", "no gateway prefix; preserve XiaoAI native handling")
