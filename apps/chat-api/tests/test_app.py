import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest
from fastapi.testclient import TestClient

import app as app_module
import llm

CHAT_KEYS = {"input_en", "input_pron", "reply_en", "reply_pron", "reply_ko", "topic", "llm_provider"}


class _Upstream(BaseHTTPRequestHandler):
    def do_GET(self):
        routes = {
            "/": {"service": "content-api", "hostname": "ip-10-0-16-5"},
            "/scenarios": [{"id": 1, "topic": "cafe", "level": "beginner",
                            "opener_en": "Hi", "opener_ko": "안녕"}],
            "/scenarios/1": {"id": 1, "topic": "cafe"},
        }
        if self.path in routes:
            body = json.dumps(routes[self.path]).encode()
            self.send_response(200)
        else:
            body = b"{}"
            self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


@pytest.fixture(scope="module")
def upstream_url():
    srv = HTTPServer(("127.0.0.1", 0), _Upstream)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{srv.server_port}"
    srv.shutdown()


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("LLM_PROVIDER", "stub")
    monkeypatch.setenv("HOSTNAME", "chat-api-test-pod")
    return TestClient(app_module.app, raise_server_exceptions=False)


def test_health(client):
    assert client.get("/health").json() == {"status": "ok"}


def test_root(client):
    j = client.get("/").json()
    assert j["service"] == "chat-api" and j["pod"] == "chat-api-test-pod"
    assert j["llm_provider"] == "stub" and "version" in j


def test_chat_stub_seven_fields(client):
    r = client.post("/chat", json={"message": "커피 주세요", "history": []})
    assert r.status_code == 200
    j = r.json()
    assert set(j) == CHAT_KEYS
    assert j["llm_provider"] == "stub"


def test_chat_validation(client):
    assert client.post("/chat", json={"message": ""}).status_code == 422


def test_history_truncated_to_last_6(client, monkeypatch):
    seen = {}

    def fake(name, message, history, topic_hint=None):
        seen["h"] = history
        return llm.StubProvider().generate(message, history), "stub"

    monkeypatch.setattr(llm, "chat_with_fallback", fake)
    hist = [{"role": "user" if i % 2 == 0 else "assistant", "content": f"m{i}"} for i in range(10)]
    assert client.post("/chat", json={"message": "안녕", "history": hist}).status_code == 200
    assert [h["content"] for h in seen["h"]] == [f"m{i}" for i in range(4, 10)]


def test_chat_unknown_provider_falls_back(client, monkeypatch):
    monkeypatch.setenv("LLM_PROVIDER", "nope")
    j = client.post("/chat", json={"message": "안녕"}).json()
    assert j["llm_provider"] == "stub(fallback)" and set(j) == CHAT_KEYS


def test_chat_with_scenario_topic(client, monkeypatch, upstream_url):
    monkeypatch.setenv("CONTENT_API_URL", upstream_url)
    j = client.post("/chat", json={"message": "안녕", "scenario_id": 1}).json()
    assert j["topic"] == "cafe"


def test_scenario_ok(client, monkeypatch, upstream_url):
    monkeypatch.setenv("CONTENT_API_URL", upstream_url + "/")
    j = client.get("/scenario").json()
    assert j["pod"] == "chat-api-test-pod" and j["upstream"] == "content-api"
    assert j["upstream_hostname"] == "ip-10-0-16-5"
    assert j["data"][0]["topic"] == "cafe"


def test_scenario_502_unreachable(client, monkeypatch):
    monkeypatch.setenv("CONTENT_API_URL", "http://127.0.0.1:1")  # 연결 거부
    r = client.get("/scenario")
    assert r.status_code == 502 and r.json()["cause"]


def test_scenario_502_not_configured(client, monkeypatch):
    monkeypatch.delenv("CONTENT_API_URL", raising=False)
    r = client.get("/scenario")
    assert r.status_code == 502 and "not set" in r.json()["cause"]


def test_scenario_502_upstream_http_error(client, monkeypatch, upstream_url):
    monkeypatch.setenv("CONTENT_API_URL", upstream_url + "/missing")  # /missing/scenarios → 404
    r = client.get("/scenario")
    assert r.status_code == 502 and "404" in r.json()["cause"]


def test_note_not_configured(client, monkeypatch):
    monkeypatch.delenv("NOTE_API_URL", raising=False)
    assert client.post("/note", json={"user_id": "u"}).status_code == 503
