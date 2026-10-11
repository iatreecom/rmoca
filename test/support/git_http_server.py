"""Smart-HTTP git server for tests: wraps `git http-backend` (the reference
implementation that GitLab/Gitea/cgit also use) with optional Basic auth.

usage: git_http_server.py PORT REPO_ROOT [USER:PASSWORD]
"""
import base64
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, ROOT = int(sys.argv[1]), sys.argv[2]
AUTH = sys.argv[3] if len(sys.argv) > 3 else None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _serve(self):
        if AUTH:
            expected = "Basic " + base64.b64encode(AUTH.encode()).decode()
            if self.headers.get("Authorization") != expected:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="git"')
                self.end_headers()
                return
        path, _, query = self.path.partition("?")
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        env = dict(
            os.environ,
            GIT_PROJECT_ROOT=ROOT,
            GIT_HTTP_EXPORT_ALL="1",
            PATH_INFO=path,
            QUERY_STRING=query,
            REQUEST_METHOD=self.command,
            CONTENT_TYPE=self.headers.get("Content-Type", ""),
            CONTENT_LENGTH=str(len(body)),
            REMOTE_USER="tester",
            REMOTE_ADDR="127.0.0.1",
            GIT_CONFIG_PARAMETERS="'http.receivepack=true'",
        )
        out = subprocess.run(
            ["git", "http-backend"], input=body, env=env, capture_output=True
        ).stdout
        head, _, payload = out.partition(b"\r\n\r\n")
        status = 200
        headers = []
        for line in head.decode("latin1").split("\r\n"):
            if not line:
                continue
            key, _, value = line.partition(":")
            if key.lower() == "status":
                status = int(value.strip().split()[0])
            else:
                headers.append((key, value.strip()))
        self.send_response(status)
        for key, value in headers:
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = _serve
    do_POST = _serve


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
