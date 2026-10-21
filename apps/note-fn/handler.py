"""user17-hermes-note-fn: API Gateway HTTP API(payload v2) -> DynamoDB 오답노트·대화 저장/조회.

같은 테이블을 SK 접두사로 나눠 쓴다: 오답노트 SK = ISO 시각("20..."), 대화 SK = "conv#" + ISO 시각.
"""
import base64
import json
import logging
import os
import re
import sys
from datetime import datetime, timezone

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

DEFAULT_FUNCTION_NAME = "user17-hermes-note-fn"
TABLE_NAME = os.environ.get("TABLE_NAME", "user17-hermes-note-ddb")
MAX_FIELD = {"user_id": 64, "wrong": 1000, "correct": 1000, "memo": 2000}
CONV_PREFIX = "conv#"
NOTE_PREFIX = "20"            # 오답노트 SK(ISO 시각)는 "20xx-..." 로 시작
NICK_RE = re.compile(r"^[0-9A-Za-z가-힣_-]{2,20}$")  # 닉네임 = user_id (인증 아님, 학습자 구분용)
MAX_TURNS = 40
MAX_TURN_TEXT = 1000
TURN_KEYS = ("ko", "en", "pron")

# 콜드스타트 플래그: 새 실행 환경의 첫 호출만 True (복구 실험 증거용)
_COLD_START = True

# boto3 클라이언트는 모듈 전역: 웜 호출에서 재사용, 콜드스타트 때만 생성.
# DDB_ENDPOINT 가 있으면 로컬 DynamoDB (자격증명은 환경변수에 맡김).
# 짧은 타임아웃/재시도로 Lambda 10s 제한 안에서 500 을 확실히 반환.
_endpoint = os.environ.get("DDB_ENDPOINT")
_ddb = boto3.client(
    "dynamodb",
    endpoint_url=_endpoint or None,
    region_name=os.environ.get("AWS_REGION") or "ap-northeast-2",
    config=Config(connect_timeout=2, read_timeout=3, retries={"max_attempts": 2}),
)


def _resp(status, body):
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False),
    }


def _err(status, message, **extra):
    return _resp(status, {"error": message, **extra})


def _parse_body(event):
    raw = event.get("body")
    if raw is None or raw == "":
        raise ValueError("request body is required")
    if event.get("isBase64Encoded"):
        try:
            raw = base64.b64decode(raw).decode("utf-8")
        except Exception:
            raise ValueError("invalid base64 body")
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        raise ValueError("invalid JSON")
    if not isinstance(data, dict):
        raise ValueError("body must be a JSON object")
    return data


def _validate(data):
    """필수/타입/빈 문자열/길이 검증. 정제된 dict 반환, 실패 시 ValueError."""
    out = {}
    for key in ("user_id", "wrong", "correct"):
        v = data.get(key)
        if key not in data or v is None:
            raise ValueError(f"'{key}' is required")
        if not isinstance(v, str):
            raise ValueError(f"'{key}' must be a string")
        if not v.strip():
            raise ValueError(f"'{key}' must not be empty")
        out[key] = v
    memo = data.get("memo")
    if memo is not None:
        if not isinstance(memo, str):
            raise ValueError("'memo' must be a string")
        if memo.strip():
            out["memo"] = memo
    for key, v in out.items():
        if len(v) > MAX_FIELD[key]:
            raise ValueError(f"'{key}' exceeds {MAX_FIELD[key]} characters")
    return out


def _post_note(event, ctx_info):
    qs = event.get("queryStringParameters") or {}
    if qs.get("crash") == "1":
        # 복구 실험: 실행 환경을 강제 종료 -> 다음 호출은 새 환경(cold_start=true)에서 성공
        logger.error(json.dumps({"event": "crash_requested", **ctx_info}))
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(1)

    try:
        item = _validate(_parse_body(event))
    except ValueError as e:
        return _err(400, str(e), **ctx_info)

    # 마이크로초 포함 UTC ISO8601 -> 같은 사용자의 동시 저장 시 SK 충돌 방지
    item["created_at"] = datetime.now(timezone.utc).isoformat(timespec="microseconds")
    ddb_item = {k: {"S": v} for k, v in item.items()}
    try:
        _ddb.put_item(
            TableName=TABLE_NAME,
            Item=ddb_item,
            ConditionExpression="attribute_not_exists(created_at)",
        )
    except (ClientError, BotoCoreError) as e:
        logger.exception("ddb put_item failed")
        return _err(500, "failed to save note", error_type=type(e).__name__, **ctx_info)
    return _resp(201, {"saved": item, "function": ctx_info["function"],
                       "request_id": ctx_info["request_id"]})


def _get_notes(user_id, ctx_info):
    if not user_id or not user_id.strip() or len(user_id) > MAX_FIELD["user_id"]:
        return _err(400, "invalid user_id", **ctx_info)
    try:
        r = _ddb.query(
            TableName=TABLE_NAME,
            KeyConditionExpression="user_id = :u AND begins_with(created_at, :p)",
            ExpressionAttributeValues={":u": {"S": user_id}, ":p": {"S": NOTE_PREFIX}},
            ScanIndexForward=False,  # 최신순
            Limit=50,  # 응답 크기 상한 (앱 기능 최소)
        )
    except (ClientError, BotoCoreError) as e:
        logger.exception("ddb query failed")
        return _err(500, "failed to query notes", error_type=type(e).__name__, **ctx_info)
    items = [{k: v["S"] for k, v in it.items() if "S" in v} for it in r.get("Items", [])]
    return _resp(200, {"user_id": user_id, "count": len(items), "items": items,
                       "function": ctx_info["function"], "request_id": ctx_info["request_id"]})


