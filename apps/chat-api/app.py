"""chat-api: 영어 회화 챗 API (EKS). 앱 기능은 최소, 운영성(/health·로그·타임아웃·폴백)에 집중."""
import logging
import os
import socket
import time

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

import llm

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("chat-api")

HISTORY_MAX = 6          # 계약: 슬라이딩 윈도우 6개 (무상태 → Pod 수평 확장 가능)
UPSTREAM_TIMEOUT = 3.0   # content-api 호출 timeout (계약: 3s)
NOTE_TIMEOUT = 5.0

app = FastAPI(title="chat-api")


def pod_name() -> str:
    return os.environ.get("HOSTNAME") or socket.gethostname()


def provider_setting() -> str:
    return os.environ.get("LLM_PROVIDER", "bedrock").lower()


@app.middleware("http")
async def access_log(request: Request, call_next):
    start = time.monotonic()
    try:
        response = await call_next(request)
    except Exception:
        # 예상 못 한 예외도 스택은 로그에, 클라이언트에는 일반 500만
        log.exception("unhandled error path=%s", request.url.path)
        return JSONResponse({"error": "internal_error"}, status_code=500)
    # probe 로그 소음 방지
    if request.url.path != "/health":
        log.info("%s %s -> %s %.0fms", request.method, request.url.path,
                 response.status_code, (time.monotonic() - start) * 1000)
    return response


class Turn(BaseModel):
    role: str
    content: str = Field(max_length=1000)


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=500)
    history: list[Turn] = Field(default_factory=list)  # 6개 초과는 거부하지 않고 최근 6개만 사용
    scenario_id: int | None = None


class ChatResponse(BaseModel):
    input_en: str
    input_pron: str
    reply_en: str
    reply_pron: str
    reply_ko: str
    topic: str
    llm_provider: str


@app.get("/health")
def health():
    # 의존성(LLM/content-api)을 확인하지 않는다: 외부 장애로 Pod가 재시작/제외되는 것을 방지
    return {"status": "ok"}


@app.get("/")
def root():
    return {
        "service": "chat-api",
        "pod": pod_name(),
        "version": os.environ.get("APP_VERSION", "dev"),
        "llm_provider": provider_setting(),
    }


def _bad_gateway(cause: str):
    log.warning("upstream failure: %s", cause)
    return JSONResponse({"error": "upstream_unavailable", "upstream": "content-api", "cause": cause},
                        status_code=502)


@app.get("/scenario")
def scenario():
    base = os.environ.get("CONTENT_API_URL", "").rstrip("/")
    if not base:
        return _bad_gateway("CONTENT_API_URL is not set")
    try:
        with httpx.Client(timeout=UPSTREAM_TIMEOUT) as c:
            r = c.get(f"{base}/scenarios")
            r.raise_for_status()
            data = r.json()
            # C4 증적: content-api `/`의 hostname = 실제로 응답한 EC2
            root_r = c.get(f"{base}/")
            root_r.raise_for_status()
            upstream_hostname = root_r.json().get("hostname")
    except httpx.TimeoutException as e:
        return _bad_gateway(f"timeout after {UPSTREAM_TIMEOUT:.0f}s: {type(e).__name__}")
    except httpx.HTTPStatusError as e:
        return _bad_gateway(f"upstream returned HTTP {e.response.status_code}")
    except (httpx.HTTPError, ValueError) as e:
        return _bad_gateway(f"{type(e).__name__}: {e}")
    return {"pod": pod_name(), "upstream": "content-api",
            "upstream_hostname": upstream_hostname, "data": data}


def _scenario_topic(scenario_id: int | None) -> str | None:
    """scenario_id가 있으면 topic 힌트만 best-effort로 조회. 실패해도 채팅은 계속."""
    base = os.environ.get("CONTENT_API_URL", "").rstrip("/")
    if scenario_id is None or not base:
        return None
    try:
        r = httpx.get(f"{base}/scenarios/{scenario_id}", timeout=UPSTREAM_TIMEOUT)
        r.raise_for_status()
        return r.json().get("topic")
    except Exception as e:
        log.warning("scenario topic lookup failed: %s", type(e).__name__)
        return None


@app.post("/chat", response_model=ChatResponse)
def chat(req: ChatRequest):
    history = [t.model_dump() for t in req.history[-HISTORY_MAX:]]
    topic_hint = _scenario_topic(req.scenario_id)
    result, label = llm.chat_with_fallback(provider_setting(), req.message, history, topic_hint)
    return {**result, "llm_provider": label}


@app.post("/note")
async def note(request: Request):
    base = os.environ.get("NOTE_API_URL", "").rstrip("/")
    if not base:
        return JSONResponse({"error": "note_api_not_configured"}, status_code=503)
    try:
        payload = await request.json()
    except ValueError:
        return JSONResponse({"error": "invalid_json"}, status_code=400)
    try:
        async with httpx.AsyncClient(timeout=NOTE_TIMEOUT) as c:
            r = await c.post(f"{base}/notes", json=payload)
        return JSONResponse(r.json(), status_code=r.status_code)
    except (httpx.HTTPError, ValueError) as e:
        log.warning("note proxy failure: %s", type(e).__name__)
        return JSONResponse({"error": "note_upstream_unavailable", "cause": type(e).__name__},
                            status_code=502)
