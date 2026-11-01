"""A stand-in for Heimdall's API, for tests/commands_test.sh.

It answers the two calls upload_heimdall makes, as Heimdall 2.15 does:

  GET /server        {"apiKeysEnabled": ..., ...}
  POST /evaluations  multipart: data (the file), filename, public,
                     evaluationTags, groups; 201 with the evaluation's id,
                     401 without an Authorization header, 403 with a wrong
                     key

It listens on 127.0.0.1 on a free port, which it writes to DIR/port, and
logs each upload as a JSON line in DIR/uploads.jsonl, numbering them from
the lines already there. Each request reads
DIR/settings.json, so a test changes its answers without restarting it:

  key            the API key it takes (default "test-key")
  api_keys       what GET /server says of API keys (default true)
  fail           1-based numbers of uploads to answer with status (default [])
  status         the status for those (default 500)
  garbage        answer uploads with 201 and a body that isn't JSON

Usage: python3 tests/fake_heimdall.py DIR
"""

import email.parser
import email.policy
import hashlib
import http.server
import json
import os
import sys

DIR = sys.argv[1]


def settings():
    try:
        with open(os.path.join(DIR, "settings.json")) as handle:
            return json.load(handle)
    except FileNotFoundError:
        return {}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, status, body, content_type="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path != "/server":
            self.answer(404, {"statusCode": 404, "message": "Cannot GET " + self.path})
            return
        self.answer(200, {
            "apiKeysEnabled": settings().get("api_keys", True),
            "banner": "", "enabledOAuth": [], "localLoginEnabled": True,
        })

    def do_POST(self):
        if self.path != "/evaluations":
            self.answer(404, {"statusCode": 404, "message": "Cannot POST " + self.path})
            return
        config = settings()
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        auth = self.headers.get("Authorization")
        if auth is None:
            self.answer(401, {"statusCode": 401, "message": "Unauthorized"})
            return
        if auth != "Api-Key " + config.get("key", "test-key"):
            self.answer(403, {"statusCode": 403, "message": "Forbidden resource"})
            return
        message = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
            b"Content-Type: " + self.headers.get("Content-Type", "").encode() + b"\r\n\r\n" + body)
        fields, files = {}, {}
        for part in message.iter_parts():
            name = part.get_param("name", header="content-disposition")
            if part.get_filename() is not None:
                content = part.get_payload(decode=True)
                files.setdefault(name, []).append({
                    "filename": part.get_filename(),
                    "content_type": part.get_content_type(),
                    "sha256": hashlib.sha256(content).hexdigest(),
                })
            else:
                fields.setdefault(name, []).append(part.get_payload(decode=True).decode())
        # Numbered from the log, which a test empties with the settings.
        log_path = os.path.join(DIR, "uploads.jsonl")
        number = 1
        if os.path.exists(log_path):
            with open(log_path) as log:
                number += sum(1 for _ in log)
        with open(log_path, "a") as log:
            log.write(json.dumps({"n": number, "fields": fields, "files": files}) + "\n")
        if number in config.get("fail", []):
            self.answer(config.get("status", 500), {"statusCode": config.get("status", 500), "message": "Bad"})
            return
        if config.get("garbage"):
            self.answer(201, b"<html>not json</html>", "text/html")
            return
        self.answer(201, {
            "id": str(1000 + number), "filename": fields.get("filename", [""])[0],
            "public": fields.get("public", [""])[0] == "true", "evaluationTags": [],
        })


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(DIR, "port.tmp"), "w") as handle:
    handle.write(str(server.server_address[1]))
os.rename(os.path.join(DIR, "port.tmp"), os.path.join(DIR, "port"))
server.serve_forever()
