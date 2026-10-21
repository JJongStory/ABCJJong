FROM python:3.12-slim

# 로그 즉시 flush, pyc 미생성(읽기 전용 루트FS 대비)
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY app.py llm.py ./
COPY static/ ./static/

# 비루트 실행: K8s runAsNonRoot 검증을 위해 숫자 UID 사용
RUN useradd --system --uid 10001 --no-create-home appuser
USER 10001

EXPOSE 8000
# HEALTHCHECK 없음: 상태 확인은 K8s liveness/readiness probe(/health)가 담당
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
