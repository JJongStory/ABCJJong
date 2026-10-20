# NOTE: terraform-aws-modules/eks 를 쓰지 않고 순수 aws_eks_* 리소스로 작성.
#  - 레지스트리에 접근 불가한 환경에서 작성해 모듈 입력을 검증할 수 없음
#  - 모듈은 메이저 버전마다 입력이 바뀜
#  - 발표 때 리소스 하나하나 설명하기 쉬움

data "aws_partition" "current" {}

resource "aws_iam_role" "cluster" {
  name = var.names.cluster_role

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name        = var.names.cluster_role
    Workload    = "chat"
    ComputeType = "container"
  }
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# 컨트롤 플레인 로그 (보존 7일로 비용 제한). 그룹을 먼저 만들어 retention 을 우리가 통제.
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.names.eks}/cluster"
  retention_in_days = 7

  tags = {
    Name        = "${var.names.eks}-logs"
    Workload    = "chat"
    ComputeType = "container"
  }
}

resource "aws_eks_cluster" "this" {
  name     = var.names.eks
  version  = var.eks_version
  role_arn = aws_iam_role.cluster.arn

  # 애드온을 아래에서 명시적으로 관리하므로 자동 부트스트랩 끔
  bootstrap_self_managed_addons = false

  vpc_config {
    subnet_ids = var.app_subnet_ids
    # private: 노드 → API. public: CloudShell(VPC 밖)에서 kubectl/helm 이 닿아야 함.
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  access_config {
    authentication_mode = "API"
    # terraform 실행 주체(CloudShell 사용자)에게 cluster-admin 자동 부여
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = ["api", "audit"]

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.eks,
  ]

  tags = {
    Name        = var.names.eks
    Workload    = "chat"
    ComputeType = "container"
  }
}

resource "aws_iam_role" "node" {
  name = var.names.node_role

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name        = var.names.node_role
    Workload    = "chat"
    ComputeType = "container"
  }
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryReadOnly",
    "AmazonSSMManagedInstanceCore", # SSM 접속(키페어/SSH 없음)
  ])

  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/${each.key}"
}

# 별도 launch template/SG 없이 클러스터 SG 를 노드·Pod 가 공유 (계약서 3장: eks_cluster_sg_id)
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = var.names.ng
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.app_subnet_ids
  instance_types  = ["t3.medium"]

  scaling_config {
    min_size     = 2
    desired_size = 2
    max_size     = 4
  }

  update_config {
    max_unavailable = 1
  }

  lifecycle {
    # 오토스케일/수동 조정으로 바뀐 desired 를 apply 가 되돌리지 않게
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]

  tags = {
    Name        = var.names.ng
    Workload    = "chat"
    ComputeType = "container"
  }
}

# 애드온: 버전 미지정 = 클러스터 버전의 default. 노드가 필요한 것은 node group 이후.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "metrics-server"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}
