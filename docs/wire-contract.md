# Workflow module 1.0.0: wire contract for the owner-bound operations

The Runtime API reproduces four management operations directly against Temporal, because the workflow module
binds them to the process that owns the task queue. This is what it must match. Source: module commit
`469782b` (the 1.0.0 bundled with WSO2 Integrator). N = `native/src/main/java/io/ballerina/lib/workflow/`.

## Common

- Payloads: Temporal `DefaultDataConverter`, so `json/plain`; null is `binary/null`. Temporal's HTTP API takes
  and returns `json/plain` payloads as plain JSON (shorthand).
- Error body: `{"error":{"message": …}}`. Status: NOT_FOUND 404, ACCESS_DENIED 403, INVALID_REQUEST 400,
  CONFLICT 409, INVALID_PAYLOAD 422, else 500. Runtime errors are classified by message substring:
  "not found" 404, "Unauthorized" 403, "not running"/"already completed" 409, "Invalid payload" 422.
- Identity: `x-user-id`, `x-user-roles` (comma separated) in trusted-gateway mode, or JWT claims.

## Start: `POST /workflows`

- Body: `workflowType` (required), `input`, `workflowId`, `timeoutSeconds` (int or numeric string),
  `ifRunning` = `FAIL` (default) | `USE_EXISTING` | `TERMINATE_EXISTING`,
  `ifClosed` = `ALLOW_DUPLICATE` (default) | `ALLOW_DUPLICATE_FAILED_ONLY` | `REJECT_DUPLICATE`.
  `startedBy` is the caller's user ID, never a body field.
- Temporal type: `"workflow-" + workflowType`. Task queue: the owning integration's.
- ID: caller's, else UUIDv7. Caller IDs: non-blank, no surrounding whitespace, ≤ 255 UTF-8 bytes, not
  prefixed `humantask-`, `reviewactivity-`, `childwf-`, `childagent-` (400 otherwise).
- Policies only when the caller chose the ID and only when not default:
  `WORKFLOW_ID_CONFLICT_POLICY_{USE_EXISTING|TERMINATE_EXISTING}`,
  `WORKFLOW_ID_REUSE_POLICY_{ALLOW_DUPLICATE_FAILED_ONLY|REJECT_DUPLICATE}`.
- Input: exactly one payload, the JSON value (absent input = one `binary/null` payload).
- Memo: `workflowKind` = `WORKFLOW` | `AGENT`; `startedBy` when non-blank; `startRequestId` (random UUID)
  only with a caller ID and `USE_EXISTING`.
- Search attribute: Keyword `WorkflowKind` = the same kind, when the attribute exists.
- `workflowExecutionTimeout` = `timeoutSeconds`. `userMetadata.summary` = the `@display` label, if any.
- Response: `{"workflowId","runId","started"}`, 201, or 200 when an existing run was joined.
- Errors: unknown type 404 "No workflow or durable agent is registered as 'X'"; ID held 409 "An instance with
  id 'X' already exists (status: RUNNING)"; else 500 "Failed to start workflow: …".
- Agents: body `input` must be `{query: string, input?}`; the engine argument is
  `{"agentName": <name>, "query": …, "input": <payload|null>}`; `input` is converted to the agent's
  `inputType` (422 on failure).

## Complete or fail a human task: `POST /human-tasks/{id}/complete` (`{"result": …}`) and `/fail`

1. No user ID and no roles: 403 "Unauthorized: caller identity is required".
2. Describe the task workflow (ID = task ID). Queue ownership (module only; the runtime checks the scope).
3. Status RUNNING, else 409 "Human task 'X' is not running (status=…)".
4. Memo `workflowKind == "HUMAN_TASK"`.
5. Result type check against the in-process registered type (skipped when unknown). The runtime cannot do this;
   `formSchema` in the memo is the substitute.
6. Assignment (memo string arrays `userRoles`, `users`, `excludedUsers`, `excludedRoles`,
   `administratorRoles`, `administratorUsers`): excluded role → deny; excluded users set and caller unknown or
   excluded → deny; no `userRoles` and no `users` → allow; role in `userRoles` or user in `users` → audience;
   role in `administratorRoles` or user in `administratorUsers` → administrator; else 403 "Unauthorized: caller
   does not have a required role to complete task 'X'. Required one of: [..]".
