"""LLM 어댑터. app.py는 이 모듈의 chat_with_fallback()만 호출한다.

설계 요지:
- Provider 인터페이스를 분리해 Bedrock/Gemini/Stub을 교체 가능하게 한다.
- 어떤 예외·타임아웃·잘못된 JSON이든 StubProvider로 폴백해 /chat은 항상 응답한다.
- 크리덴셜은 코드/환경변수에 두지 않는다: Bedrock은 IRSA, Gemini 키는 Secrets Manager.
"""
import json
import logging
import os
import re
import urllib.request
from abc import ABC, abstractmethod

import boto3
from botocore.config import Config

log = logging.getLogger("chat-api.llm")

LLM_TIMEOUT_SEC = 10  # 계약: LLM 호출 타임아웃 10s
RESULT_KEYS = ("input_en", "input_pron", "reply_en", "reply_pron", "reply_ko", "topic")

# JSON 7필드 중 llm_provider는 서버가 채우므로 모델에는 6필드만 요구한다.
SYSTEM_PROMPT = (
    "You are an English conversation tutor for Korean learners. "
    "The user writes in Korean. Reply ONLY with one JSON object, no markdown, no extra text, "
    "with exactly these string keys: "
    '"input_en" (English translation of the user message), '
    '"input_pron" (Korean Hangul pronunciation of input_en), '
    '"reply_en" (your short, friendly English reply that continues the conversation), '
    '"reply_pron" (Korean Hangul pronunciation of reply_en), '
    '"reply_ko" (Korean translation of reply_en), '
    '"topic" (one short lowercase English topic word, e.g. cafe, airport, small-talk). '
    "IMPORTANT: input_pron and reply_pron are transliterations - write how the ENGLISH sentence "
    "sounds using Hangul letters. Never copy the user's original Korean sentence and never write "
    "the Korean meaning there. "
    'Example for the user message "커피 한 잔 주세요": '
    '{"input_en": "One coffee, please.", "input_pron": "원 커피, 플리즈.", '
    '"reply_en": "Sure! Hot or iced?", "reply_pron": "슈어! 핫 오어 아이스드?", '
    '"reply_ko": "물론이죠! 따뜻한 걸로 드릴까요, 아이스로 드릴까요?", "topic": "cafe"}'
)


class LLMError(Exception):
    """프로바이더 응답이 계약(6필드 JSON)을 만족하지 못할 때."""


def parse_llm_json(text: str) -> dict:
    """모델 출력에서 JSON 객체를 꺼내 6필드를 검증한다. 실패 시 LLMError(→ 폴백)."""
    if not isinstance(text, str) or not text.strip():
        raise LLMError("empty model output")
    t = text.strip()
    # 모델이 ```json 펜스를 붙이는 경우 대비
    t = re.sub(r"^```(?:json)?\s*|\s*```$", "", t)
    try:
        obj = json.loads(t)
    except json.JSONDecodeError as e:
        raise LLMError(f"invalid JSON: {e}") from e
    if not isinstance(obj, dict):
        raise LLMError("JSON is not an object")
    out = {}
    for k in RESULT_KEYS:
        v = obj.get(k)
        if not isinstance(v, str) or not v.strip():
            raise LLMError(f"missing or invalid field: {k}")
        out[k] = v
    return out


class Provider(ABC):
    name = "base"

    @abstractmethod
    def generate(self, message: str, history: list, topic_hint: str | None = None) -> dict:
        """RESULT_KEYS 6필드 dict를 반환. 실패 시 예외."""


def _history_messages(history: list) -> list:
    """role/content만 남기고 user/assistant 교대 규칙(Converse)을 맞추기 위해 정규화."""
    msgs = []
    for h in history:
        role = "assistant" if h.get("role") == "assistant" else "user"
        content = str(h.get("content", "")).strip()
        if not content:
            continue
        if msgs and msgs[-1]["role"] == role:  # 같은 role 연속 → 합침
            msgs[-1]["text"] += "\n" + content
        else:
            msgs.append({"role": role, "text": content})
    return msgs


class BedrockProvider(Provider):
    name = "bedrock"

    def __init__(self, model_id: str, region: str, client=None):
        self.model_id = model_id
        # 짧은 타임아웃 + 총 시도 1회: botocore의 max_attempts=1은 "재시도 1회(총 2회)"라
        # 최악 20s가 되어 10s 계약을 깨므로 total_max_attempts=1 로 지정한다.
        self.client = client or boto3.client(
            "bedrock-runtime",
            region_name=region,
            config=Config(
                read_timeout=LLM_TIMEOUT_SEC,
                connect_timeout=3,
                retries={"total_max_attempts": 1},
            ),
        )

    def generate(self, message, history, topic_hint=None):
        msgs = _history_messages(history)
        # Converse는 첫 메시지가 user여야 한다
        while msgs and msgs[0]["role"] != "user":
            msgs.pop(0)
        user_text = message if not topic_hint else f"[topic: {topic_hint}] {message}"
        if msgs and msgs[-1]["role"] == "user":
            msgs[-1]["text"] += "\n" + user_text
        else:
            msgs.append({"role": "user", "text": user_text})
        resp = self.client.converse(
            modelId=self.model_id,
            system=[{"text": SYSTEM_PROMPT}],
            messages=[{"role": m["role"], "content": [{"text": m["text"]}]} for m in msgs],
            inferenceConfig={"maxTokens": 600, "temperature": 0.5},
        )
        try:
            text = resp["output"]["message"]["content"][0]["text"]
        except (KeyError, IndexError, TypeError) as e:
            raise LLMError(f"unexpected Converse response shape: {e}") from e
        return parse_llm_json(text)


