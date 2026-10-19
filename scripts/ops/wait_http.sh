#!/usr/bin/env bash
# 사용법: wait_http.sh URL [기대문자열] [timeout초=600]
# URL 이 200 이고(기대문자열이 있으면 본문에 포함) 될 때까지 1초 간격 폴링한다.
# 성공: "OK <초>s (failures=N)" 출력, exit 0 / 타임아웃: exit 1
# failures = 성공 전까지의 실패 횟수. 재배포 중 0 이 아니면 무중단이 아니었다는 단서가 된다.
set -uo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 URL [expected-string] [timeout-sec=600]" >&2
  exit 2
fi
url=$1
expect=${2:-}
timeout=${3:-600}

body=$(mktemp)
trap 'rm -f "$body"' EXIT

start=$SECONDS
failures=0
echo "[wait_http] GET $url expect='${expect}' timeout=${timeout}s"

while true; do
  # --max-time: 응답 없는 대상에서 폴링이 멈추지 않게 한다
  code=$(curl -sS -o "$body" -w '%{http_code}' --connect-timeout 2 --max-time 5 "$url" 2>/dev/null || true)
  if [[ $code == 200 ]] && { [[ -z $expect ]] || grep -qF -- "$expect" "$body"; }; then
    echo "OK $((SECONDS - start))s (failures=${failures})"
    exit 0
  fi
  failures=$((failures + 1))
  if ((SECONDS - start >= timeout)); then
    echo "TIMEOUT ${timeout}s (failures=${failures}, last_http=${code:-000})" >&2
    exit 1
  fi
  sleep 1
done
