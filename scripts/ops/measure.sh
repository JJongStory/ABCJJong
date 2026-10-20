#!/usr/bin/env bash
# 사용법: measure.sh <env: vm|container|serverless|shared> <op: deploy|redeploy|recover|scale|기타> -- <명령...>
# 명령을 먼저 echo(캡처용)한 뒤 실행하고, 시작/종료 시각·소요초·exit code 를 docs/ops-matrix.csv 에 append 한다.
# 측정 정의는 docs/ops-matrix.md 참고: "명령 입력 ~ 외부 URL 이 새 상태로 응답"이 되도록 명령에 wait_http.sh 를 포함시킨다.
set -uo pipefail

usage() {
  echo "usage: $0 <vm|container|serverless|shared> <op> -- <command...>" >&2
  exit 2
}

[[ $# -ge 4 ]] || usage
env_name=$1
op=$2
shift 2
[[ $1 == -- ]] || usage
shift
[[ $# -ge 1 ]] || usage

case $env_name in
  vm | container | serverless | shared) ;;
  *)
    echo "env must be one of: vm container serverless shared" >&2
    exit 2
    ;;
esac

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
csv=${MEASURE_CSV:-$root/docs/ops-matrix.csv}
mkdir -p "$(dirname "$csv")"
[[ -s $csv ]] || echo "env,op,command,start_iso,end_iso,duration_sec,exit_code" >"$csv"

cmd_str=$*
echo "+ $cmd_str"

start_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_ns=$(date +%s%N)
"$@"
rc=$?
end_ns=$(date +%s%N)
end_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
dur=$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN{printf "%.1f", (e-s)/1e9}')

# CSV 이스케이프: 큰따옴표 두 번
esc=${cmd_str//\"/\"\"}
printf '%s,%s,"%s",%s,%s,%s,%s\n' "$env_name" "$op" "$esc" "$start_iso" "$end_iso" "$dur" "$rc" >>"$csv"

echo "[measure] env=$env_name op=$op start=$start_iso end=$end_iso duration=${dur}s exit=$rc -> ${csv#"$root"/}"
exit "$rc"
