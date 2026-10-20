#!/usr/bin/env bash
# k8s/*.yaml 의 ${...} 자리표시자를 envsubst 로 치환해 출력한다.
#   필수 env: IMAGE, CHAT_IRSA_ROLE_ARN, CONTENT_API_URL
#   선택 env: NOTE_API_URL(기본 빈값), LLM_PROVIDER(기본 bedrock), BEDROCK_MODEL_ID, APP_VERSION(기본 IMAGE 태그), SKIP
set -euo pipefail

usage() {
  cat <<'USAGE'
사용법: scripts/render-k8s.sh [--skip a,b,...] [-o OUTDIR]
  --skip LIST  제외할 파일(쉼표 구분): namespace,serviceaccount,configmap,deployment,service,ingress,hpa
               (환경변수 SKIP 으로도 지정 가능. 예: k3d 적용 시 --skip ingress,hpa)
  -o OUTDIR    지정 시 파일별로 OUTDIR/ 에 저장, 없으면 stdout 에 '---' 로 이어 출력
필수 env: IMAGE CHAT_IRSA_ROLE_ARN CONTENT_API_URL
예) IMAGE=123.dkr.ecr.ap-northeast-2.amazonaws.com/hermes-prd-chat-ecr:ab12cd3 \
    CHAT_IRSA_ROLE_ARN=arn:aws:iam::123:role/hermes-prd-chat-irsa-role \
    CONTENT_API_URL=http://internal-xxx.elb.amazonaws.com scripts/render-k8s.sh | kubectl apply -f -
USAGE
}

ALL=(namespace serviceaccount configmap deployment service ingress hpa)  # 적용 순서
SKIP_LIST="${SKIP:-}"
OUTDIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip) [[ $# -ge 2 ]] || { echo "ERROR: --skip 값 필요" >&2; exit 2; }; SKIP_LIST="$2"; shift 2 ;;
    -o) [[ $# -ge 2 ]] || { echo "ERROR: -o 값 필요" >&2; exit 2; }; OUTDIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: 알 수 없는 인자: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v envsubst >/dev/null 2>&1 || {
  echo "ERROR: envsubst 가 없습니다. 설치: apt-get install -y gettext-base (또는 dnf install -y gettext)" >&2; exit 1; }

missing=()
for v in IMAGE CHAT_IRSA_ROLE_ARN CONTENT_API_URL; do
  [[ -n "${!v:-}" ]] || missing+=("$v")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: 필수 환경변수 미설정: ${missing[*]}" >&2; exit 1
fi
# latest 태그 금지(계약): 태그 없음 또는 :latest 거부
if [[ "$IMAGE" != *:* || "${IMAGE##*:}" == "latest" || "${IMAGE##*/}" != *:* ]]; then
  echo "ERROR: IMAGE 는 git short SHA 태그가 필요합니다(latest/태그없음 금지): $IMAGE" >&2; exit 1
fi

# 선택 변수 기본값
export NOTE_API_URL="${NOTE_API_URL:-}"
export LLM_PROVIDER="${LLM_PROVIDER:-bedrock}"
# 기본값은 Claude Haiku 4.5 Global 추론 프로파일 — 실제 ID는 list-inference-profiles 로 확인 후 env 로 덮어쓸 것
export BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-global.anthropic.claude-haiku-4-5-20251001-v1:0}"
export APP_VERSION="${APP_VERSION:-${IMAGE##*:}}"
export IMAGE CHAT_IRSA_ROLE_ARN CONTENT_API_URL

# 치환 대상을 명시: 목록 밖의 $ 는 건드리지 않는다
VARS='${IMAGE} ${CHAT_IRSA_ROLE_ARN} ${CONTENT_API_URL} ${NOTE_API_URL} ${LLM_PROVIDER} ${BEDROCK_MODEL_ID} ${APP_VERSION}'

K8S_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../k8s" && pwd)"

declare -A skip=()
IFS=',' read -r -a _s <<< "$SKIP_LIST"
for n in "${_s[@]:-}"; do
  n="${n// /}"; [[ -z "$n" ]] && continue
  found=0; for a in "${ALL[@]}"; do [[ "$a" == "$n" ]] && found=1; done
  [[ $found -eq 1 ]] || { echo "ERROR: --skip 에 알 수 없는 이름: $n (허용: ${ALL[*]})" >&2; exit 2; }
  skip[$n]=1
done

[[ -z "$OUTDIR" ]] || mkdir -p "$OUTDIR"
first=1
for n in "${ALL[@]}"; do
  [[ -z "${skip[$n]:-}" ]] || continue
  f="$K8S_DIR/$n.yaml"
  [[ -f "$f" ]] || { echo "ERROR: 파일 없음: $f" >&2; exit 1; }
  if [[ -n "$OUTDIR" ]]; then
    envsubst "$VARS" < "$f" > "$OUTDIR/$n.yaml"
  else
    [[ $first -eq 1 ]] || echo "---"
    envsubst "$VARS" < "$f"
    first=0
  fi
done
