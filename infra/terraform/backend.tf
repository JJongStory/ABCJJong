# state: S3 + 네이티브 락(use_lockfile, DynamoDB 락 테이블 불필요 — Terraform >= 1.10)
# bucket/key/region 은 하드코딩하지 않고 init 시 주입한다 (버킷명에 계정 ID 없음 → 캡처 안전):
#   terraform init -backend-config="bucket=$TFB" -backend-config="key=hermes/prd.tfstate" -backend-config="region=ap-northeast-2"
terraform {
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}
