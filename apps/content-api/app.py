"""content-api (워크로드 A). FastAPI + PyMySQL.

설계 원칙:
- /health 는 DB와 무관하게 200 (ALB 헬스체크·프로세스 생존 확인용).
- DB가 늦게 떠도 프로세스는 죽지 않는다: 기동 시 백그라운드 재시도 + 요청 시 재연결/재초기화.
- 비밀번호는 env 에 두지 않고 Secrets Manager 에서 조회(DB_SECRET_ARN). 로컬용 DB_USER/DB_PASSWORD 는 대체 경로.
"""
import json
import logging
import os
import socket
import threading
import time
import urllib.request
from contextlib import contextmanager
from typing import Any, Dict, Iterator, List, Optional

import pymysql
import pymysql.cursors
from fastapi import FastAPI, HTTPException

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                    format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("content-api")

APP_VERSION = os.environ.get("APP_VERSION", "dev")
DB_CONNECT_TIMEOUT = 3      # DB 장애가 요청을 오래 붙잡지 않도록 짧게
IMDS_TIMEOUT = 1            # 로컬/비EC2 에서 빨리 "local" 로 폴백
IMDS_BASE = "http://169.254.169.254/latest"

CREATE_SQL = """
CREATE TABLE IF NOT EXISTS scenarios (
  id INT AUTO_INCREMENT PRIMARY KEY,
  topic VARCHAR(100) NOT NULL,
  level VARCHAR(20) NOT NULL,
  opener_en TEXT NOT NULL,
  opener_ko TEXT NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
"""

SEEDS = [
    ("cafe", "beginner",
     "Hi! Welcome in. What can I get for you today?",
     "안녕하세요! 어서 오세요. 오늘 무엇을 드릴까요?"),
    ("airport", "intermediate",
     "Good morning. May I see your passport and boarding pass, please?",
     "안녕하세요. 여권과 탑승권을 보여주시겠어요?"),
    ("small-talk", "beginner",
     "Hey! How's your day going so far?",
     "안녕! 오늘 하루 어때?"),
]

COLUMNS = "id, topic, level, opener_en, opener_ko"

_creds_lock = threading.Lock()
_creds: Optional[Dict[str, str]] = None
_init_lock = threading.Lock()
_initialized = False


class DBUnavailable(Exception):
    """DB 접속/조회 실패. 엔드포인트에서 503 으로 변환."""


def _load_creds() -> Dict[str, str]:
    """Secrets Manager(RDS 관리형 시크릿 {"username","password"}) 또는 로컬 env. 성공 시 캐시."""
    global _creds
    with _creds_lock:
        if _creds:
            return _creds
        arn = os.environ.get("DB_SECRET_ARN")
        if arn:
            import boto3  # 로컬 테스트에서 불필요한 import 비용 회피
            from botocore.config import Config
            client = boto3.client(
                "secretsmanager", region_name=os.environ.get("AWS_REGION"),
                config=Config(connect_timeout=3, read_timeout=5, retries={"max_attempts": 2}))
            secret = json.loads(client.get_secret_value(SecretId=arn)["SecretString"])
            _creds = {"user": secret["username"], "password": secret["password"]}
        else:
            _creds = {"user": os.environ.get("DB_USER", "hermes_admin"),
                      "password": os.environ.get("DB_PASSWORD", "")}
        return _creds


def _connect() -> pymysql.connections.Connection:
    try:
        c = _load_creds()
        # Terraform 의 rds_endpoint 는 "host:3306" 형태일 수 있어 둘 다 허용
        host, _, port = os.environ.get("DB_HOST", "127.0.0.1").partition(":")
        return pymysql.connect(
            host=host,
            port=int(port or os.environ.get("DB_PORT", "3306")),
            user=c["user"], password=c["password"],
            database=os.environ.get("DB_NAME", "hermes"),
            charset="utf8mb4", cursorclass=pymysql.cursors.DictCursor,
            connect_timeout=DB_CONNECT_TIMEOUT, read_timeout=5, write_timeout=5,
            autocommit=True)
    except Exception as e:  # 시크릿 조회 실패·접속 실패 모두 동일하게 취급
        raise DBUnavailable("%s: %s" % (type(e).__name__, e)) from e


