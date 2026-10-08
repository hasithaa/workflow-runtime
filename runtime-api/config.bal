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

# A registration key: the workflow runtime bridge signs with it, and it decides the namespace.
#
# + keyId - Key ID the bridge sends as the token's `kid`
# + keyMaterial - Shared HS256 key, at least 32 bytes
# + namespace - Temporal namespace the registering integration runs in
type RegistrationKey record {|
    string keyId;
    string keyMaterial;
    string namespace;
|};

# Keys the workflow runtime bridge may register with.
configurable RegistrationKey[] registrationKeys = [];

# Temporal namespace this runtime manages.
configurable string namespace = "default";

# Temporal HTTP API base URL (the frontend's HTTP port), e.g. `https://temporal:7243`.
configurable string temporalHttpUrl = "http://localhost:7243";

# PEM CA certificate that signed Temporal's frontend certificate; empty uses the default trust store.
configurable string temporalCaCert = "";

# Sends a runtime-signed system token on every Temporal call; needs Temporal's JWT authorizer to trust this runtime.
configurable boolean temporalAuth = false;

# Port of the registration endpoints the bridge calls.
configurable int registrationPort = 9460;

# Port of the Workflow Management API.
configurable int apiPort = 9470;

# Base URL of the embedded workflow module's management API, which serves reads and lifecycle operations.
configurable string managementUrl = "http://localhost:8240/workflow";

# Heartbeat interval the runtime asks bridges for, in seconds.
configurable int heartbeatSeconds = 60;

# Missed heartbeats before a runtime counts as offline.
configurable int offlineAfterMissedBeats = 3;

# Largest number of review activities one bulk retry may decide.
configurable int maxBulkRetrySize = 100;
