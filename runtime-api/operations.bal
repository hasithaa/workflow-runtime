// Copyright (c) 2026, WSO2 LLC. (http://www.wso2.org).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied. See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/http;
import ballerina/random;
import ballerina/time;

// The management operations the workflow module binds to the process that owns the task queue, done here against
// Temporal directly. Messages, status codes and signal payloads follow workflow 1.0.0 (see docs/wire-contract.md).

const string TYPE_PREFIX = "workflow-";
const string REVIEW_TYPE_PREFIX = "reviewactivity-";
final readonly & string[] RESERVED_ID_PREFIXES = ["humantask-", "reviewactivity-", "childwf-", "childagent-"];
final readonly & string[] AUDIENCE_KEYS = ["userRoles", "users", "excludedUsers", "excludedRoles"];

const string HUMAN_TASK = "HUMAN_TASK";
const string REVIEW_ACTIVITY = "REVIEW_ACTIVITY";
const string RETRY_TASK = "RETRY_TASK";
const string ON_FAILURE = "ON_FAILURE";

type Caller record {|
    string? userId;
    string[] roles;
|};

type Result record {|
    int status;
    json body;
|};

isolated function ok(json body, int status = 200) returns Result => {status, body};

isolated function failure(int status, string message) returns Result => {status, body: {"error": {"message": message}}};

// ---- definitions ----

isolated function definitions(IntegrationRecord[] scope) returns Result {
    json[] defs = [];
    foreach IntegrationRecord entry in scope {
        int workers = entry.runtimes.toArray().filter(rt => isOnline(rt)).length();
        foreach map<json> def in definitionsOf(entry) {
            map<json> item = def.clone();
            if item["kind"] == "AGENT" {
                item["inputSchema"] = AGENT_START_SCHEMA;
            }
            item["isActive"] = workers > 0;
            item["workerCount"] = workers;
            defs.push(item);
        }
    }
    return ok({definitions: defs});
}

// The `{query, input}` envelope a durable agent is started with. The registered metadata carries the runner's own
// schema, and not the agent's input type, so `input` stays open here.
const string AGENT_START_SCHEMA = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\","
    + "\"description\":\"The user turn the agent reasons over\"},\"input\":{}},\"required\":[\"query\"],"
    + "\"additionalProperties\":false}";

isolated function definitionsOf(IntegrationRecord entry) returns map<json>[] {
    string? checksum = entry.currentChecksum;
    json metadata = checksum is string ? entry.descriptors[checksum] : ();
    json listed = metadata is map<json> ? metadata["definitions"] : ();
    map<json>[] out = [];
    if listed is json[] {
        foreach json def in listed {
            if def is map<json> {
                out.push(def);
            }
        }
    }
    return out;
}

// ---- start ----

