import os
import sys

# handler.py 는 apps/note-fn/ 바로 아래에 있다
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# 단위테스트가 실제 AWS 로 나가지 않도록 더미 리전만 지정 (자격증명은 넣지 않음)
os.environ.setdefault("AWS_DEFAULT_REGION", "ap-northeast-2")
