# =============================================================================
# mock 模擬器映像 —— 僅實驗室（compose_app_mock_projects 含該專案時）使用
#
# 一個映像三種角色（api / smtp / worker），實際角色由 docker-compose.yml
# 的 command 覆寫 argv 決定。刻意選 python:3.12-alpine：
#   - 標準庫就夠（見 mock_service.py），零 pip 依賴 → build 不需出網、秒級完成
#   - alpine 內建 busybox wget → compose 的 api healthcheck 直接可用
# =============================================================================
FROM python:3.12-alpine

# 只複製單一腳本；不 COPY 整個目錄，避免未來雜物意外進映像
COPY mock_service.py /app/mock_service.py

# 保底預設跑 api；正式角色由 compose 的 command（api|smtp|worker）覆寫
CMD ["python", "/app/mock_service.py", "api"]