isolated function startInstance(IntegrationRecord[] scope, json body, Caller caller) returns Result|error {
    if body !is map<json> {
        return failure(400, "Request body must be a JSON object");
    }
    json typeValue = body["workflowType"];
    if typeValue !is string || typeValue == "" {
        return failure(400, "workflowType is required");
    }
    [IntegrationRecord, map<json>]? owner = findDefinition(scope, typeValue);
    if owner is () {
        return failure(404, string `No workflow or durable agent is registered as '${typeValue}'`);
    }
    IntegrationRecord entry = owner[0];
    string? taskQueue = entry.taskQueue;
    if taskQueue is () {
        return failure(409, string `Integration '${entry.name}' has not reported its task queue`);
    }
    string kind = owner[1]["kind"] is string ? <string>owner[1]["kind"] : "WORKFLOW";

    json input = body["input"];
    if kind == "AGENT" {
        if input !is map<json> || input["query"] !is string {
            return failure(422, "Invalid payload: a durable agent is started with {query, input}");
        }
        foreach string key in input.keys() {
            if key != "query" && key != "input" {
                return failure(422, string `Invalid payload: unknown field '${key}' in the agent start envelope`);
            }
        }
        input = {agentName: typeValue, query: input["query"], input: input["input"]};
    }

    string? badPolicy = invalidPolicies(body["ifRunning"], body["ifClosed"]);
    if badPolicy is string {
        return failure(400, badPolicy);
    }
    string? requestedId = body["workflowId"] is string ? <string>body["workflowId"] : ();
    if requestedId is string {
        string? invalid = invalidWorkflowId(requestedId);
        if invalid is string {
            return failure(400, invalid);
        }
    }
    string workflowId = requestedId ?: uuidV7();
    map<json> memo = {workflowKind: kind};
    string? userId = caller.userId;
    if userId is string && userId.trim() != "" {
        memo["startedBy"] = userId;
    }
    map<json> request = {
        workflowId,
        workflowType: {name: TYPE_PREFIX + typeValue},
        taskQueue: {name: taskQueue},
        input: [input],
        memo: {fields: memo},
        searchAttributes: {indexedFields: {WorkflowKind: kind}},
        requestId: uuidV7(),
        identity: "workflow-runtime"
    };
    json timeout = body["timeoutSeconds"];
    if timeout is int || timeout is string {
        request["workflowExecutionTimeout"] = timeout.toString() + "s";
    }
    if requestedId is string {
        json ifRunning = body["ifRunning"];
        if ifRunning == "USE_EXISTING" || ifRunning == "TERMINATE_EXISTING" {
            request["workflowIdConflictPolicy"] = "WORKFLOW_ID_CONFLICT_POLICY_" + ifRunning.toString();
        }
        if ifRunning == "USE_EXISTING" {
            memo["startRequestId"] = uuidV7();
        }
        json ifClosed = body["ifClosed"];
        if ifClosed == "ALLOW_DUPLICATE_FAILED_ONLY" || ifClosed == "REJECT_DUPLICATE" {
            request["workflowIdReusePolicy"] = "WORKFLOW_ID_REUSE_POLICY_" + ifClosed.toString();
        }
    }
    json|http:Response started = check startExecution(request, workflowId);
    if started is http:Response {
        if started.statusCode == 409 {
            return failure(409, string `An instance with id '${workflowId}' already exists (status: RUNNING)`);
        }
        return failure(500, "Failed to start workflow: " + check started.getTextPayload());
    }
    boolean isNew = check started.started;
    return ok({workflowId, runId: check started.runId, started: isNew}, isNew ? 201 : 200);
}

isolated function findDefinition(IntegrationRecord[] scope, string workflowType)
        returns [IntegrationRecord, map<json>]? {
    foreach IntegrationRecord entry in scope {
        foreach map<json> def in definitionsOf(entry) {
            if def["workflowType"] == workflowType {
                return [entry, def];
            }
        }
    }
    return ();
}

isolated function invalidWorkflowId(string id) returns string? {
    if id.trim() == "" {
        return "instanceId must not be blank";
    }
    if id.trim() != id {
        return "instanceId must not have leading or trailing whitespace";
    }
    int length = id.toBytes().length();
    if length > 255 {
        return string `instanceId must be at most 255 bytes in UTF-8, got ${length}`;
    }
    foreach string prefix in RESERVED_ID_PREFIXES {
        if id.startsWith(prefix) {
            return string `instanceId must not start with the reserved prefix '${prefix}'`;
        }
    }
    return ();
}

isolated function invalidPolicies(json ifRunning, json ifClosed) returns string? {
    if ifRunning !is () && ifRunning != "FAIL" && ifRunning != "USE_EXISTING" && ifRunning != "TERMINATE_EXISTING" {
        return string `ifRunning must be one of FAIL, USE_EXISTING or TERMINATE_EXISTING, got '${ifRunning.toString()}'`;
    }
    if ifClosed !is () && ifClosed != "ALLOW_DUPLICATE" && ifClosed != "ALLOW_DUPLICATE_FAILED_ONLY"
            && ifClosed != "REJECT_DUPLICATE" {
        return string `ifClosed must be one of ALLOW_DUPLICATE, ALLOW_DUPLICATE_FAILED_ONLY or REJECT_DUPLICATE, `
            + string `got '${ifClosed.toString()}'`;
    }
    return ();
}

