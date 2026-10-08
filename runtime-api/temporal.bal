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
import ballerina/url;

// Temporal's HTTP API. json/plain payloads travel as plain JSON (shorthand form), so memo reads and signals need no
// payload encoding.

final http:Client temporal = check newTemporalClient();

function newTemporalClient() returns http:Client|error {
    http:ClientConfiguration config = {timeout: 30};
    if temporalCaCert != "" {
        config.secureSocket = {cert: temporalCaCert};
    }
    return new (temporalHttpUrl, config);
}

type Execution record {|
    string taskQueue;
    string status;
    map<json> memo;
|};

isolated function headers() returns map<string>|error {
    if !temporalAuth {
        return {};
    }
    string token = check issueTemporalToken(["temporal-system:admin"], 300);
    return {"Authorization": "Bearer " + token};
}

isolated function describeExecution(string workflowId) returns Execution|http:Response|error {
    http:Response response = check temporal->get(string `/api/v1/namespaces/${namespace}/workflows/${workflowId}`,
            check headers());
    if response.statusCode != 200 {
        return response;
    }
    json body = check response.getJsonPayload();
    json info = check body.workflowExecutionInfo;
    return {
        taskQueue: check body.executionConfig.taskQueue.name,
        status: check info.status,
        memo: memoFields(check info.memo)
    };
}

isolated function memoFields(json memo) returns map<json> {
    if memo is map<json> {
        json fields = memo["fields"];
        if fields is map<json> {
            return fields;
        }
    }
    return {};
}

isolated function signal(string workflowId, string name, json payload) returns error? {
    http:Response response = check temporal->post(
            string `/api/v1/namespaces/${namespace}/workflows/${workflowId}/signal/${name}`,
            {input: [payload], identity: "workflow-runtime"}, check headers());
    if response.statusCode == 404 {
        return error(string `Task '${workflowId}' was no longer running`);
    }
    if response.statusCode != 200 {
        return error(string `Signal ${name} failed: ${response.statusCode} ${check response.getTextPayload()}`);
    }
}

isolated function startExecution(map<json> request, string workflowId) returns json|http:Response|error {
    http:Response response = check temporal->post(
            string `/api/v1/namespaces/${namespace}/workflows/${workflowId}`, request, check headers());
    if response.statusCode != 200 {
        return response;
    }
    return response.getJsonPayload();
}

// Lists executions matching a visibility query, with their memo; follows pages up to `max` results.
isolated function listExecutions(string query, int max) returns map<json>[]|error {
    map<json>[] out = [];
    string? token = ();
    while out.length() < max {
        string path = string `/api/v1/namespaces/${namespace}/workflows?query=${check urlEncode(query)}&pageSize=100`;
        if token is string && token != "" {
            path += "&nextPageToken=" + check urlEncode(token);
        }
        http:Response response = check temporal->get(path, check headers());
        if response.statusCode != 200 {
            return error(string `Listing failed: ${response.statusCode} ${check response.getTextPayload()}`);
        }
        json body = check response.getJsonPayload();
        json executions = body is map<json> ? body["executions"] : ();
        if executions is json[] {
            foreach json e in executions {
                if e is map<json> {
                    out.push(e);
                }
            }
        }
        json next = body is map<json> ? body["nextPageToken"] : ();
        if next !is string || next == "" {
            break;
        }
        token = next;
    }
    return out;
}

isolated function urlEncode(string value) returns string|error => url:encode(value, "UTF-8");

// Reports whether a signal of this name already reached the workflow; closes the window between describe and signal.
isolated function alreadySignaled(string workflowId, string name) returns boolean|error {
    http:Response response = check temporal->get(
            string `/api/v1/namespaces/${namespace}/workflows/${workflowId}/history?maximumPageSize=1000`, check headers());
    if response.statusCode != 200 {
        return false;
    }
    json body = check response.getJsonPayload();
    json events = check body.history.events;
    if events !is json[] {
        return false;
    }
    foreach json event in events {
        if event is map<json> && event["eventType"] == "EVENT_TYPE_WORKFLOW_EXECUTION_SIGNALED" {
            json attrs = event["workflowExecutionSignaledEventAttributes"];
            if attrs is map<json> && attrs["signalName"] == name {
                return true;
            }
        }
    }
    return false;
}
