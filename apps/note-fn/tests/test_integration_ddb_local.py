"""DDB_ENDPOINT(amazon/dynamodb-local) 가 지정된 경우에만 실행."""
import importlib
import json
import os
import time

import boto3
import pytest

ENDPOINT = os.environ.get("DDB_ENDPOINT")
pytestmark = pytest.mark.skipif(not ENDPOINT, reason="DDB_ENDPOINT not set")


class Ctx:
    function_name = "user17-hermes-note-fn"
    aws_request_id = "int-1"


@pytest.fixture(scope="module")
def h():
    table = f"hermes-test-note-{int(time.time())}"
    os.environ["TABLE_NAME"] = table
    import handler
    importlib.reload(handler)  # 모듈 전역 클라이언트/테이블명을 새 환경으로 재생성
    c = boto3.client("dynamodb", endpoint_url=ENDPOINT,
                     region_name=os.environ.get("AWS_REGION", "ap-northeast-2"))
    c.create_table(
        TableName=table, BillingMode="PAY_PER_REQUEST",
        AttributeDefinitions=[{"AttributeName": "user_id", "AttributeType": "S"},
                              {"AttributeName": "created_at", "AttributeType": "S"}],
        KeySchema=[{"AttributeName": "user_id", "KeyType": "HASH"},
                   {"AttributeName": "created_at", "KeyType": "RANGE"}])
    yield handler
    c.delete_table(TableName=table)


def _ev(method, path, body=None, params=None):
    return {"requestContext": {"http": {"method": method}}, "rawPath": path,
            "body": json.dumps(body) if body is not None else None,
            "pathParameters": params, "queryStringParameters": None}


def test_put_then_query_newest_first(h):
    for i in range(3):
        r = h.lambda_handler(_ev("POST", "/notes", {"user_id": "u1", "wrong": f"w{i}",
                                                    "correct": f"c{i}", "memo": "m"}), Ctx())
        assert r["statusCode"] == 201
    h.lambda_handler(_ev("POST", "/notes", {"user_id": "u2", "wrong": "x", "correct": "y"}), Ctx())
    r = h.lambda_handler(_ev("GET", "/notes/u1", params={"user_id": "u1"}), Ctx())
    b = json.loads(r["body"])
    assert r["statusCode"] == 200 and b["count"] == 3
    assert [i["wrong"] for i in b["items"]] == ["w2", "w1", "w0"]


def test_query_empty(h):
    b = json.loads(h.lambda_handler(_ev("GET", "/notes/none", params={"user_id": "none"}), Ctx())["body"])
    assert b["count"] == 0 and b["items"] == []
