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

import ballerina/time;

type RuntimeRecord record {|
    string runtimeId;
    string integration;
    string runtime;
    string namespace;
    string? taskQueue;
    string checksum;
    string? integrationVersion;
    string bridgeVersion;
    string startedAt;
    string lastSeen;
|};

type IntegrationRecord record {|
    string name;
    string namespace;
    string? taskQueue = ();
    string? currentChecksum = ();
    map<json> descriptors = {};
    map<RuntimeRecord> runtimes = {};
|};

isolated map<IntegrationRecord> integrations = {};

isolated function nowString() returns string => time:utcToString(time:utcNow());

isolated function recordRegistration(json body, string ns) returns error? {
    map<json> reg = check body.ensureType();
    string name = check reg["integration"].ensureType();
    string checksum = check reg["checksum"].ensureType();
    RuntimeRecord rt = {
        runtimeId: check reg["runtimeId"].ensureType(),
        integration: name,
        runtime: check reg["runtime"].ensureType(),
        namespace: ns,
        taskQueue: check reg["taskQueue"].ensureType(),
        checksum,
        integrationVersion: check reg["integrationVersion"].ensureType(),
        bridgeVersion: check reg["bridgeVersion"].ensureType(),
        startedAt: check reg["startedAt"].ensureType(),
        lastSeen: nowString()
    };
    json metadata = reg["metadata"];
    lock {
        IntegrationRecord entry = integrations[name] ?: {name, namespace: ns};
        entry.taskQueue = rt.taskQueue;
        entry.currentChecksum = checksum;
        entry.descriptors[checksum] = metadata.clone();
        entry.runtimes[rt.runtimeId] = rt.clone();
        integrations[name] = entry;
    }
}

// Returns true when the runtime and its checksum are known, i.e. no new registration is needed.
isolated function recordHeartbeat(json body) returns boolean|error {
    map<json> beat = check body.ensureType();
    string name = check beat["integration"].ensureType();
    string runtimeId = check beat["runtimeId"].ensureType();
    string checksum = check beat["checksum"].ensureType();
    lock {
        IntegrationRecord? entry = integrations[name];
        if entry is () || !entry.descriptors.hasKey(checksum) {
            return false;
        }
        RuntimeRecord? rt = entry.runtimes[runtimeId];
        if rt is () {
            return false;
        }
        rt.lastSeen = nowString();
        rt.checksum = checksum;
        return true;
    }
}

isolated function isOnline(RuntimeRecord rt) returns boolean {
    time:Utc|error seen = time:utcFromString(rt.lastSeen);
    if seen is error {
        return false;
    }
    return time:utcDiffSeconds(time:utcNow(), seen) < <decimal>(heartbeatSeconds * offlineAfterMissedBeats);
}

isolated function integrationNamed(string name) returns IntegrationRecord? {
    lock {
        return integrations[name].clone();
    }
}

isolated function allIntegrations() returns IntegrationRecord[] {
    lock {
        return integrations.toArray().clone();
    }
}

isolated function integrationForQueue(string taskQueue) returns IntegrationRecord? {
    lock {
        foreach IntegrationRecord entry in integrations {
            if entry.taskQueue == taskQueue {
                return entry.clone();
            }
        }
        return ();
    }
}
