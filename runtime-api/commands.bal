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
import ballerina/workflow.management;

// Executes Workflow Management commands ({operation, params, identity}, the format ICP's command tunnel carries) for one
// registered integration. Owner-bound operations run here against Temporal; the rest run in the embedded module.

# Key a trusted caller (such as ICP) sends as `x-runtime-key`; empty disables the commands endpoint.
configurable string commandApiKey = "";

final readonly & string[] SCOPED_LIST_OPERATIONS = [
    "instances.list", "humanTasks.list", "workItems.list", "humanTasks.pendingCount", "reviewActivities.list"
];

service /runtime on new http:Listener(commandPort) {

    isolated resource function post integrations/[string name]/commands(
            @http:Header {name: "x-runtime-key"} string? key, @http:Payload json command) returns http:Response|error {
        if commandApiKey == "" || key != commandApiKey {
            return respond(failure(401, "A valid x-runtime-key is required"));
        }
        IntegrationRecord? entry = integrationNamed(name);
        if entry is () {
            return respond(failure(404, string `Integration '${name}' is not registered with this runtime`));
        }
        return respond(check executeFor(entry, command));
    }

    // Managed runtimes and their liveness, for a console that mirrors them.
    isolated resource function get integrations(@http:Header {name: "x-runtime-key"} string? key) returns http:Response {
        if commandApiKey == "" || key != commandApiKey {
            return respond(failure(401, "A valid x-runtime-key is required"));
        }
        return respond(ok(integrationsView()));
    }

    // The registered metadata document of an integration's current checksum.
    isolated resource function get integrations/[string name]/metadata(@http:Header {name: "x-runtime-key"} string? key)
            returns http:Response {
        if commandApiKey == "" || key != commandApiKey {
            return respond(failure(401, "A valid x-runtime-key is required"));
        }
        IntegrationRecord? entry = integrationNamed(name);
        string? checksum = entry is IntegrationRecord ? entry.currentChecksum : ();
        if entry is () || checksum is () {
            return respond(failure(404, string `Integration '${name}' is not registered with this runtime`));
        }
        return respond(ok(entry.descriptors[checksum]));
    }
}

isolated function integrationsView() returns json {
    json[] out = [];
    foreach IntegrationRecord entry in allIntegrations() {
        json[] runtimes = from RuntimeRecord rt in entry.runtimes select {...rt, online: isOnline(rt)};
        out.push({
            name: entry.name,
            namespace: entry.namespace,
            taskQueue: entry.taskQueue,
            checksum: entry.currentChecksum,
            knownChecksums: entry.descriptors.keys(),
            runtimes
        });
    }
    return {integrations: out};
}

# Port of the commands endpoint, separate from the public Workflow Management API.
configurable int commandPort = 9490;

isolated function executeFor(IntegrationRecord scope, json command) returns Result|error {
    if command !is map<json> || command["operation"] !is string {
        return failure(400, "A command needs an operation");
    }
    string operation = <string>command["operation"];
    json rawParams = command["params"];
    map<json> params = rawParams is map<json> ? rawParams.clone() : {};
    Caller caller = callerFrom(command["identity"]);
    string taskId = params["taskId"] is string ? <string>params["taskId"] : "";
    match operation {
        "definitions.list" => {
            return definitions([scope]);
        }
        "runtime.info" => {
            return ok({taskQueue: scope.taskQueue});
        }
        "instances.start" => {
            return startInstance([scope], params, caller);
        }
        "humanTasks.complete" => {
            return completeTask(scope, taskId, params, caller, false);
        }
        "humanTasks.fail" => {
            return completeTask(scope, taskId, params, caller, true);
        }
        "reviewActivities.decide" => {
            json action = params["action"];
            if action != "proceed" && action != "proceed-with-input" && action != "reject" {
                return failure(400, "Unknown review decision action");
            }
            return decideReview(scope, taskId, <string>action, params, caller);
        }
        "tasks.reassign" => {
            map<json> audience = {};
            foreach string key in AUDIENCE_KEYS {
                if params.hasKey(key) {
                    audience[key] = params[key];
                }
            }
            return reassign(scope, taskId, kindOf(params), audience, caller);
        }
        "tasks.extendDeadline" => {
            return extendDeadline(scope, taskId, kindOf(params), params, caller);
        }
        "reviewActivities.bulkRetry" => {
            return bulkRetry(scope, params, caller);
        }
    }
    if SCOPED_LIST_OPERATIONS.indexOf(operation) !is () && !params.hasKey("taskQueue") {
        params["taskQueue"] = scope.taskQueue;
    }
    map<json> raw = {operation, params, identity: {userId: caller.userId, roles: caller.roles}};
    management:Command|error typed = raw.cloneWithType();
    if typed is error {
        return failure(400, "Unknown operation: " + operation);
    }
    json|management:Error result = management:executeCommand(typed);
    if result is management:Error {
        return {status: statusOf(management:errorCodeOf(result)), body: management:toErrorJson(result)};
    }
    return ok(result, operation == "instances.start" ? 201 : 200);
}

isolated function kindOf(map<json> params) returns string =>
    params["kind"] == REVIEW_ACTIVITY ? REVIEW_ACTIVITY : HUMAN_TASK;

isolated function callerFrom(json identity) returns Caller {
    if identity !is map<json> {
        return {userId: (), roles: []};
    }
    json userId = identity["userId"];
    json roles = identity["roles"];
    string[] roleList = [];
    if roles is json[] {
        foreach json r in roles {
            if r is string {
                roleList.push(r);
            }
        }
    }
    return {userId: userId is string && userId.trim() != "" ? userId : (), roles: roleList};
}

isolated function statusOf(management:ErrorCode code) returns int {
    match code {
        management:NOT_FOUND => {
            return 404;
        }
        management:ACCESS_DENIED => {
            return 403;
        }
        management:INVALID_REQUEST => {
            return 400;
        }
        management:CONFLICT => {
            return 409;
        }
        management:INVALID_PAYLOAD => {
            return 422;
        }
    }
    return 500;
}
