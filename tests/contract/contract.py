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

"""Runs the same management scenarios against two hosts of the Workflow Management API and compares them.

The reference host is an integration's own API (workflow.management.rest); the candidate is the Workflow Runtime's
mount for that integration. Each step must give the same status code and the same top-level response fields.
Error messages are compared after IDs are masked; a differing message is reported but does not fail the run.

Needs the expense-approval sample (samples/expense-approval) and Python 3 (standard library only).
"""

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
import uuid

WORKFLOW_TYPE = "expenseApprovalWorkflow"
MANAGER = {"x-user-id": "alice", "x-user-roles": "manager"}
CLERK = {"x-user-id": "bob", "x-user-roles": "clerk"}
ADMIN = {"x-user-id": "carol", "x-user-roles": "expense-admin"}
ANONYMOUS = {}
ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|CT-[A-Za-z0-9-]+")


class Host:
    def __init__(self, name, base):
        self.name = name
        self.base = base.rstrip("/")

    def call(self, method, path, identity, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        for key, value in identity.items():
            req.add_header(key, value)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.status, parse(resp.read())
        except urllib.error.HTTPError as err:
            return err.code, parse(err.read())

    def wait(self, fetch, timeout=90):
        deadline = time.time() + timeout
        while time.time() < deadline:
            value = fetch()
            if value:
                return value
            time.sleep(1)
        raise TimeoutError(f"{self.name}: timed out waiting")

    def pending_task(self, workflow_id, name):
        def fetch():
            _, body = self.call("GET", "/human-tasks?status=PENDING&limit=100", MANAGER)
            for task in body.get("items", []):
                if task.get("parentWorkflowId") == workflow_id and task["taskName"].endswith("." + name):
                    return task["taskId"]
            return None
        return self.wait(fetch)

    def pending_review(self, workflow_id):
        def fetch():
            _, body = self.call("GET", "/review-activities?status=PENDING&limit=100", MANAGER)
            for task in body.get("items", []):
                if task.get("parentWorkflowId") == workflow_id:
                    return task["taskId"]
            return None
        return self.wait(fetch, timeout=180)


def parse(raw):
    try:
        return json.loads(raw) if raw else {}
    except ValueError:
        return {"_text": raw.decode(errors="replace")[:200]}


def claim(tag, currency="EUR", amount=40):
    return {"claimId": f"CT-{tag}-{uuid.uuid4().hex[:6]}", "employee": "nimal", "amount": amount,
            "currency": currency, "purpose": "contract test"}


def start(host, currency="EUR", amount=40, workflow_id=None):
    body = {"workflowType": WORKFLOW_TYPE, "input": claim(host.name, currency, amount)}
    if workflow_id:
        body["workflowId"] = workflow_id
    return host.call("POST", "/workflows", MANAGER, body)


def scenario(host):
    """Yields (step, status, body) for one host. Both hosts run it against their own fresh instances."""
    yield ("definitions", *host.call("GET", "/definitions", MANAGER))
    yield ("start: unknown type", *host.call("POST", "/workflows", MANAGER, {"workflowType": "nope", "input": {}}))
    yield ("start: missing type", *host.call("POST", "/workflows", MANAGER, {"input": {}}))
    yield ("start: reserved id", *start(host, workflow_id="humantask-x"))

    fixed_id = f"CT-{host.name}-{uuid.uuid4().hex[:8]}"
    yield ("start: explicit id", *start(host, workflow_id=fixed_id))
    yield ("start: id already running", *start(host, workflow_id=fixed_id))

    status, body = start(host)
    yield ("start", status, body)
    wid = body["workflowId"]
    task = host.pending_task(wid, "checkExpenseRequest")
    path = f"/human-tasks/{task}"
    yield ("complete: no identity", *host.call("POST", path + "/complete", ANONYMOUS, {"result": {"action": "REJECT"}}))
    yield ("complete: wrong role", *host.call("POST", path + "/complete", CLERK, {"result": {"action": "REJECT"}}))
    yield ("complete: invalid result", *host.call("POST", path + "/complete", MANAGER, {"result": {"action": "MAYBE"}}))
    yield ("reassign: not an administrator", *host.call("POST", path + "/reassign", MANAGER, {"userRoles": ["finance"]}))
    yield ("reassign: bad audience", *host.call("POST", path + "/reassign", ADMIN, {"userRoles": "finance"}))
    yield ("reassign: empty audience", *host.call("POST", path + "/reassign", ADMIN, {}))
    yield ("reassign: administrator", *host.call("POST", path + "/reassign", ADMIN, {"userRoles": ["manager", "finance"]}))
    yield ("deadline: not positive", *host.call("POST", path + "/deadline", ADMIN, {"timeoutMillis": 0}))
    yield ("deadline: administrator", *host.call("POST", path + "/deadline", ADMIN, {"timeoutMillis": 86400000}))
    time.sleep(2)
    yield ("complete: manager", *host.call("POST", path + "/complete", MANAGER,
                                           {"result": {"action": "REQUEST_BILL", "comment": "send bills"}}))
    time.sleep(2)  # the module answers 500 when its signal races the task closing; settle first
    yield ("complete: again", *host.call("POST", path + "/complete", MANAGER, {"result": {"action": "REJECT"}}))
    yield ("task after completion", *host.call("GET", path, MANAGER))

    time.sleep(2)
    yield ("send data event", *host.call("POST", f"/workflows/{wid}/data/billSubmitted", MANAGER,
                                         {"bills": [{"reference": "B-1", "amount": 40}]}))
    task2 = host.pending_task(wid, "reviewBills")
    yield ("fail task: administrator", *host.call("POST", f"/human-tasks/{task2}/fail", ADMIN,
                                                  {"reason": "contract test"}))

    status, body = start(host, currency="USD", amount=50)
    wid2 = body["workflowId"]
    host.call("POST", f"/human-tasks/{host.pending_task(wid2, 'checkExpenseRequest')}/complete", MANAGER,
              {"result": {"action": "REQUEST_BILL"}})
    time.sleep(2)
    host.call("POST", f"/workflows/{wid2}/data/billSubmitted", MANAGER, {"bills": [{"reference": "B", "amount": 50}]})
    host.call("POST", f"/human-tasks/{host.pending_task(wid2, 'reviewBills')}/complete", MANAGER,
              {"result": {"approved": True}})
    review = host.pending_review(wid2)
    rpath = f"/review-activities/{review}"
    yield ("review: wrong role", *host.call("POST", rpath + "/reject", CLERK, {}))
    yield ("review: input not an object", *host.call("POST", rpath + "/proceed-with-input", MANAGER, {"input": 3}))
    yield ("bulk: no selection", *host.call("POST", "/review-activities/bulk-retry", MANAGER, {"action": "retry"}))
    yield ("bulk: unknown action", *host.call("POST", "/review-activities/bulk-retry", MANAGER,
                                              {"action": "skip", "taskIds": [review]}))
    yield ("bulk: fail by parent", *host.call("POST", "/review-activities/bulk-retry", MANAGER,
                                              {"action": "fail", "parentWorkflowId": wid2, "feedback": "gateway"}))
    time.sleep(2)
    yield ("bulk: already decided", *host.call("POST", "/review-activities/bulk-retry", MANAGER,
                                               {"action": "retry", "taskIds": [review]}))
    yield ("review: decided again", *host.call("POST", rpath + "/proceed", MANAGER, {}))


def shape(body):
    if isinstance(body, dict):
        keys = set(body.keys())
        if "items" in body and isinstance(body["items"], list) and body["items"] and isinstance(body["items"][0], dict):
            keys |= {"items[]." + k for k in body["items"][0].keys()}
        if "definitions" in body and body["definitions"]:
            keys |= {"definitions[]." + k for k in body["definitions"][0].keys()}
        return keys
    return {type(body).__name__}


def message(body):
    err = body.get("error") if isinstance(body, dict) else None
    text = err.get("message") if isinstance(err, dict) else None
    return ID.sub("<id>", text) if text else None


def summary(body):
    if isinstance(body, dict) and "applied" in body:
        return {k: body[k] for k in ("requested", "applied", "skipped", "failed")} | {
            "outcomes": [i["outcome"] for i in body.get("items", [])]}
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--reference", default="http://localhost:8234/workflow")
    parser.add_argument("--candidate", default="http://localhost:9470/integrations/expense-approval/workflow")
    args = parser.parse_args()
    ref, cand = Host("reference", args.reference), Host("candidate", args.candidate)

    ref_steps = list(scenario(ref))
    cand_steps = list(scenario(cand))
    failures, notes = 0, 0
    for (step, rs, rb), (_, cs, cb) in zip(ref_steps, cand_steps):
        problems = []
        if rs != cs:
            problems.append(f"status {rs} vs {cs}")
        if shape(rb) != shape(cb):
            problems.append(f"fields {sorted(shape(rb) ^ shape(cb))}")
        if summary(rb) != summary(cb):
            problems.append(f"bulk {summary(rb)} vs {summary(cb)}")
        verdict = "FAIL" if problems else "PASS"
        if problems:
            failures += 1
        note = ""
        if not problems and message(rb) != message(cb):
            notes += 1
            note = f"  (message: {message(rb)!r} vs {message(cb)!r})"
        print(f"{verdict}  {step:32} {rs}  {'; '.join(problems)}{note}")
        if problems:
            print(f"      reference: {json.dumps(rb)[:300]}\n      candidate: {json.dumps(cb)[:300]}")
    print(f"\n{len(ref_steps) - failures}/{len(ref_steps)} steps match; {notes} with a different message")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
