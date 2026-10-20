# ---------------------------------------------------------------------------
# 계약서 4~7장의 이름·CIDR 을 한 곳(locals)에서 관리한다. 모듈은 var.names 로 받아 쓴다.
# 의존 순서(계약서 11장): network → data → chat(EKS) → content → note → monitoring
# ---------------------------------------------------------------------------
locals {
  region = "ap-northeast-2"
  azs    = ["ap-northeast-2a", "ap-northeast-2c"]
  p      = "user17-hermes"

  cidr = {
    vpc    = "10.0.0.0/16"
    public = ["10.0.0.0/24", "10.0.1.0/24"]     # pub-a, pub-c
    app    = ["10.0.16.0/20", "10.0.32.0/20"]   # app-a, app-c (Pod IP 소비 → /20)
    data   = ["10.0.100.0/24", "10.0.101.0/24"] # data-a, data-c
  }

  n = {
    network = {
      vpc      = "${local.p}-shared-vpc"
      igw      = "${local.p}-shared-igw"
      nat      = "${local.p}-shared-nat-a"
      nat_eip  = "${local.p}-shared-nat-eip-a"
      pub_a    = "${local.p}-shared-pub-a"
      pub_c    = "${local.p}-shared-pub-c"
      app_a    = "${local.p}-shared-app-a"
      app_c    = "${local.p}-shared-app-c"
      data_a   = "${local.p}-shared-data-a"
      data_c   = "${local.p}-shared-data-c"
      rtb_pub  = "${local.p}-shared-rtb-pub"
      rtb_app  = "${local.p}-shared-rtb-app"
      rtb_data = "${local.p}-shared-rtb-data"
      vpce_s3  = "${local.p}-shared-vpce-s3"
      vpce_ddb = "${local.p}-shared-vpce-ddb"
    }
    data = {
      rds              = "${local.p}-shared-rds"
      rds_subnets      = "${local.p}-shared-rds-subnets"
      rds_sg           = "${local.p}-shared-rds-sg"
      ddb              = "${local.p}-note-ddb"
      artifacts_prefix = "${local.p}-shared-artifacts" # 모듈이 -<random6> 을 붙인다
    }
    chat = {
      ecr          = "${local.p}-chat-ecr"
      eks          = "${local.p}-chat-eks"
      ng           = "${local.p}-chat-ng"
      cluster_role = "${local.p}-chat-eks-cluster-role"
      node_role    = "${local.p}-chat-ng-role"
      irsa_role    = "${local.p}-chat-irsa-role"
      albc_role    = "${local.p}-chat-albc-role"
      albc_policy  = "${local.p}-chat-albc-policy"
      gha_role     = "${local.p}-shared-gha-role"
    }
    content = {
      lt               = "${local.p}-content-lt"
      asg              = "${local.p}-content-asg"
      ec2              = "${local.p}-content-ec2"
      alb_ext          = "${local.p}-content-alb-ext"
      alb_int          = "${local.p}-content-alb-int"
      tg_ext           = "${local.p}-content-tg-ext"
      tg_int           = "${local.p}-content-tg-int"
      alb_ext_sg       = "${local.p}-content-alb-ext-sg"
      alb_int_sg       = "${local.p}-content-alb-int-sg"
      ec2_sg           = "${local.p}-content-ec2-sg"
      ec2_role         = "${local.p}-content-ec2-role"
      instance_profile = "${local.p}-content-ec2-profile"
    }
    note = {
      api       = "${local.p}-note-api"
      fn        = "${local.p}-note-fn"
      fn_role   = "${local.p}-note-fn-role"
      lambda_sg = "${local.p}-note-lambda-sg"
    }
    monitoring = {
      sns               = "${local.p}-shared-alerts"
      alarm_alb_5xx     = "${local.p}-content-alb-5xx"
      alarm_asg_cpu     = "${local.p}-content-asg-cpu"
      alarm_lambda_errs = "${local.p}-note-fn-errors"
    }
  }

  db_name = "hermes"
  db_user = "hermes_admin"
}

module "network" {
  source = "./modules/network"

  names               = local.n.network
  azs                 = local.azs
  region              = local.region
  vpc_cidr            = local.cidr.vpc
  public_subnet_cidrs = local.cidr.public
  app_subnet_cidrs    = local.cidr.app
  data_subnet_cidrs   = local.cidr.data
}

module "data" {
  source = "./modules/data"

  names              = local.n.data
  vpc_id             = module.network.vpc_id
  data_subnet_ids    = module.network.data_subnet_ids
  vpce_ddb_id        = module.network.vpce_ddb_id
  admin_role_arns    = var.admin_role_arns
  db_name            = local.db_name
  db_user            = local.db_user
  rds_instance_class = var.rds_instance_class
}

module "chat" {
  source = "./modules/chat"

  names                 = local.n.chat
  region                = local.region
  vpc_id                = module.network.vpc_id
  app_subnet_ids        = module.network.app_subnet_ids
  eks_version           = var.eks_version
  bedrock_model_id      = var.bedrock_model_id
  enable_github_ci_role = var.enable_github_ci_role
  github_repo           = var.github_repo

  github_oidc_provider_arn = var.github_oidc_provider_arn
}

module "content" {
  source = "./modules/content"

  names                 = local.n.content
  region                = local.region
  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  app_subnet_ids        = module.network.app_subnet_ids
  eks_cluster_sg_id     = module.chat.eks_cluster_sg_id
  rds_endpoint          = module.data.rds_endpoint
  rds_secret_arn        = module.data.rds_secret_arn
  rds_sg_id             = module.data.rds_sg_id
  artifacts_bucket      = module.data.artifacts_bucket
  db_name               = local.db_name
  app_version           = var.app_version
  content_instance_type = var.content_instance_type
}

module "note" {
  source = "./modules/note"

  names                = local.n.note
  region               = local.region
  vpc_id               = module.network.vpc_id
  app_subnet_ids       = module.network.app_subnet_ids
  ddb_table_name       = module.data.ddb_table_name
  ddb_table_arn        = module.data.ddb_table_arn
  ddb_prefix_list_id   = module.network.ddb_prefix_list_id
  reserved_concurrency = var.note_reserved_concurrency
}

module "monitoring" {
  source = "./modules/monitoring"

  names                      = local.n.monitoring
  alert_email                = var.alert_email
  content_alb_ext_arn_suffix = module.content.content_alb_ext_arn_suffix
  content_asg_name           = module.content.content_asg_name
  note_fn_name               = module.note.note_fn_name
}
