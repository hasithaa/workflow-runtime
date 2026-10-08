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
import ballerina/io;
import ballerina/jwt;

// Issues Temporal access tokens (RS256) and serves the JWKS Temporal's JWT authorizer trusts.

# Port of the token issuer and the JWKS endpoint.
configurable int tokenPort = 9480;

# PEM RSA private key that signs Temporal access tokens.
configurable string tokenKeyFile = "secrets/token-signing.key";

# JWKS document with the matching public key, served to Temporal's JWT authorizer.
configurable string jwksFile = "secrets/jwks.json";

# Key ID of the signing key, as listed in the JWKS.
configurable string tokenKeyId = "runtime-1";

# Lifetime of issued worker tokens, in seconds.
configurable decimal workerTokenSeconds = 31536000;

# Key an operator sends as `x-admin-key` to issue tokens; empty disables the token endpoint.
configurable string adminApiKey = "";

final readonly & string[] TEMPORAL_ROLES = ["read", "write", "worker", "admin"];

service / on new http:Listener(tokenPort) {

    isolated resource function get jwks\.json() returns json|error => io:fileReadJson(jwksFile);

    // Body: {"namespace": "finance", "roles": ["worker", "write"]} or {"system": true} for the runtime's own admin token.
    isolated resource function post runtime/tokens(@http:Header {name: "x-admin-key"} string? key,
            @http:Payload json body) returns json|http:BadRequest|http:Unauthorized|error {
        if adminApiKey == "" || key != adminApiKey {
            return <http:Unauthorized>{body: {"error": {"message": "A valid x-admin-key is required"}}};
        }
        string[] permissions = [];
        if body is map<json> && body["system"] == true {
            permissions.push("temporal-system:admin");
        } else {
            json ns = body is map<json> ? body["namespace"] : ();
            json roles = body is map<json> ? body["roles"] : ();
            if ns !is string || roles !is json[] {
                return <http:BadRequest>{body: {"error": {"message": "namespace and roles are required"}}};
            }
            foreach json role in roles {
                if role !is string || TEMPORAL_ROLES.indexOf(role) is () {
                    return <http:BadRequest>{body: {"error": {"message": string `Unknown role: ${role.toString()}`}}};
                }
                permissions.push(ns + ":" + role);
            }
        }
        string token = check issueTemporalToken(permissions, workerTokenSeconds);
        return {token, permissions};
    }
}

isolated function issueTemporalToken(string[] permissions, decimal lifetime) returns string|error =>
    jwt:issue({
        issuer: "workflow-runtime",
        username: "workflow-runtime",
        keyId: tokenKeyId,
        expTime: lifetime,
        customClaims: {"permissions": permissions},
        signatureConfig: {algorithm: jwt:RS256, config: {keyFile: tokenKeyFile}}
    });