// Formats a role list as the module does (Java's List.toString): [a, b].
isolated function roleList(json value) returns string =>
    "[" + string:'join(", ", ...strings({v: value}, "v")) + "]";

// ---- human tasks ----

isolated function completeTask(IntegrationRecord? scope, string taskId, json body, Caller caller, boolean rejecting)
        returns Result|error {
    if caller.userId is () && caller.roles.length() == 0 {
        return failure(403, "Unauthorized: caller identity is required");
    }
    Execution|http:Response exec = check describeExecution(taskId);
    if exec is http:Response {
        return failure(404, string `Human task not found: '${taskId}'`);
    }
    Result? outOfScope = checkScope(scope, exec, "human task", taskId);
    if outOfScope is Result {
        return outOfScope;
    }
    string status = shortStatus(exec.status);
    if status != "RUNNING" {
        return failure(409, string `Human task '${taskId}' is not running (status=${status})`);
    }
    if exec.memo["workflowKind"] != HUMAN_TASK {
        return failure(404, string `Human task not found: '${taskId}' is not a human task workflow`);
    }
    json result = body is map<json> ? body["result"] : ();
    if !rejecting {
        string? invalid = validateAgainstFormSchema(result, exec.memo["formSchema"]);
        if invalid is string {
            json taskName = exec.memo["taskName"];
            return failure(422, string `Invalid payload for human task '${taskName.toString()}': ${invalid}`);
        }
    }
    string? access = accessOf(exec.memo, caller);
    if access is () {
        return failure(403, string `Unauthorized: caller does not have a required role to complete task '${taskId}'. `
                + string `Required one of: ${roleList(exec.memo["userRoles"])}`);
    }
    string completedAt = time:utcToString(time:utcNow());
    map<json> payload = {
        completedBy: caller.userId ?: "unknown",
        completedAt,
        completedAs: access,
        callerRoles: caller.roles.length() > 0 ? caller.roles : ()
    };
    if rejecting {
        payload["__rejected"] = true;
        payload["reason"] = body is map<json> ? body["reason"] : ();
        if body is map<json> && body["details"] is map<json> {
            payload["details"] = body["details"];
        }
    } else {
        payload["result"] = result;
    }
    if check alreadySignaled(taskId, "taskCompletion") {
        return failure(409, string `Human task '${taskId}' is not running (status=COMPLETED)`);
    }
    error? sent = signal(taskId, "taskCompletion", payload);
    if sent is error {
        return failure(409, string `Human task '${taskId}' completed or was no longer running`);
    }
    return ok({success: true, completedBy: caller.userId ?: "unknown", completedAt});
}

// ---- review activities ----

isolated function decideReview(IntegrationRecord? scope, string taskId, string action, json body, Caller caller)
        returns Result|error {
    Execution|http:Response exec = check describeExecution(taskId);
    if exec is http:Response {
        return failure(404, string `Review activity not found: '${taskId}'`);
    }
    if !isReview(exec) {
        return failure(404, string `Review activity not found: '${taskId}'`);
    }
    Result? outOfScope = checkScope(scope, exec, "review activity", taskId);
    if outOfScope is Result {
        return outOfScope;
    }
    if reviewAccessOf(exec.memo, caller) is () {
        return failure(403, "Unauthorized: caller is not allowed to decide this review activity");
    }
    string status = shortStatus(exec.status);
    if status != "RUNNING" {
        return failure(409, string `Retry task '${taskId}' is not running (status=${status})`);
    }
    string access = reviewAccessOf(exec.memo, caller) ?: "audience";
    string decidedAt = time:utcToString(time:utcNow());
    map<json> payload = {
        action,
        decidedBy: caller.userId ?: "unknown",
        completedAs: access,
        callerRoles: caller.roles.length() > 0 ? caller.roles : (),
        decidedAt
    };
    if action == "proceed-with-input" {
        json input = body is map<json> ? body["input"] : ();
        if input !is map<json> {
            return failure(400, "input must be a JSON object");
        }
        payload["input"] = input;
    }
    if action == "reject" && body is map<json> && body["feedback"] is string {
        payload["feedback"] = body["feedback"];
    }
    if check alreadySignaled(taskId, "taskDecision") {
        return failure(409, string `Retry task '${taskId}' is not running (status=COMPLETED)`);
    }
    error? sent = signal(taskId, "taskDecision", payload);
    if sent is error {
        return failure(409, string `Retry task '${taskId}' is not running (status=COMPLETED)`);
    }
    return ok({success: true, decision: action, completedBy: caller.userId ?: "unknown", completedAt: decidedAt});
}

