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
import ballerina/jwt;
import ballerina/log;

// Registration and heartbeat endpoints for the workflow runtime bridge (protocol version 1).
service /runtime on new http:Listener(registrationPort) {

    isolated resource function post register(@http:Header string? authorization, @http:Payload json body)
            returns json|http:Unauthorized|http:BadRequest {
        string|error ns = namespaceOf(authorization);
        if ns is error {
            return <http:Unauthorized>{body: {"error": {"message": ns.message()}}};
        }
        error? stored = recordRegistration(body, ns);
        if stored is error {
            return <http:BadRequest>{body: {"error": {"message": stored.message()}}};
        }
        log:printInfo("Integration registered", integration = (body is map<json> ? body["integration"] : ()).toString(),
                runtime = (body is map<json> ? body["runtime"] : ()).toString(), namespace = ns);
        return {registrationRequired: false, nextHeartbeatInSeconds: heartbeatSeconds};
    }

    isolated resource function post heartbeat(@http:Header string? authorization, @http:Payload json body)
            returns json|http:Unauthorized|http:BadRequest {
        string|error ns = namespaceOf(authorization);
        if ns is error {
            return <http:Unauthorized>{body: {"error": {"message": ns.message()}}};
        }
        boolean|error known = recordHeartbeat(body);
        if known is error {
            return <http:BadRequest>{body: {"error": {"message": known.message()}}};
        }
        return {registrationRequired: !known, nextHeartbeatInSeconds: heartbeatSeconds};
    }
}

// Verifies the bridge's HS256 token and returns the namespace its key is scoped to.
isolated function namespaceOf(string? authorization) returns string|error {
    if authorization is () || !authorization.startsWith("Bearer ") {
        return error("Bearer token required");
    }
    string token = authorization.substring(7);
    [jwt:Header, jwt:Payload] [header, _] = check jwt:decode(token);
    foreach RegistrationKey key in registrationKeys {
        if key.keyId == header.kid {
            _ = check jwt:validate(token, {
                issuer: "workflow-runtime-bridge",
                audience: "workflow-runtime",
                signatureConfig: {secret: key.keyMaterial}
            });
            return key.namespace;
        }
    }
    return error("Unknown key id");
}
