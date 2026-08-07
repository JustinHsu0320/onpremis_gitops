#!/usr/bin/env python3
# =============================================================================
# mock_service.py — compose 專案通用「鏈路模擬器」（一個檔案、三種角色）
#
# 用途（junior 必讀）：
#   實驗室（compose_app_mock_projects 含該專案）沒有 GitLab Registry，拉不到真實 app 映像。
#   本檔用 Python 標準庫模擬三個服務的「對外行為契約」，讓 99-verify 能驗證
#   整條鏈路（LB VIP → HAProxy → app 節點埠 → 回應），完全不含商業邏輯。
#
#   角色由 argv[1] 決定（docker-compose.yml 的 command 傳入）：
#     api    : HTTP 8080，GET /health 回 200 {"status":"ok","host":<hostname>}，
#              其他路徑一律 200 echo
#     smtp   : TCP 2525，連上即回 "220 mock-smtp ESMTP" banner，
#              QUIT → 221、其他指令 → 250
#     worker : 每 30 秒印一行心跳 log 的長駐迴圈
#
#   刻意零第三方依賴：python:3.12-alpine 拉下來即可跑、不需 pip install——
#   build 秒級完成、攻擊面最小、也不用經 egress proxy 出網抓套件。
# =============================================================================
import json
import socket
import socketserver
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# 埠號是跨 role 契約（CONVENTIONS.md §3 埠號總表）：LB 後端健檢與 99-verify
# 都指著這兩個埠。host network 模式下容器直接綁宿主埠，這兩個數字
# 就是 app 節點的「對外承諾」，改動 = 先改 CONVENTIONS.md。
HTTP_PORT = 8080
SMTP_PORT = 2525


class ApiHandler(BaseHTTPRequestHandler):
    """模擬 api 服務：只實作健康檢查契約，其他路徑一律 200 echo。"""

    def do_GET(self):
        if self.path == "/health":
            # LB 健檢（HAProxy httpchk）與 99-verify 依賴的契約：200 + JSON。
            # host 欄位帶 hostname → 經 VIP 打進來時可肉眼確認分流到哪台節點
            body = json.dumps(
                {"status": "ok", "host": socket.gethostname()}
            ).encode()
        else:
            # 其他路徑 echo 200：手動 curl 時一眼確認「打到的是 mock 不是真 app」
            body = json.dumps(
                {"echo": self.path, "host": socket.gethostname()}
            ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # 覆寫預設 access log：加上固定前綴，docker logs 交錯時可辨識來源
        sys.stderr.write("[mock-api] %s\n" % (fmt % args))


class SmtpHandler(socketserver.StreamRequestHandler):
    """模擬 smtp-receiver：只做「greeting + 最低限度回應」，不實作 SMTP 狀態機。

    鏈路驗證只需要兩件事：
      1. TCP 連得上（LB 465 passthrough → app 2525 通）
      2. 連上立刻收到 220 banner（99-verify 斷言 stdout 以 '220' 開頭）
    """

    def handle(self):
        # RFC 5321：連線建立後 server 先說話。99-verify 的 `nc | head -1`
        # 抓的就是這一行；\r\n 是 SMTP 的行終止契約，不可省
        self.wfile.write(b"220 mock-smtp ESMTP\r\n")
        while True:
            line = self.rfile.readline()
            if not line:
                # client 直接斷線（health check 常見行為），安靜收工
                break
            cmd = line.strip().upper()
            if cmd == b"QUIT":
                self.wfile.write(b"221 Bye\r\n")
                break
            # 其他所有指令一律裝懂回 250：驗鏈路、不驗協定正確性
            self.wfile.write(b"250 OK\r\n")


class ReusableThreadingTCPServer(socketserver.ThreadingTCPServer):
    # 容器 recreate 時，前一代連線可能還在 TIME_WAIT；不開 reuse_address
    # 會 bind 失敗 → 容器進 restart loop。daemon_threads 讓殘留的 client
    # 執行緒不會擋住程序收到 SIGTERM 後退出。
    allow_reuse_address = True
    daemon_threads = True


def run_worker():
    """模擬 worker：長駐背景消費者的「殼」。

    目的只有兩個：
      1. 給 compose 一個不會退出的容器（否則 restart: unless-stopped 空轉重啟）
      2. docker logs 可見心跳 → 人工確認容器活著、時間有前進
    """
    n = 0
    while True:
        n += 1
        # flush=True 必要：容器內 stdout 是 pipe（非 tty），Python 會做
        # block buffering，不 flush 的話 docker logs 什麼都看不到
        print(
            "[mock-worker] heartbeat #%d host=%s" % (n, socket.gethostname()),
            flush=True,
        )
        time.sleep(30)


def main():
    role = sys.argv[1] if len(sys.argv) > 1 else "api"
    if role == "api":
        # ThreadingHTTPServer：兩台 LB 的健檢 + 監控 + 驗證會同時打 /health，
        # 單執行緒版本會互相卡住造成健檢誤判
        server = ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), ApiHandler)
        print("[mock-api] listening on :%d" % HTTP_PORT, flush=True)
        server.serve_forever()
    elif role == "smtp":
        server = ReusableThreadingTCPServer(("0.0.0.0", SMTP_PORT), SmtpHandler)
        print("[mock-smtp] listening on :%d" % SMTP_PORT, flush=True)
        server.serve_forever()
    elif role == "worker":
        run_worker()
    else:
        sys.exit("usage: %s api|smtp|worker" % sys.argv[0])


if __name__ == "__main__":
    main()
