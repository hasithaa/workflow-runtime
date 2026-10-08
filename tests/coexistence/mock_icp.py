#!/usr/bin/env python3
# Copyright (c) 2026, WSO2 LLC. (http://www.wso2.org).
#
# WSO2 LLC. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied. See the License for the
# specific language governing permissions and limitations
# under the License.

"""Stands in for ICP's heartbeat endpoints and records what the ICP runtime bridge sends (GET /received)."""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

received = []


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.read_body() or b"{}")
        received.append({
            "path": self.path,
            "workflowMetadata": "workflowMetadata" in body,
            "workflowTaskQueue": body.get("workflowTaskQueue"),
            "capabilities": body.get("capabilities"),
            "authorized": self.headers.get("Authorization", "").startswith("Bearer "),
            "fields": sorted(body.keys()),
        })
        # Optional fields are only sent after the server lists them, so ask for one more full heartbeat.
        full_again = self.path.endswith("deltaHeartbeat") and not any(r["workflowMetadata"] for r in received)
        self.reply({"acknowledged": True, "supportedHeartbeatFields": ["workflowMetadata"], "commands": [],
                    "fullHeartbeatRequired": full_again})

    def read_body(self):
        if self.headers.get("Transfer-Encoding", "").lower() != "chunked":
            return self.rfile.read(int(self.headers.get("Content-Length", 0)))
        data = b""
        while True:
            size = int(self.rfile.readline().strip().split(b";")[0], 16)
            if size == 0:
                self.rfile.readline()
                return data
            data += self.rfile.read(size)
            self.rfile.readline()

    def do_GET(self):
        self.reply({"count": len(received), "last": received[-5:]})

    def reply(self, payload):
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", int(sys.argv[1]) if len(sys.argv) > 1 else 9445), Handler).serve_forever()
