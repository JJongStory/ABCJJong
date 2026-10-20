import base64
import json
import types

import pytest

import handler


class Ctx:
    function_name = "hermes-prd-note-fn"
    aws_request_id = "req-1"


class FakeDDB:
    def __init__(self):
        self.puts, self.queries = [], []

    def put_item(self, **kw):
        self.puts.append(kw)

    def query(self, **kw):
        self.queries.append(kw)
        return {"Items": [{"user_id": {"S": "u"}, "created_at": {"S": "t"},
                           "wrong": {"S": "a"}, "correct": {"S": "b"}}]}


@pytest.fixture
def ddb(monkeypatch):
    f = FakeDDB()
    monkeypatch.setattr(handler, "_ddb", f)
    return f


def ev(method, path, body=None, qs=None, params=None, b64=False):
    if body is not None and not isinstance(body, str):
        body = json.dumps(body)
    if b64 and body is not None:
        body = base64.b64encode(body.encode()).decode()
    return {"requestContext": {"http": {"method": method}}, "rawPath": path, "body": body,
            "isBase64Encoded": b64, "queryStringParameters": qs, "pathParameters": params}


def call(e):
    r = handler.lambda_handler(e, Ctx())
    assert r["headers"]["content-type"] == "application/json"
    return r["statusCode"], json.loads(r["body"])


GOOD = {"user_id": "u1", "wrong": "go", "correct": "went"}


def test_post_ok(ddb):
    s, b = call(ev("POST", "/notes", GOOD))
    assert s == 201 and b["function"] == "hermes-prd-note-fn" and b["request_id"] == "req-1"
    assert b["saved"]["created_at"].endswith("+00:00") and "." in b["saved"]["created_at"]
    assert ddb.puts[0]["Item"]["user_id"] == {"S": "u1"}


def test_post_base64_and_memo(ddb):
    s, b = call(ev("POST", "/notes", {**GOOD, "memo": "m"}, b64=True))
    assert s == 201 and b["saved"]["memo"] == "m"


@pytest.mark.parametrize("body", [
    {"wrong": "a", "correct": "b"}, {**GOOD, "wrong": 1}, {**GOOD, "correct": "  "},
    {**GOOD, "user_id": "x" * 65}, {**GOOD, "memo": 3}, {**GOOD, "wrong": "x" * 1001}, [1],
])
def test_post_validation(ddb, body):
    s, b = call(ev("POST", "/notes", body))
    assert s == 400 and "error" in b and not ddb.puts


def test_post_bad_json_and_empty(ddb):
    assert call(ev("POST", "/notes", "{bad"))[0] == 400
    assert call(ev("POST", "/notes", None))[0] == 400


def test_get(ddb):
    s, b = call(ev("GET", "/notes/u", params={"user_id": "u"}))
    assert s == 200 and b["count"] == 1 and b["user_id"] == "u"
    assert ddb.queries[0]["ScanIndexForward"] is False


def test_routing(ddb):
    assert call(ev("GET", "/nope"))[0] == 404
    assert call(ev("GET", "/notes"))[0] == 405
    assert call(ev("DELETE", "/notes/u"))[0] == 405
    assert call(ev("GET", "/notes/a/b"))[0] == 404


def test_ddb_error_500(monkeypatch):
    from botocore.exceptions import ClientError

    class Boom:
        def put_item(self, **kw):
            raise ClientError({"Error": {"Code": "X", "Message": "m"}}, "PutItem")

        def query(self, **kw):
            raise ClientError({"Error": {"Code": "X", "Message": "m"}}, "Query")

    monkeypatch.setattr(handler, "_ddb", Boom())
    assert call(ev("POST", "/notes", GOOD))[0] == 500
    assert call(ev("GET", "/notes/u"))[0] == 500


def test_crash(ddb, monkeypatch):
    class Exited(BaseException):  # 실제 _exit 는 복귀하지 않으므로 catch-all(Exception)에 안 잡히게
        pass

    codes = []

    def fake_exit(c):
        codes.append(c)
        raise Exited

    monkeypatch.setattr(handler.os, "_exit", fake_exit)
    with pytest.raises(Exited):
        handler.lambda_handler(ev("POST", "/notes", GOOD, qs={"crash": "1"}), Ctx())
    assert codes == [1] and not ddb.puts


def test_cold_start_flag(ddb, caplog):
    handler._COLD_START = True
    with caplog.at_level("INFO"):
        call(ev("GET", "/notes/u"))
        call(ev("GET", "/notes/u"))
    logs = [json.loads(r.getMessage()) for r in caplog.records if r.getMessage().startswith("{")]
    assert [l["cold_start"] for l in logs if l["event"] == "request"] == [True, False]


def test_no_context_defaults(ddb):
    r = handler.lambda_handler(ev("GET", "/notes/u"), types.SimpleNamespace())
    assert json.loads(r["body"])["function"] == "hermes-prd-note-fn"
