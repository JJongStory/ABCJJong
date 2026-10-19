#!/usr/bin/env bash
# Project HERMES — AWS CloudShell bootstrap (멱등: 세션마다 다시 실행해도 안전)
# 사용: source ~/hermes/scripts/bootstrap.sh   (source 해야 환경변수가 현재 셸에 남음)
set -uo pipefail

export AWS_REGION=ap-northeast-2 AWS_DEFAULT_REGION=ap-northeast-2
BIN="$HOME/bin"; mkdir -p "$BIN"
case ":$PATH:" in *":$BIN:"*) ;; *) export PATH="$BIN:$PATH" ;; esac

# 1GB $HOME 보호: provider/플러그인은 /tmp (세션 종료 시 사라짐 → terraform init 재실행)
export TF_DATA_DIR=/tmp/tfdata TF_PLUGIN_CACHE_DIR=/tmp/tfcache
mkdir -p "$TF_DATA_DIR" "$TF_PLUGIN_CACHE_DIR"

need() { ! command -v "$1" >/dev/null 2>&1; }

if need terraform; then
  V=$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/terraform | python3 -c 'import sys,json;print(json.load(sys.stdin)["current_version"])')
  curl -fsSL -o /tmp/tf.zip "https://releases.hashicorp.com/terraform/${V}/terraform_${V}_linux_amd64.zip"
  unzip -oq /tmp/tf.zip -d "$BIN" terraform && rm -f /tmp/tf.zip
fi
if need eksctl; then
  curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C "$BIN"
fi
if need helm; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | HELM_INSTALL_DIR="$BIN" USE_SUDO=false bash >/dev/null
fi

# 영속 저장 공간 점검
echo "== versions"; terraform version | head -1; eksctl version; helm version --short; kubectl version --client 2>/dev/null | head -1
echo "== \$HOME usage"; du -sh "$HOME" 2>/dev/null
echo "== docker"; if docker info >/dev/null 2>&1; then echo "docker OK"; else echo "docker 사용 불가 → GitHub Actions 빌드 경로 사용"; fi

# EKS가 이미 있으면 kubeconfig 연결
if aws eks describe-cluster --name hermes-prd-chat-eks >/dev/null 2>&1; then
  aws eks update-kubeconfig --name hermes-prd-chat-eks --alias hermes >/dev/null && echo "kubeconfig: hermes"
fi

# 셸 편의
alias k=kubectl
alias kh='kubectl -n hermes'
echo "bootstrap done. (세션 20~30분 무입력 시 종료됨 — 긴 apply 중엔 탭 유지)"
