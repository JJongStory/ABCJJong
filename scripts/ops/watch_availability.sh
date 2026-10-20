#!/usr/bin/env bash
# 사용법: watch_availability.sh URL [간격초=1]   (재배포/복구 중 백그라운드로: `... &`, 끝나면 kill 또는 Ctrl-C)
# 시각, HTTP 코드, 응답시간(ms)을 csv 로 남겨 200 / 비200 타임라인(무중단 증명)을 만든다.
# 출력 파일: $OUT (기본 docs/availability-<UTC시각>.csv). 종료 시 요약(총 횟수, 비200 횟수, 최장 연속 실패)을 출력한다.
set -uo pipefail

[[ $# -ge 1 ]] || {
  echo "usage: $0 URL [interval-sec=1]" >&2
  exit 2
}
url=$1
interval=${2:-1}

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out=${OUT:-$root/docs/availability-$(date -u +%Y%m%dT%H%M%SZ).csv}
mkdir -p "$(dirname "$out")"
echo "ts_iso,http_code,latency_ms" >"$out"

total=0 bad=0 streak=0 max_streak=0

summary() {
  echo "[watch] total=$total non200=$bad max_consecutive_fail=$max_streak -> ${out#"$root"/}"
  exit 0
}
trap summary INT TERM

echo "[watch] $url every ${interval}s -> ${out#"$root"/}"
while true; do
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # code 와 시간을 한 번에: 연결 실패 시 000
  res=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --connect-timeout 2 --max-time 5 "$url" 2>/dev/null || true)
  code=${res%% *}
  [[ -n $code ]] || code=000
  secs=${res#* }
  [[ $res == *" "* ]] || secs=0
  ms=$(awk -v t="$secs" 'BEGIN{printf "%d", t*1000}')
  echo "$ts,$code,$ms" >>"$out"
  total=$((total + 1))
  if [[ $code == 200 ]]; then
    streak=0
  else
    bad=$((bad + 1))
    streak=$((streak + 1))
    ((streak > max_streak)) && max_streak=$streak
  fi
  sleep "$interval"
done
