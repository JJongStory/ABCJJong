"""Bedrock/Gemini 실호출 금지: 모든 외부 호출은 Stubber/mock으로 대체."""
import json
from unittest import mock

import boto3
import pytest
from botocore.exceptions import ReadTimeoutError
from botocore.stub import Stubber

import llm

GOOD = {"input_en": "Hello", "input_pron": "헬로", "reply_en": "Hi!", "reply_pron": "하이",
        "reply_ko": "안녕!", "topic": "small-talk"}
KEYS = set(GOOD)


@pytest.fixture(autouse=True)
def _clear_cache():
    llm._cache.clear()


def _bedrock_with_stub(text=None, error=None):
    client = boto3.client("bedrock-runtime", region_name="ap-northeast-2",
                          aws_access_key_id="x", aws_secret_access_key="x")  # 더미(호출 안 함)
    stub = Stubber(client)
    if error:
        stub.add_client_error("converse", service_error_code=error)
    else:
        stub.add_response("converse", {
            "output": {"message": {"role": "assistant", "content": [{"text": text}]}},
            "stopReason": "end_turn",
            "usage": {"inputTokens": 1, "outputTokens": 1, "totalTokens": 2},
            "metrics": {"latencyMs": 1},
        })
    stub.activate()
    return llm.BedrockProvider("test-model", "ap-northeast-2", client=client)


def _patch_provider(name, provider, monkeypatch):
    monkeypatch.setattr(llm, "get_provider", lambda n: provider)


def test_bedrock_success_parse():
    p = _bedrock_with_stub(json.dumps(GOOD))
    assert p.generate("안녕", [{"role": "user", "content": "a"}]) == GOOD


def test_bedrock_code_fence_parse():
    p = _bedrock_with_stub("```json\n" + json.dumps(GOOD) + "\n```")
    assert set(p.generate("안녕", [])) == KEYS


def test_bedrock_exception_fallback(monkeypatch):
    _patch_provider("bedrock", _bedrock_with_stub(error="ThrottlingException"), monkeypatch)
    res, label = llm.chat_with_fallback("bedrock", "커피", [])
    assert label == "stub(fallback)" and set(res) == KEYS


def test_bedrock_invalid_json_fallback(monkeypatch):
    _patch_provider("bedrock", _bedrock_with_stub("not json at all"), monkeypatch)
    _, label = llm.chat_with_fallback("bedrock", "커피", [])
    assert label == "stub(fallback)"


def test_bedrock_missing_field_fallback(monkeypatch):
    bad = {k: v for k, v in GOOD.items() if k != "reply_ko"}
    _patch_provider("bedrock", _bedrock_with_stub(json.dumps(bad)), monkeypatch)
    _, label = llm.chat_with_fallback("bedrock", "커피", [])
    assert label == "stub(fallback)"


def test_bedrock_timeout_fallback(monkeypatch):
    p = llm.BedrockProvider("m", "ap-northeast-2", client=mock.Mock())
    p.client.converse.side_effect = ReadTimeoutError(endpoint_url="https://bedrock-runtime")
    _patch_provider("bedrock", p, monkeypatch)
    _, label = llm.chat_with_fallback("bedrock", "커피", [])
    assert label == "stub(fallback)"


def test_bedrock_client_timeout_config():
    c = llm.BedrockProvider("m", "ap-northeast-2").client.meta.config
    assert c.read_timeout == 10 and c.connect_timeout == 3 and c.retries.get("total_max_attempts") == 1


def test_success_label_is_provider_name(monkeypatch):
    _patch_provider("bedrock", _bedrock_with_stub(json.dumps(GOOD)), monkeypatch)
    res, label = llm.chat_with_fallback("bedrock", "안녕", [])
    assert label == "bedrock" and res == GOOD


def test_stub_selected_label_is_stub():
    res, label = llm.chat_with_fallback("stub", "안녕하세요", [])
    assert label == "stub" and set(res) == KEYS and res["input_en"] == "Hello"


def test_unknown_or_unconfigured_provider_falls_back(monkeypatch):
    monkeypatch.delenv("BEDROCK_MODEL_ID", raising=False)
    assert llm.chat_with_fallback("bedrock", "x", [])[1] == "stub(fallback)"
    assert llm.chat_with_fallback("zzz", "x", [])[1] == "stub(fallback)"


# ---- Gemini ----
def _gemini(secret="plain-key"):
    sm = mock.Mock()
    sm.get_secret_value.return_value = {"SecretString": secret}
    return llm.GeminiProvider("hermes/prd/chat/gemini-api-key", "ap-northeast-2", sm_client=sm)


def _urlopen_returning(payload):
    resp = mock.MagicMock()
    resp.__enter__.return_value.read.return_value = json.dumps(payload).encode()
    return mock.patch("llm.urllib.request.urlopen", return_value=resp)


def test_gemini_success_and_key_in_header():
    p = _gemini(json.dumps({"api_key": "k123"}))
    payload = {"candidates": [{"content": {"parts": [{"text": json.dumps(GOOD)}]}}]}
    with _urlopen_returning(payload) as u:
        assert p.generate("안녕", []) == GOOD
    req = u.call_args.args[0]
    assert req.get_header("X-goog-api-key") == "k123" and "k123" not in req.full_url
    assert u.call_args.kwargs["timeout"] == 10


def test_gemini_invalid_json_fallback(monkeypatch):
    payload = {"candidates": [{"content": {"parts": [{"text": "oops"}]}}]}
    _patch_provider("gemini", _gemini(), monkeypatch)
    with _urlopen_returning(payload):
        assert llm.chat_with_fallback("gemini", "x", [])[1] == "stub(fallback)"


def test_gemini_timeout_fallback(monkeypatch):
    _patch_provider("gemini", _gemini(), monkeypatch)
    with mock.patch("llm.urllib.request.urlopen", side_effect=TimeoutError("timed out")):
        assert llm.chat_with_fallback("gemini", "x", [])[1] == "stub(fallback)"


def test_gemini_secret_error_fallback(monkeypatch):
    p = _gemini()
    p._sm.get_secret_value.side_effect = RuntimeError("AccessDenied")
    _patch_provider("gemini", p, monkeypatch)
    assert llm.chat_with_fallback("gemini", "x", [])[1] == "stub(fallback)"