// ---- administration: reassign, extend deadline ----

isolated function administer(IntegrationRecord? scope, string taskId, string kind, string action, map<json> fields,
        Caller caller) returns Result|error {
    if caller.userId is () && caller.roles.length() == 0 {
        return failure(403, "Unauthorized: caller identity is required");
    }
    string notFound = kind == HUMAN_TASK ? "Human task not found: " + taskId : "Review activity not found: " + taskId;
    Execution|http:Response exec = check describeExecution(taskId);
    if exec is http:Response {
        return failure(404, notFound);
    }
    json memoKind = exec.memo["workflowKind"];
    if (kind == HUMAN_TASK && memoKind != HUMAN_TASK) || (kind == REVIEW_ACTIVITY && !isReview(exec)) {
        return failure(404, notFound);
    }
    Result? outOfScope = checkScope(scope, exec, "task", taskId);
    if outOfScope is Result {
        return outOfScope;
    }
    string status = shortStatus(exec.status);
    if status != "RUNNING" {
        return failure(409, string `Task '${taskId}' is not running (status=${status})`);
    }
    if memoKind != HUMAN_TASK && memoKind != REVIEW_ACTIVITY {
        return failure(500, string `Invalid task: '${taskId}' is not a human task or review (workflowKind=${memoKind.toString()})`);
    }
    if !administers(exec.memo, caller) {
        return failure(403, string `Unauthorized: only an administrator of task '${taskId}' may ${action} it`);
    }
    map<json> payload = fields.clone();
    payload["action"] = action;
    payload["administeredBy"] = caller.userId ?: "unknown";
    payload["completedAt"] = time:utcToString(time:utcNow());
    error? sent = signal(taskId, "taskAdminister", payload);
    if sent is error {
        return failure(409, string `Failed to administer task '${taskId}': it was no longer running`);
    }
    return ok({success: true, action, administeredBy: caller.userId ?: "unknown",
        administeredAt: time:utcToString(time:utcNow())});
}

isolated function reassign(IntegrationRecord? scope, string taskId, string kind, json body, Caller caller)
        returns Result|error {
    if caller.userId is () && caller.roles.length() == 0 {
        return failure(403, "Unauthorized: caller identity is required");
    }
    string invalid = "The audience must be lists of strings under userRoles, users, excludedUsers or excludedRoles";
    if body !is map<json> {
        return failure(400, invalid);
    }
    foreach [string, json] [key, value] in body.entries() {
        if AUDIENCE_KEYS.indexOf(key) is () || value !is json[] || value.some(v => v !is string) {
            return failure(400, invalid);
        }
    }
    if body.length() == 0 {
        return failure(400, "Name at least one audience list to replace");
    }
    return administer(scope, taskId, kind, "reassign", body, caller);
}

isolated function extendDeadline(IntegrationRecord? scope, string taskId, string kind, json body, Caller caller)
        returns Result|error {
    if caller.userId is () && caller.roles.length() == 0 {
        return failure(403, "Unauthorized: caller identity is required");
    }
    json timeout = body is map<json> ? body["timeoutMillis"] : ();
    if timeout !is int? || (timeout is int && timeout <= 0) {
        return failure(400, "timeoutMillis must be positive, or absent to clear the deadline");
    }
    return administer(scope, taskId, kind, "extendDeadline", {timeoutMillis: timeout}, caller);
}

