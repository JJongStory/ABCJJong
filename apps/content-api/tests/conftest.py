import os
import sys

# apps/content-api 를 import 경로에 추가 (app.py 를 최상위 모듈로 import)
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# 테스트에서 startup 백그라운드 DB 재시도 스레드 비활성
os.environ.setdefault("SKIP_DB_INIT", "1")