def _init_schema(conn: pymysql.connections.Connection) -> None:
    """CREATE TABLE IF NOT EXISTS + 비어 있을 때만 seed (멱등)."""
    global _initialized
    with _init_lock:
        if _initialized:
            return
        with conn.cursor() as cur:
            cur.execute(CREATE_SQL)
            cur.execute("SELECT COUNT(*) AS n FROM scenarios")
            if cur.fetchone()["n"] == 0:
                cur.executemany(
                    "INSERT INTO scenarios (topic, level, opener_en, opener_ko) VALUES (%s,%s,%s,%s)", SEEDS)
                log.info("seeded %d scenarios", len(SEEDS))
        _initialized = True
        log.info("db schema ready")


@contextmanager
def db() -> Iterator[pymysql.connections.Connection]:
    conn = _connect()
    try:
        if not _initialized:  # 기동 시 init 실패했어도 첫 성공 요청에서 보충
            try:
                _init_schema(conn)
            except pymysql.MySQLError as e:
                raise DBUnavailable("init: %s" % e) from e
        yield conn
    except pymysql.MySQLError as e:
        raise DBUnavailable("%s: %s" % (type(e).__name__, e)) from e
    finally:
        conn.close()


def _init_with_retry() -> None:
    """기동 시 백그라운드 재시도. 실패해도 프로세스는 유지."""
    delay = 2
    while not _initialized:
        try:
            with db():
                pass
        except Exception as e:
            log.warning("db init failed, retry in %ss: %s", delay, e)
            time.sleep(delay)
            delay = min(delay * 2, 30)


def get_az() -> str:
    """IMDSv2: 토큰 PUT → placement/availability-zone. 실패 시 "local"."""
    try:
        req = urllib.request.Request(
            IMDS_BASE + "/api/token", method="PUT",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"})
        token = urllib.request.urlopen(req, timeout=IMDS_TIMEOUT).read().decode()
        req2 = urllib.request.Request(
            IMDS_BASE + "/meta-data/placement/availability-zone",
            headers={"X-aws-ec2-metadata-token": token})
        return urllib.request.urlopen(req2, timeout=IMDS_TIMEOUT).read().decode().strip()
    except Exception:
        return "local"


app = FastAPI(title="content-api", version=APP_VERSION)


@app.on_event("startup")
def _startup() -> None:
    if os.environ.get("SKIP_DB_INIT") != "1":
        threading.Thread(target=_init_with_retry, daemon=True).start()


def _fail(e: DBUnavailable) -> HTTPException:
    # 원인(호스트명·예외 메시지)은 로그에만. 외부 ALB 로 공개되는 응답에는 일반 문구만 (T6)
    log.error("db unavailable: %s", e)
    return HTTPException(status_code=503, detail="database unavailable")


@app.get("/health")
def health() -> Dict[str, str]:
    return {"status": "ok"}


@app.get("/")
def root() -> Dict[str, Any]:
    try:
        with db() as conn, conn.cursor() as cur:
            cur.execute("SELECT %s FROM scenarios ORDER BY id LIMIT 1" % COLUMNS)
            sample = cur.fetchone()
    except DBUnavailable as e:
        raise _fail(e)
    return {"service": "content-api", "version": APP_VERSION,
            "hostname": socket.gethostname(), "az": get_az(), "sample": sample}


@app.get("/scenarios")
def list_scenarios() -> List[Dict[str, Any]]:
    try:
        with db() as conn, conn.cursor() as cur:
            cur.execute("SELECT %s FROM scenarios ORDER BY id" % COLUMNS)
            return list(cur.fetchall())
    except DBUnavailable as e:
        raise _fail(e)


@app.get("/scenarios/{scenario_id}")
def get_scenario(scenario_id: int) -> Dict[str, Any]:
    try:
        with db() as conn, conn.cursor() as cur:
            cur.execute("SELECT %s FROM scenarios WHERE id=%%s" % COLUMNS, (scenario_id,))
            row = cur.fetchone()
    except DBUnavailable as e:
        raise _fail(e)
    if row is None:
        raise HTTPException(status_code=404, detail="scenario not found")
    return row