class GeminiProvider(Provider):
    name = "gemini"

    def __init__(self, secret_id: str, region: str, model: str | None = None, sm_client=None):
        self.secret_id = secret_id
        self.model = model or os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")
        self._sm = sm_client or boto3.client(
            "secretsmanager",
            region_name=region,
            config=Config(read_timeout=5, connect_timeout=3, retries={"total_max_attempts": 1}),
        )
        self._key = None  # 메모리 캐시만 사용(디스크/로그 기록 금지)

    def _api_key(self) -> str:
        if self._key:
            return self._key
        raw = self._sm.get_secret_value(SecretId=self.secret_id)["SecretString"]
        try:  # 평문 키 또는 {"api_key": "..."} 둘 다 허용
            obj = json.loads(raw)
            if isinstance(obj, dict):
                raw = obj.get("api_key") or obj.get("GEMINI_API_KEY") or ""
        except json.JSONDecodeError:
            pass
        if not raw:
            raise LLMError("gemini api key not found in secret")
        self._key = raw.strip()
        return self._key

    def generate(self, message, history, topic_hint=None):
        contents = [
            {"role": "model" if m["role"] == "assistant" else "user", "parts": [{"text": m["text"]}]}
            for m in _history_messages(history)
        ]
        user_text = message if not topic_hint else f"[topic: {topic_hint}] {message}"
        contents.append({"role": "user", "parts": [{"text": user_text}]})
        body = json.dumps({
            "systemInstruction": {"parts": [{"text": SYSTEM_PROMPT}]},
            "contents": contents,
            "generationConfig": {"responseMimeType": "application/json", "temperature": 0.5},
        }).encode()
        req = urllib.request.Request(
            f"https://generativelanguage.googleapis.com/v1beta/models/{self.model}:generateContent",
            data=body,
            # 키는 URL 쿼리가 아닌 헤더로 전달(접근 로그에 남지 않게)
            headers={"Content-Type": "application/json", "x-goog-api-key": self._api_key()},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=LLM_TIMEOUT_SEC) as r:  # noqa: S310 (고정 https URL)
            data = json.loads(r.read())
        try:
            text = data["candidates"][0]["content"]["parts"][0]["text"]
        except (KeyError, IndexError, TypeError) as e:
            raise LLMError(f"unexpected Gemini response shape: {e}") from e
        return parse_llm_json(text)


# 한글 → (영어, 한글발음). 데모/폴백용 최소 사전
_STUB_DICT = {
    "안녕": ("Hello", "헬로우"),
    "커피": ("I would like a coffee", "아이 우드 라이크 어 커피"),
    "공항": ("Where is the airport", "웨어 이즈 디 에어포트"),
    "고마워": ("Thank you", "땡큐"),
    "감사": ("Thank you", "땡큐"),
    "이름": ("What is your name", "왓 이즈 유어 네임"),
}
_STUB_DEFAULT = ("I want to practice English", "아이 원트 투 프랙티스 잉글리시")


class StubProvider(Provider):
    name = "stub"

    def generate(self, message, history, topic_hint=None):
        en, pron = _STUB_DEFAULT
        for ko, val in _STUB_DICT.items():
            if ko in message:
                en, pron = val
                break
        return {
            "input_en": en,
            "input_pron": pron,
            "reply_en": "Nice! Tell me more.",
            "reply_pron": "나이스! 텔 미 모어.",
            "reply_ko": "좋아요! 더 말해 주세요.",
            "topic": topic_hint or "small-talk",
        }


_cache: dict = {}


def get_provider(name: str) -> Provider:
    """설정값으로 Provider 생성(프로세스 내 캐시). 알 수 없는 값/생성 실패는 호출측에서 폴백."""
    name = (name or "bedrock").lower()
    if name in _cache:
        return _cache[name]
    region = os.environ.get("AWS_REGION", "ap-northeast-2")
    if name == "stub":
        p = StubProvider()
    elif name == "bedrock":
        model_id = os.environ.get("BEDROCK_MODEL_ID")
        if not model_id:
            raise LLMError("BEDROCK_MODEL_ID not set")
        p = BedrockProvider(model_id, region)
    elif name == "gemini":
        secret_id = os.environ.get("GEMINI_SECRET_ID")
        if not secret_id:
            raise LLMError("GEMINI_SECRET_ID not set")
        p = GeminiProvider(secret_id, region)
    else:
        raise LLMError(f"unknown LLM_PROVIDER: {name}")
    _cache[name] = p
    return p


def chat_with_fallback(provider_name: str, message: str, history: list, topic_hint: str | None = None):
    """(6필드 dict, llm_provider 라벨) 반환. 실패는 절대 전파하지 않는다."""
    name = (provider_name or "bedrock").lower()
    try:
        provider = get_provider(name)
        result = provider.generate(message, history, topic_hint)
        return result, provider.name
    except Exception as e:  # 타임아웃·권한·네트워크·파싱 모두 폴백 (사유는 로그에만)
        log.warning("llm provider=%s failed, fallback to stub: %s: %s", name, type(e).__name__, e)
        return StubProvider().generate(message, history, topic_hint), "stub(fallback)"
