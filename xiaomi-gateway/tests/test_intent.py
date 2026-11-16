from app.intent import classify


def test_native_mijia_command_is_not_intercepted() -> None:
    intent = classify("打开客厅的灯")
    assert intent.kind == "native"


def test_polite_native_mijia_command_is_not_intercepted() -> None:
    intent = classify("帮我打开客厅的灯")
    assert intent.kind == "native"


def test_music_command_is_intercepted() -> None:
    intent = classify("播放周杰伦晴天")
    assert intent.kind == "music"


def test_explicit_ai_command_is_intercepted() -> None:
    intent = classify("请问量子计算是什么")
    assert intent.kind == "ai"
