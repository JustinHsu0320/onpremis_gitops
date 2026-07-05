# =============================================================================
# environments/prod/backend.tf — GitLab-managed Terraform state（http backend）
#
# 為什麼是 GitLab HTTP backend？
#   * state 內含機密（雖然本層機密不多，仍有 vCenter 物件細節）→ 不進 Git
#   * GitLab 原生提供 state 儲存 + 鎖（lock/unlock）+ 版本紀錄，地端自建
#     GitLab CE（gitlab-01）就有，不需要另外架 S3/Consul
#
# 這個 block「刻意留空」：所有連線參數一律在 init 階段用 -backend-config
# 注入（或等效的 TF_HTTP_* 環境變數），理由：
#   * address 內含 GitLab project id、username/password 是 CI 憑證——
#     這些值不寫死在 Git（換 GitLab 位址 / 輪替 token 不該改程式碼）
#   * 本機離線驗證（validate / fmt / plan review）用 `terraform init
#     -backend=false` 直接跳過 backend 初始化，完全不需要碰得到 GitLab
#
# GitLab CI 內的標準 init 寫法（TF_STATE_NAME=prod；CI_* 皆為 GitLab 內建變數）：
#
#   terraform init \
#     -backend-config="address=$${CI_API_V4_URL}/projects/$${CI_PROJECT_ID}/terraform/state/$${TF_STATE_NAME}" \
#     -backend-config="lock_address=$${CI_API_V4_URL}/projects/$${CI_PROJECT_ID}/terraform/state/$${TF_STATE_NAME}/lock" \
#     -backend-config="unlock_address=$${CI_API_V4_URL}/projects/$${CI_PROJECT_ID}/terraform/state/$${TF_STATE_NAME}/lock" \
#     -backend-config="username=gitlab-ci-token" \
#     -backend-config="password=$${CI_JOB_TOKEN}" \
#     -backend-config="lock_method=POST" \
#     -backend-config="unlock_method=DELETE" \
#     -backend-config="retry_wait_min=5"
#
# 工程師本機（用個人 PAT，scope: api）：
#   export TF_HTTP_USERNAME=<gitlab帳號>
#   export TF_HTTP_PASSWORD=<personal access token>
#   terraform init -backend-config="address=https://gitlab.ptc-nec.com.tw/api/v4/projects/<id>/terraform/state/prod" ...
#
# 純離線靜態檢查（不碰 state）：
#   terraform init -backend=false && terraform validate
# =============================================================================

terraform {
  backend "http" {}
}
