data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  oidc_issuer_host = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")

  # global./us./apac./eu. 접두사를 떼면 foundation-model ID
  bedrock_foundation_model_id = replace(var.bedrock_model_id, "/^(global|us|apac|eu)\\./", "")
}

# ---------------------------------------------------------------- OIDC (IRSA)
# thumbprint_list 생략: AWS provider >= 5.81 은 불필요(IAM 이 공개 CA 로 검증).
resource "aws_iam_openid_connect_provider" "eks" {
  url            = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]

  tags = {
    Name        = "${var.names.eks}-oidc"
    Workload    = "chat"
    ComputeType = "container"
  }
}

# ---------------------------------------------------------------- chat-api IRSA
data "aws_iam_policy_document" "irsa_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:${var.k8s_namespace}:${var.k8s_service_account}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "irsa" {
  name               = var.names.irsa_role
  assume_role_policy = data.aws_iam_policy_document.irsa_trust.json

  tags = {
    Name        = var.names.irsa_role
    Workload    = "chat"
    ComputeType = "container"
  }
}

data "aws_iam_policy_document" "irsa" {
  statement {
    sid = "BedrockInvoke"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:Converse",
      "bedrock:ConverseStream",
    ]
    # Global 추론 프로파일은 요청을 여러 리전으로 라우팅하므로 foundation-model ARN 의 리전은 와일드카드.
    # 프로파일은 계정 소유(리전 고정이 아닌 접두사 호환 위해 리전 * 허용).
    resources = [
      "arn:${local.partition}:bedrock:*:${local.account_id}:inference-profile/${var.bedrock_model_id}",
      "arn:${local.partition}:bedrock:*::foundation-model/${local.bedrock_foundation_model_id}",
    ]
  }

  # 선택: Gemini 폴백용 API 키 시크릿(없어도 apply 에는 영향 없음). 접미사 -XXXXXX 때문에 '-*'.
  statement {
    sid       = "OptionalGeminiSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:${local.partition}:secretsmanager:${var.region}:${local.account_id}:secret:hermes/prd/chat/gemini-api-key-*"]
  }

  # execute-api 문장 없음: note API 는 HTTP API(IAM authorizer 미사용)라 SigV4 권한이 필요 없다.
}

resource "aws_iam_role_policy" "irsa" {
  name   = "${var.names.irsa_role}-policy"
  role   = aws_iam_role.irsa.id
  policy = data.aws_iam_policy_document.irsa.json
}

# ---------------------------------------------------------------- AWS Load Balancer Controller
# LB Controller 자체는 Terraform 이 아닌 helm 으로 설치(런북 03). 이유: 클러스터 생성 직후
# helm/kubernetes provider 인증 의존성(순환·타이밍 문제)을 피하기 위함. 여기선 IRSA 역할만 만든다.
#
# albc_iam_policy.json 은 upstream 공식 정책(kubernetes-sigs/aws-load-balancer-controller
# docs/install/iam_policy.json)이다. 공식 정책의 Resource "*" 는 조건/태그 키
# (elbv2.k8s.aws/cluster 등)로 범위가 제한되며, 이것이 "Resource * 금지" 규칙의 유일한 정당화된 예외.
# 2026-10-19 upstream main 과 액션 80개 일치 확인 후 원본 그대로 사용. 10/20 에 EKS 버전과 맞는 태그인지 한 번 더 diff 권장:
#   curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
resource "aws_iam_policy" "albc" {
  name   = var.names.albc_policy
  policy = file("${path.module}/albc_iam_policy.json")

  tags = {
    Name        = var.names.albc_policy
    Workload    = "chat"
    ComputeType = "container"
  }
}

data "aws_iam_policy_document" "albc_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "albc" {
  name               = var.names.albc_role
  assume_role_policy = data.aws_iam_policy_document.albc_trust.json

  tags = {
    Name        = var.names.albc_role
    Workload    = "chat"
    ComputeType = "container"
  }
}

resource "aws_iam_role_policy_attachment" "albc" {
  role       = aws_iam_role.albc.name
  policy_arn = aws_iam_policy.albc.arn
}

# ---------------------------------------------------------------- GitHub Actions CI (선택)
locals {
  create_gha_oidc = var.enable_github_ci_role && var.github_oidc_provider_arn == ""
  gha_oidc_arn    = var.github_oidc_provider_arn != "" ? var.github_oidc_provider_arn : try(aws_iam_openid_connect_provider.github[0].arn, "")
}

# 계정당 같은 URL 의 provider 는 하나만 가능 → 이미 있으면 var.github_oidc_provider_arn 으로 재사용
resource "aws_iam_openid_connect_provider" "github" {
  count = local.create_gha_oidc ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  tags = {
    Name        = "${var.names.gha_role}-oidc"
    Workload    = "shared"
    ComputeType = "none"
  }
}

data "aws_iam_policy_document" "gha_trust" {
  count = var.enable_github_ci_role ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.gha_oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # main 브랜치 push 만 허용 (정확 일치, 와일드카드 없음)
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "gha" {
  count = var.enable_github_ci_role ? 1 : 0

  name               = var.names.gha_role
  assume_role_policy = data.aws_iam_policy_document.gha_trust[0].json

  tags = {
    Name        = var.names.gha_role
    Workload    = "shared"
    ComputeType = "none"
  }
}

data "aws_iam_policy_document" "gha" {
  count = var.enable_github_ci_role ? 1 : 0

  # GetAuthorizationToken 은 리소스 수준 권한을 지원하지 않아 "*" 가 유일하게 필요한 API
  statement {
    sid       = "EcrAuthToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.this.arn]
  }

  # kubeconfig 생성용. 실제 클러스터 권한은 아래 access entry 가 결정.
  statement {
    sid       = "EksDescribe"
    actions   = ["eks:DescribeCluster"]
    resources = [aws_eks_cluster.this.arn]
  }
}

resource "aws_iam_role_policy" "gha" {
  count = var.enable_github_ci_role ? 1 : 0

  name   = "${var.names.gha_role}-policy"
  role   = aws_iam_role.gha[0].id
  policy = data.aws_iam_policy_document.gha[0].json
}

# CI 가 `kubectl -n hermes set image` 할 수 있도록 hermes 네임스페이스 한정 Edit 권한
resource "aws_eks_access_entry" "gha" {
  count = var.enable_github_ci_role ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.gha[0].arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "gha" {
  count = var.enable_github_ci_role ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.gha[0].arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = [var.k8s_namespace]
  }

  depends_on = [aws_eks_access_entry.gha]
}
