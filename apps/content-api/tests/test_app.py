import os
import urllib.error

import pytest
from fastapi.testclient import TestClient

import app as appmod

client = TestClient(appmod.app)

# DB 테스트용 접속 정보(없으면 skip): TEST_DB_HOST, TEST_DB_PORT, TEST_DB_USER, TEST_DB_PASSWORD, TEST_DB_NAME
HAS_DB = bool(os.environ.get("TEST_DB_HOST"))
needs_db = pytest.mark.skipif(not HAS_DB, reason="TEST_DB_HOST 미설정: DB 테스트 skip")


@pytest.fixture(autouse=True)
def reset_state(monkeypatch):
    monkeypatch.setattr(appmod, "_initialized", False)
    monkeypatch.setattr(appmod, "_creds", None)
    monkeypatch.delenv("DB_SECRET_ARN", raising=False)


def test_health_ok_without_db():
    r = client.get("/health")
    assert r.status_code == 200 and r.json() == {"status": "ok"}


def test_az_local_when_imds_fails(monkeypatch):
    def boom(*a, **k):
        raise urllib.error.URLError("no imds")
    monkeypatch.setattr(appmod.urllib.request, "urlopen", boom)
    assert appmod.get_az() == "local"


def test_az_from_imdsv2(monkeypatch):
    class R:
        def __init__(self, b): self.b = b
        def read(self): return self.b
    calls = []
    def fake(req, timeout=None):
        calls.append((req.get_method(), req.full_url))
        return R(b"tok" if req.get_method() == "PUT" else b"ap-northeast-2a")
    monkeypatch.setattr(appmod.urllib.request, "urlopen", fake)
    assert appmod.get_az() == "ap-northeast-2a"
    assert calls[0][0] == "PUT"


def test_503_when_db_down(monkeypatch):
    monkeypatch.setenv("DB_HOST", "127.0.0.1")
    monkeypatch.setenv("DB_PORT", "1")  # 닫힌 포트
    for path in ("/", "/scenarios", "/scenarios/1"):
        r = client.get(path)
        assert r.status_code == 503, path
        assert "database unavailable" in r.json()["detail"]
    assert client.get("/health").status_code == 200


def test_503_when_secret_lookup_fails(monkeypatch):
    monkeypatch.setenv("DB_SECRET_ARN", "arn:aws:secretsmanager:ap-northeast-2:000000000000:secret:x")
    monkeypatch.setenv("AWS_REGION", "ap-northeast-2")
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "x")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "x")
    monkeypatch.setenv("AWS_ENDPOINT_URL", "http://127.0.0.1:1")
    assert client.get("/scenarios").status_code == 503


@pytest.fixture
def dbenv(monkeypatch):
    monkeypatch.setenv("DB_HOST", os.environ["TEST_DB_HOST"])
    monkeypatch.setenv("DB_PORT", os.environ.get("TEST_DB_PORT", "3306"))
    monkeypatch.setenv("DB_USER", os.environ.get("TEST_DB_USER", "root"))
    monkeypatch.setenv("DB_PASSWORD", os.environ.get("TEST_DB_PASSWORD", ""))
    monkeypatch.setenv("DB_NAME", os.environ.get("TEST_DB_NAME", "hermes"))


@needs_db
def test_db_seed_and_endpoints(dbenv):
    r = client.get("/scenarios")
    assert r.status_code == 200
    rows = r.json()
    assert len(rows) >= 3
    assert set(rows[0]) == {"id", "topic", "level", "opener_en", "opener_ko"}
    one = client.get("/scenarios/%d" % rows[0]["id"])
    assert one.status_code == 200 and one.json() == rows[0]
    assert client.get("/scenarios/999999").status_code == 404
    root = client.get("/").json()
    assert root["service"] == "content-api" and root["sample"]["id"] == rows[0]["id"]
    assert root["az"] == "local" and root["hostname"]


@needs_db
def test_init_idempotent(dbenv):
    n1 = len(client.get("/scenarios").json())
    appmod._initialized = False  # 재기동 시뮬레이션
    n2 = len(client.get("/scenarios").json())
    assert n1 == n2
