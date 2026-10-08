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
import ballerina/workflow as _;
import ballerina/workflow.management.rest as _;

// Serves the Workflow Management API per integration and per namespace. Reads and lifecycle go to the
// in-process management API (the module, no workers); the four owner-bound operations run here.

final http:Client management = check new (managementUrl);

final string[] & readonly SCOPED_LISTS = ["workflows", "human-tasks", "review-activities"];

service / on new http:Listener(apiPort) {

    isolated resource function 'default integrations/[string name]/workflow/[string... path](http:Request req)
            returns http:Response|error {
        IntegrationRecord? entry = integrationNamed(name);
        if entry is () {
            return respond(failure(404, string `Integration '${name}' is not registered with this runtime`));
        }
        return dispatch(entry, path, req);
    }

    isolated resource function 'default workflow/[string... path](http:Request req) returns http:Response|error {
        return dispatch((), path, req);
    }

    // The registered metadata document of an integration's current checksum.
    isolated resource function get runtime/integrations/[string name]/metadata() returns json|http:NotFound {
        IntegrationRecord? entry = integrationNamed(name);
        string? checksum = entry is IntegrationRecord ? entry.currentChecksum : ();
        if entry is () || checksum is () {
            return http:NOT_FOUND;
        }
        return entry.descriptors[checksum];
    }

    // Admin view of managed runtimes: registrations, liveness, task queues.
    isolated resource function get runtime/integrations() returns json => integrationsView();
}

isolated function dispatch(IntegrationRecord? scope, string[] path, http:Request req) returns http:Response|error {
    string method = req.method;
    Caller caller = callerOf(req);
    IntegrationRecord[] all = allIntegrations();
    if scope is IntegrationRecord {
        all = [scope];
    }
    int n = path.length();
    if method == "GET" && n == 1 && path[0] == "definitions" {
        return respond(definitions(all));
    }
    if method == "POST" && n == 1 && path[0] == "workflows" {
        return respond(check startInstance(all, check bodyOf(req), caller));
    }
    if method == "POST" && n == 3 && path[0] == "human-tasks" && (path[2] == "complete" || path[2] == "fail") {
        return respond(check completeTask(scope, path[1], check bodyOf(req), caller, path[2] == "fail"));
    }
    if method == "POST" && n == 3 && path[0] == "review-activities"
            && (path[2] == "proceed" || path[2] == "proceed-with-input" || path[2] == "reject") {
        return respond(check decideReview(scope, path[1], path[2], check bodyOf(req), caller));
    }
    if method == "POST" && n == 2 && path[0] == "review-activities" && path[1] == "bulk-retry" {
        return respond(check bulkRetry(scope, check bodyOf(req), caller));
    }
    if method == "POST" && n == 3 && (path[0] == "human-tasks" || path[0] == "review-activities")
            && (path[2] == "reassign" || path[2] == "deadline") {
        string kind = path[0] == "human-tasks" ? HUMAN_TASK : REVIEW_ACTIVITY;
        json body = check bodyOf(req);
        return respond(path[2] == "reassign" ? check reassign(scope, path[1], kind, body, caller)
            : check extendDeadline(scope, path[1], kind, body, caller));
    }
    return proxy(scope, path, req);
}

isolated function proxy(IntegrationRecord? scope, string[] path, http:Request req) returns http:Response|error {
    map<string[]> query = req.getQueryParams().clone();
    string? queue = scope is IntegrationRecord ? scope.taskQueue : ();
    if queue is string && path.length() >= 1 && SCOPED_LISTS.indexOf(path[0]) !is ()
            && (path.length() == 1 || path[1] == "pending-count") && !query.hasKey("taskQueue") {
        query["taskQueue"] = [queue];
    }
    string target = "/" + string:'join("/", ...path);
    string[] pairs = [];
    foreach [string, string[]] [key, values] in query.entries() {
        foreach string v in values {
            pairs.push(key + "=" + v);
        }
    }
    if pairs.length() > 0 {
        target += "?" + string:'join("&", ...pairs);
    }
    http:Request out = new;
    foreach string header in ["x-user-id", "x-user-roles", "content-type"] {
        string|http:HeaderNotFoundError value = req.getHeader(header);
        if value is string {
            out.setHeader(header, value);
        }
    }
    byte[]|error payload = req.getBinaryPayload();
    if payload is byte[] && payload.length() > 0 {
        out.setBinaryPayload(payload);
    }
    return management->execute(req.method, target, out);
}

isolated function callerOf(http:Request req) returns Caller {
    string|http:HeaderNotFoundError user = req.getHeader("x-user-id");
    string|http:HeaderNotFoundError roles = req.getHeader("x-user-roles");
    string[] roleList = roles is string
        ? from string r in re `,`.split(roles) where r.trim() != "" select r.trim()
        : [];
    return {userId: user is string && user.trim() != "" ? user.trim() : (), roles: roleList};
}

isolated function bodyOf(http:Request req) returns json|error {
    byte[] payload = check req.getBinaryPayload();
    return payload.length() == 0 ? {} : (check string:fromBytes(payload)).fromJsonString();
}

isolated function respond(Result result) returns http:Response {
    http:Response response = new;
    response.statusCode = result.status;
    response.setJsonPayload(result.body);
    return response;
}
