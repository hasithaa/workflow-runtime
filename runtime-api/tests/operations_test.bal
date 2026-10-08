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

import ballerina/test;

final readonly & map<json> TASK_MEMO = {
    userRoles: ["manager"],
    administratorRoles: ["expense-admin"],
    administratorUsers: ["root"],
    excludedUsers: ["mallory"]
};

@test:Config {}
function grantsTheAudience() {
    test:assertEquals(accessOf(TASK_MEMO, {userId: "alice", roles: ["manager"]}), "audience");
}

@test:Config {}
function grantsAdministratorsByRoleOrUser() {
    test:assertEquals(accessOf(TASK_MEMO, {userId: "carol", roles: ["expense-admin"]}), "administrator");
    test:assertEquals(accessOf(TASK_MEMO, {userId: "root", roles: []}), "administrator");
}

@test:Config {}
function deniesOthersAndExcludedUsers() {
    test:assertEquals(accessOf(TASK_MEMO, {userId: "bob", roles: ["clerk"]}), ());
    test:assertEquals(accessOf(TASK_MEMO, {userId: "mallory", roles: ["manager"]}), ());
    test:assertEquals(accessOf(TASK_MEMO, {userId: (), roles: ["manager"]}), (), "excluded users need a known caller");
}

@test:Config {}
function excludedRoleWins() {
    map<json> memo = {userRoles: ["manager"], excludedRoles: ["contractor"]};
    test:assertEquals(accessOf(memo, {userId: "dan", roles: ["manager", "contractor"]}), ());
}

@test:Config {}
function opensTasksWithoutAudience() {
    test:assertEquals(accessOf({}, {userId: "anyone", roles: []}), "audience");
    test:assertEquals(reviewAccessOf({administratorRoles: ["ops"]}, {userId: "x", roles: []}), "audience");
}

@test:Config {}
function onlyAdministratorsAdminister() {
    test:assertTrue(administers(TASK_MEMO, {userId: "carol", roles: ["expense-admin"]}));
    test:assertFalse(administers(TASK_MEMO, {userId: "alice", roles: ["manager"]}));
}

const string FORM = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"REJECT\",\"REQUEST_BILL\"]},"
    + "\"comment\":{\"type\":\"string\"},\"amount\":{\"type\":\"number\"}},\"required\":[\"action\"],\"additionalProperties\":false}";

@test:Config {}
function acceptsAValidResult() {
    test:assertEquals(validateAgainstFormSchema({action: "REJECT", comment: "no", amount: 12.5}, FORM), ());
}

@test:Config {}
function reportsTheFirstSchemaViolation() {
    test:assertEquals(validateAgainstFormSchema({comment: "x"}, FORM), "$.action is required");
    test:assertEquals(validateAgainstFormSchema({action: "MAYBE"}, FORM), "$.action must be one of [\"REJECT\", \"REQUEST_BILL\"]");
    test:assertEquals(validateAgainstFormSchema({action: "REJECT", amount: "ten"}, FORM), "$.amount must be number");
    test:assertEquals(validateAgainstFormSchema({action: "REJECT", extra: 1}, FORM), "$.extra is not allowed");
    test:assertEquals(validateAgainstFormSchema("REJECT", FORM), "$ must be object");
}

@test:Config {}
function skipsTheCheckWithoutASchema() {
    test:assertEquals(validateAgainstFormSchema({anything: true}, ()), ());
    test:assertEquals(validateAgainstFormSchema({anything: true}, "not json"), ());
}

@test:Config {}
function rejectsReservedAndMalformedIds() {
    test:assertEquals(invalidWorkflowId("order-1"), ());
    test:assertTrue(invalidWorkflowId("humantask-1") is string);
    test:assertTrue(invalidWorkflowId(" padded") is string);
    test:assertTrue(invalidWorkflowId("") is string);
}

@test:Config {}
function generatesVersionSevenUuids() {
    string id = uuidV7();
    test:assertEquals(id.length(), 36);
    test:assertEquals(id.substring(14, 15), "7");
    test:assertTrue(["8", "9", "a", "b"].indexOf(id.substring(19, 20)) !is ());
    test:assertTrue(uuidV7() != id);
}

@test:Config {}
function mapsTemporalStatusToTaskStatus() {
    test:assertEquals(taskStatus("WORKFLOW_EXECUTION_STATUS_RUNNING"), "PENDING");
    test:assertEquals(taskStatus("WORKFLOW_EXECUTION_STATUS_TIMED_OUT"), "FAILED");
    test:assertEquals(shortStatus("WORKFLOW_EXECUTION_STATUS_COMPLETED"), "COMPLETED");
}

@test:Config {}
function validatesStartPolicies() {
    test:assertEquals(invalidPolicies((), ()), ());
    test:assertEquals(invalidPolicies("USE_EXISTING", "REJECT_DUPLICATE"), ());
    test:assertTrue(invalidPolicies("SOMETIMES", ()) is string);
    test:assertTrue(invalidPolicies((), "NEVER") is string);
}

@test:Config {}
function formatsRolesLikeTheModule() {
    test:assertEquals(roleList(["manager", "finance"]), "[manager, finance]");
    test:assertEquals(roleList("manager"), "[manager]");
}
