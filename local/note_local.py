"""로컬 전용 어댑터: 일반 HTTP 요청 -> API Gateway HTTP API(payload v2) 이벤트 -> handler.lambda_handler.

Lambda 자체는 수정하지 않고 같은 handler 코드를 그대로 호출한다 (로컬/클라우드 코드 동일).
- 테이블은 기동 시 자동 생성 (DynamoDB Local 은 매번 비어 있음).
- ?crash=1 은 handler 가 os._exit(1) 로 프로세스를 죽인다 -> compose 의 restart: always 가
  '새 실행 환경' 역할을 한다 (Lambda 가 새 환경을 띄우는 것과 같은 복구 리허설).
"""
import json
import os
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

import boto3
from botocore.exceptions import ClientError

sys.path.insert(0, os.environ.get("HANDLER_DIR", "/app"))

TABLE = os.environ.setdefault("TABLE_NAME", "hermes-prd-note-ddb")
os.environ.setdefault("AWS_REGION", "ap-northeast-2")
os.environ.setdefault("AWS_DEFAULT_REGION", os.environ["AWS_REGION"])


def ensure_table():
    ddb = boto3.client("dynamodb", endpoint_url=os.environ["DDB_ENDPOINT"])
    for attempt in range(30):  # dynamodb-local 이 늦게 뜰 수 있어 재시도
        try:
            ddb.create_table(
                TableName=TABLE,
                AttributeDefinitions=[
                    {"AttributeName": "user_id", "AttributeType": "S"},
                    {"AttributeName": "created_at", "AttributeType": "S"},
                ],
                KeySchema=[
                    {"AttributeName": "user_id", "KeyType": "HASH"},
                    {"AttributeName": "created_at", "KeyType": "RANGE"},
                ],
                BillingMode="PAY_PER_REQUEST",
            )
            print(f"table created: {TABLE}", flush=True)
            return
        except ClientError as e:
            if e.response["Error"]["Code"] == "ResourceInUseException":
                return
            print(f"ensure_table retry {attempt}: {e}", flush=True)
        except Exception as e:  # 연결 거부 등
            print(f"ensure_table retry {attempt}: {e}", flush=True)
        time.sleep(1)
    raise SystemExit("dynamodb-local not reachable")


class Context:
    function_name = "hermes-prd-note-fn"

    def __init__(self):
        self.aws_request_id = str(uuid.uuid4())


class Adapter(BaseHTTPRequestHandler):
    def _dispatch(self):
        import handler  # ensure_table 이후 import (Lambda 콜드스타트와 동일하게 첫 호출 때 로드)

        u = urlparse(self.path)
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length).decode() if length else None
        ctx = Context()
        event = {
            "version": "2.0",
            "routeKey": "$default",
            "rawPath": u.path,
            "rawQueryString": u.query,
            "queryStringParameters": {
                k: v for k, _, v in (p.partition("=") for p in u.query.split("&") if p)
            } or None,
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "requestContext": {
                "http": {"method": self.command, "path": u.path},
                "requestId": ctx.aws_request_id,
            },
            "body": body,
            "isBase64Encoded": False,
        }
        parts = [p for p in u.path.split("/") if p]
        if len(parts) == 2 and parts[0] == "notes":  # API GW 의 {user_id} 경로 매핑 흉내
            event["pathParameters"] = {"user_id": parts[1]}
        res = handler.lambda_handler(event, ctx)
        payload = (res.get("body") or "").encode()
        self.send_response(res.get("statusCode", 200))
        for k, v in (res.get("headers") or {}).items():
            self.send_header(k, v)
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST = do_PUT = do_DELETE = _dispatch

    def log_message(self, fmt, *args):
        print("note-local:", fmt % args, flush=True)


if __name__ == "__main__":
    ensure_table()
    port = int(os.environ.get("PORT", "9000"))
    print(f"note-local listening on :{port}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Adapter).serve_forever()