def _validate_conversation(data):
    """대화 저장 요청 검증. {user_id, topic?, turns:[{role, ko?, en?, pron?}]}"""
    uid = data.get("user_id")
    if not isinstance(uid, str) or not NICK_RE.match(uid):
        raise ValueError("'user_id' must be 2-20 chars of letters, digits, Korean, _ or -")
    topic = data.get("topic") or ""
    if not isinstance(topic, str) or len(topic) > 40:
        raise ValueError("'topic' must be a string up to 40 chars")
    turns = data.get("turns")
    if not isinstance(turns, list) or not turns or len(turns) > MAX_TURNS:
        raise ValueError(f"'turns' must be a list of 1-{MAX_TURNS} items")
    clean = []
    for t in turns:
        if not isinstance(t, dict) or t.get("role") not in ("user", "assistant"):
            raise ValueError("each turn needs role 'user' or 'assistant'")
        c = {"role": t["role"]}
        for k in TURN_KEYS:
            v = t.get(k)
            if v is None:
                continue
            if not isinstance(v, str) or len(v) > MAX_TURN_TEXT:
                raise ValueError(f"turn '{k}' must be a string up to {MAX_TURN_TEXT} chars")
            c[k] = v
        if not any(c.get(k, "").strip() for k in TURN_KEYS):
            raise ValueError("each turn needs at least one of ko/en/pron")
        clean.append(c)
    first_user = next((t for t in clean if t["role"] == "user"), clean[0])
    title = (first_user.get("ko") or first_user.get("en") or "")[:40]
    return uid, topic, title, clean


def _post_conversation(event, ctx_info):
    try:
        uid, topic, title, turns = _validate_conversation(_parse_body(event))
    except ValueError as e:
        return _err(400, str(e), **ctx_info)
    created = datetime.now(timezone.utc).isoformat(timespec="microseconds")
    item = {"user_id": uid, "created_at": CONV_PREFIX + created, "topic": topic, "title": title,
            "turn_count": str(len(turns)), "turns": json.dumps(turns, ensure_ascii=False)}
    try:
        _ddb.put_item(TableName=TABLE_NAME, Item={k: {"S": v} for k, v in item.items()},
                      ConditionExpression="attribute_not_exists(created_at)")
    except (ClientError, BotoCoreError) as e:
        logger.exception("ddb put_item failed (conversation)")
        return _err(500, "failed to save conversation", error_type=type(e).__name__, **ctx_info)
    summary = {k: item[k] for k in ("user_id", "created_at", "topic", "title", "turn_count")}
    return _resp(201, {"saved": summary, "function": ctx_info["function"],
                       "request_id": ctx_info["request_id"]})


def _get_conversations(user_id, ctx_info):
    if not user_id or not NICK_RE.match(user_id):
        return _err(400, "invalid user_id", **ctx_info)
    try:
        r = _ddb.query(
            TableName=TABLE_NAME,
            KeyConditionExpression="user_id = :u AND begins_with(created_at, :p)",
            ExpressionAttributeValues={":u": {"S": user_id}, ":p": {"S": CONV_PREFIX}},
            ScanIndexForward=False,
            Limit=10,  # 최근 10개 대화만
        )
    except (ClientError, BotoCoreError) as e:
        logger.exception("ddb query failed (conversation)")
        return _err(500, "failed to query conversations", error_type=type(e).__name__, **ctx_info)
    items = []
    for it in r.get("Items", []):
        row = {k: v["S"] for k, v in it.items() if "S" in v}
        try:
            row["turns"] = json.loads(row.get("turns", "[]"))
        except ValueError:
            row["turns"] = []
        items.append(row)
    return _resp(200, {"user_id": user_id, "count": len(items), "items": items,
                       "function": ctx_info["function"], "request_id": ctx_info["request_id"]})


def lambda_handler(event, context):
    global _COLD_START
    cold = _COLD_START
    _COLD_START = False

    ctx_info = {
        "function": getattr(context, "function_name", None) or DEFAULT_FUNCTION_NAME,
        "request_id": getattr(context, "aws_request_id", None),
    }
    try:
        http = (event.get("requestContext") or {}).get("http") or {}
        method = (http.get("method") or "").upper()
        path = event.get("rawPath") or http.get("path") or ""
        logger.info(json.dumps({"event": "request", "cold_start": cold, "method": method,
                                "path": path, **ctx_info}))

        parts = [p for p in path.split("/") if p]
        if parts[:1] not in (["notes"], ["conversations"]) or len(parts) > 2:
            return _err(404, "not found", **ctx_info)
        is_conv = parts[0] == "conversations"
        if len(parts) == 1:
            if method == "POST":
                return _post_conversation(event, ctx_info) if is_conv else _post_note(event, ctx_info)
            return _err(405, "method not allowed", **ctx_info)
        if method == "GET":
            uid = (event.get("pathParameters") or {}).get("user_id") or parts[1]
            return _get_conversations(uid, ctx_info) if is_conv else _get_notes(uid, ctx_info)
        return _err(405, "method not allowed", **ctx_info)
    except Exception:
        # 예상 못한 오류도 항상 JSON 500 (프록시 통합의 502 방지)
        logger.exception("unhandled error")
        return _err(500, "internal error", **ctx_info)