// ---- bulk retry ----

isolated function bulkRetry(IntegrationRecord? scope, json body, Caller caller) returns Result|error {
    map<json> params = body is map<json> ? body : {};
    json action = params["action"];
    if action != "retry" && action != "fail" {
        return failure(400, string `Unknown bulk retry action: ${action.toString()} (expected "retry" or "fail")`);
    }
    json taskIds = params["taskIds"];
    json parent = params["parentWorkflowId"];
    json activityName = params["activityName"];
    boolean byIds = taskIds !is ();
    boolean byParent = parent is string && parent.trim().length() > 0;
    if byIds && byParent {
        return failure(400, "Specify either taskIds or parentWorkflowId, not both");
    }
    if !byIds && !byParent {
        return failure(400, "Either taskIds or parentWorkflowId is required");
    }
    string[] candidates = [];
    if byIds {
        if activityName is string {
            return failure(400, "activityName narrows a parentWorkflowId selection; it cannot be combined with taskIds");
        }
        if taskIds !is json[] {
            return failure(400, "taskIds must be an array");
        }
        if taskIds.length() == 0 {
            return failure(400, "taskIds must not be empty");
        }
        foreach json id in taskIds {
            if id !is string || id.trim().length() == 0 {
                return failure(400, "taskIds must contain non-empty strings");
            }
            if candidates.indexOf(id) is () {
                candidates.push(id);
            }
        }
    } else {
        string query = string `WorkflowType STARTS_WITH '${REVIEW_TYPE_PREFIX}' AND ExecutionStatus = 'Running'`;
        foreach map<json> e in check listExecutions(query, maxBulkRetrySize * 10) {
            map<json> memo = memoFields(e["memo"]);
            json trigger = memo["trigger"] ?: ON_FAILURE;
            if memo["parentWorkflowId"] != parent || trigger != ON_FAILURE {
                continue;
            }
            if activityName is string && memo["activityName"] != activityName {
                continue;
            }
            json execution = e["execution"];
            if execution is map<json> && execution["workflowId"] is string {
                candidates.push(<string>execution["workflowId"]);
            }
        }
    }
    if candidates.length() > maxBulkRetrySize {
        return failure(400, string `Too many review activities in one bulk decision (maximum is ${maxBulkRetrySize})`);
    }
    string decision = action == "retry" ? "proceed" : "reject";
    json decisionBody = action == "fail" && params["feedback"] is string ? {feedback: params["feedback"]} : {};
    json[] items = [];
    int applied = 0;
    int skipped = 0;
    int failed = 0;
    foreach string taskId in candidates {
        [string, string?] [outcome, reason] = check decideOneInBulk(scope, taskId, decision, decisionBody, caller);
        items.push({taskId, outcome, reason});
        if outcome == "APPLIED" {
            applied += 1;
        } else if outcome == "SKIPPED" {
            skipped += 1;
        } else {
            failed += 1;
        }
    }
    return ok({
        action: action.toString(),
        requested: candidates.length(),
        applied,
        skipped,
        failed,
        items,
        decidedBy: caller.userId ?: "unknown",
        decidedAt: time:utcToString(time:utcNow())
    });
}

