from __future__ import annotations

from openai import AsyncOpenAI

from ..config import Settings


class LLMService:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    async def answer(self, text: str) -> str:
        api_key = self.settings.model_api_key
        if not api_key:
            raise RuntimeError(
                "model API key is not configured; set MODEL_API_KEY or the provider-specific key"
            )
        client = AsyncOpenAI(
            api_key=api_key,
            base_url=self.settings.model_base_url,
        )
        response = await client.chat.completions.create(
            model=self.settings.model_name,
            messages=[
                {
                    "role": "system",
                    "content": "请用简洁、适合语音播报的中文回答。不要使用 Markdown 表格或链接。",
                },
                {"role": "user", "content": text},
            ],
            temperature=0.7,
        )
        content = response.choices[0].message.content if response.choices else None
        if not content:
            raise RuntimeError("model returned an empty answer")
        return content.strip()