7. Signal `taskCompletion` (workflow ID, no run ID), one JSON payload:
   `{"result", "completedBy": user|"unknown", "completedAt": ISO instant, "completedAs": "audience"|"administrator",
   "callerRoles": [..]|null}`. Fail sends `{"__rejected": true, "reason", "details"?, completedBy, completedAt,
   completedAs, callerRoles}` instead of `result`.
8. Response 200 `{"success":true,"completedBy","completedAt"}`.

## Decide a review activity: `/review-activities/{id}/proceed`, `/proceed-with-input` (`{"input":{…}}`), `/reject` (`{"feedback"?}`)

- Describe; kind must be `REVIEW_ACTIVITY` or `RETRY_TASK` (404 "Review activity not found…").
- Access: when the review names any audience or exclusion, the assignment rule above; when it names nobody,
  everyone (unless `reviewActivityAccessRole` is configured). Denied: 403 "Unauthorized: caller is not allowed
  to decide this review activity".
- RUNNING, else 409 "Retry task 'X' is not running (status=…)". `proceed-with-input` needs an object (400).
- Signal `taskDecision`: `{"action", "input"?, "feedback"?, "decidedBy", "completedAs", "callerRoles", "decidedAt"}`.
- Response 200 `{"success":true,"decision":<action>,"completedBy","completedAt"}`.

## Definitions: `GET /definitions`

`{"definitions":[{"workflowType","kind","displayName","icon","inputSchema": <JSON Schema as a string>,
"isActive": true, "workerCount": 1}]}`. Derivable from `getWorkflowMetadata().definitions[]` plus `isActive`
and `workerCount` (the module hardcodes both; the runtime reports live runtimes). Exception: for `AGENT`
entries the module serves the `{query, input}` envelope schema, while the metadata carries the runner's.

## Reassign and extend a deadline: `POST /{human-tasks|review-activities}/{id}/reassign` and `/deadline`

- No user ID and no roles: 403 "Unauthorized: caller identity is required".
- Reassign body: only `userRoles`, `users`, `excludedUsers`, `excludedRoles`, each a list of strings, else 400
  "The audience must be lists of strings under userRoles, users, excludedUsers or excludedRoles"; an empty body is
  400 "Name at least one audience list to replace". Deadline body: `timeoutMillis` positive or absent (absent clears
  it), else 400 "timeoutMillis must be positive, or absent to clear the deadline".
- The task must exist with the route's kind: 404 "Human task not found: X" / "Review activity not found: X".
- RUNNING, else 409 "Task 'X' is not running (status=…)". Only administrators (`administratorRoles`,
  `administratorUsers`): 403 "Unauthorized: only an administrator of task 'X' may reassign it" (or "extendDeadline").
- Signal `taskAdminister`: `{"action": "reassign"|"extendDeadline", …audience lists | "timeoutMillis",
  "administeredBy", "completedAt"}`.
- Response 200 `{"success":true,"action","administeredBy","administeredAt"}`.

## Bulk retry: `POST /review-activities/bulk-retry`

- Body: `action` = `retry` (proceed) | `fail` (reject, with optional `feedback`); exactly one of `taskIds` (non-empty
  list of non-empty strings, duplicates decided once) or `parentWorkflowId` (optionally narrowed by `activityName`).
  At most `maxBulkRetrySize` (100) tasks. Selection errors are 400 with the module's messages.
- A parent selection takes the parent's pending reviews whose `trigger` is `ON_FAILURE` (absent means `ON_FAILURE`).
- Per task: caller not allowed → `FAILED` "Unauthorized: caller is not allowed to decide this review activity";
  trigger not `ON_FAILURE` → `SKIPPED` "Not a failed-activity review: this review gates a proposed call"; status not
  `PENDING` → `SKIPPED` "Already decided: the review activity is …"; then the review decision above, where a 409 is
  `SKIPPED` and anything else not 200 is `FAILED`.
- Response 200 `{"action","requested","applied","skipped","failed","items":[{"taskId","outcome","reason"}],
  "decidedBy","decidedAt"}`.

## Where the runtime deliberately differs

- **Duplicate decisions.** Before signalling, the runtime reads the task's history and answers 409 when a
  `taskCompletion` or `taskDecision` signal already arrived. The module only checks the run status, so a second call
  that races the task closing can be accepted (signal lands before close) or fail with 500 (signal lands after).
- **Result validation.** The module checks the result against the task's Ballerina type and reports
  `{ballerina}ConversionError`; the runtime checks the memo's `formSchema` and names the failing rule.
- **`workerCount`** counts the integration's online runtimes instead of a fixed 1.