isolated function decideOneInBulk(IntegrationRecord? scope, string taskId, string decision, json body, Caller caller)
        returns [string, string?]|error {
    Execution|http:Response exec = check describeExecution(taskId);
    if exec is http:Response || !isReview(exec) {
        return ["FAILED", string `Review activity not found: '${taskId}'`];
    }
    if reviewAccessOf(exec.memo, caller) is () {
        return ["FAILED", "Unauthorized: caller is not allowed to decide this review activity"];
    }
    json trigger = exec.memo["trigger"] ?: ON_FAILURE;
    if trigger != ON_FAILURE {
        return ["SKIPPED", "Not a failed-activity review: this review gates a proposed call"];
    }
    string status = taskStatus(exec.status);
    if status != "PENDING" {
        return ["SKIPPED", "Already decided: the review activity is " + status];
    }
    Result result = check decideReview(scope, taskId, decision, body, caller);
    if result.status == 200 {
        return ["APPLIED", ()];
    }
    json message = result.body is map<json> ? (check result.body.'error.message) : ();
    return [result.status == 409 ? "SKIPPED" : "FAILED", message.toString()];
}

// ---- shared checks ----

isolated function isReview(Execution exec) returns boolean {
    json kind = exec.memo["workflowKind"];
    return kind == REVIEW_ACTIVITY || kind == RETRY_TASK;
}

isolated function checkScope(IntegrationRecord? scope, Execution exec, string what, string taskId) returns Result? {
    if scope is IntegrationRecord && scope.taskQueue != exec.taskQueue {
        return failure(403, string `Unauthorized: ${what} '${taskId}' belongs to task queue '${exec.taskQueue}', `
                + string `which is served by a different integration`);
    }
    return ();
}

isolated function shortStatus(string status) returns string =>
    status.startsWith("WORKFLOW_EXECUTION_STATUS_") ? status.substring(26) : status;

isolated function taskStatus(string status) returns string {
    string s = shortStatus(status);
    if s == "RUNNING" {
        return "PENDING";
    }
    return s == "TIMED_OUT" ? "FAILED" : s;
}

isolated function strings(map<json> memo, string key) returns string[] {
    json value = memo[key];
    if value is json[] {
        return from json v in value where v is string select v;
    }
    if value is string {
        return [value];
    }
    return [];
}

isolated function namesAudience(map<json> memo) returns boolean =>
    strings(memo, "userRoles").length() + strings(memo, "users").length() + strings(memo, "excludedUsers").length()
        + strings(memo, "excludedRoles").length() > 0;

// Task assignment as the module decides it: "audience", "administrator", or () when denied.
isolated function accessOf(map<json> memo, Caller caller) returns string? {
    string? userId = caller.userId;
    if intersects(caller.roles, strings(memo, "excludedRoles")) {
        return ();
    }
    string[] excludedUsers = strings(memo, "excludedUsers");
    if excludedUsers.length() > 0 && (userId is () || excludedUsers.indexOf(userId) !is ()) {
        return ();
    }
    string[] userRoles = strings(memo, "userRoles");
    string[] users = strings(memo, "users");
    if userRoles.length() == 0 && users.length() == 0 {
        return "audience";
    }
    if intersects(caller.roles, userRoles) || (userId is string && users.indexOf(userId) !is ()) {
        return "audience";
    }
    return administers(memo, caller) ? "administrator" : ();
}

// A review that names nobody is open to every caller.
isolated function reviewAccessOf(map<json> memo, Caller caller) returns string? =>
    namesAudience(memo) ? accessOf(memo, caller) : "audience";

isolated function administers(map<json> memo, Caller caller) returns boolean {
    string? userId = caller.userId;
    return intersects(caller.roles, strings(memo, "administratorRoles"))
        || (userId is string && strings(memo, "administratorUsers").indexOf(userId) !is ());
}

isolated function intersects(string[] a, string[] b) returns boolean {
    foreach string item in a {
        if b.indexOf(item) !is () {
            return true;
        }
    }
    return false;
}

isolated function uuidV7() returns string {
    time:Utc now = time:utcNow();
    int ms = now[0] * 1000 + <int>(now[1] * 1000);
    byte[] b = [];
    foreach int shift in [40, 32, 24, 16, 8, 0] {
        b.push(<byte>((ms >> shift) & 0xff));
    }
    foreach int _ in 0 ..< 10 {
        int|random:Error r = random:createIntInRange(0, 256);
        b.push(<byte>(r is int ? r : 0));
    }
    b[6] = <byte>((b[6] & 0x0f) | 0x70);
    b[8] = <byte>((b[8] & 0x3f) | 0x80);
    string h = b.toBase16();
    return string `${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-`
        + h.substring(20);
}
