# Workflow Runtime (experimental)

A control plane for Ballerina workflow integrations that talks to Temporal directly. Integrations register with it
through the [workflow runtime bridge](https://github.com/hasithaa/workflow-runtime-bridge); the runtime then serves
the same **Workflow Management API** an integration exposes (`/workflow`, 41 routes in workflow 1.0.0), for every
registered integration, without calling the integrations.

```
 integration ── workflow module (worker) ──────────────▶ Temporal ◀──┐
      └── workflow runtime bridge ── register, heartbeat ─▶ Runtime API ─┘
                                                            ▲
                               UIs, scripts ── /workflow ───┘
```

Status: experimental. No changes to the workflow module are needed.

## What is here

| Path | What |
|---|---|
| `runtime-api/` | The Runtime API (Ballerina): registration, the Workflow Management API, Temporal access tokens |
| `samples/expense-approval/` | A workflow integration with the bridge: human tasks, a data event, a failure review |
| `tests/contract/` | Runs the same scenarios against an integration's own API and the runtime, and compares them |
| `deploy/temporal-dev/` | Temporal on PostgreSQL for development (no auth) |
| `deploy/temporal-secured/` | Temporal with the JWT authorizer and frontend TLS, trusting the runtime's JWKS |
| `docs/wire-contract.md` | What the runtime matches for the operations it performs itself |

## How it works

- **Registration.** The bridge sends the integration's workflow metadata (`workflow.management:getWorkflowMetadata()`)
  once, then a heartbeat every 60 s. The runtime keeps each checksum, marks a runtime offline after three missed
  beats, and asks for a new registration when it does not know a checksum.
- **Reads and lifecycle** (instances, history, graphs, suspend, resume, cancel, terminate, reset, data events) are
  served by the workflow module embedded in the runtime. It has no workflows of its own, so it runs no worker.
- **Owner-bound operations.** The module only lets the process that owns a task queue list definitions, start
  instances, complete or fail tasks, decide reviews, reassign, extend deadlines and bulk-retry. The runtime does
  these itself through Temporal's HTTP API, matching the module's messages and payloads (`docs/wire-contract.md`).
- **Mounts.** `/integrations/{name}/workflow/…` is one integration's API, unchanged: a client only swaps the base
  URL. `/workflow/…` spans the namespace.
- **Temporal tokens.** `POST /runtime/tokens` (with `x-admin-key`) issues RS256 tokens with Temporal permissions
  (`<namespace>:worker|write|read|admin`, or system admin). `/jwks.json` is what Temporal's JWT authorizer trusts.
  The workflow module enables TLS whenever `authApiKey` is set, so tokens need TLS on Temporal's frontend.

## Run it locally

Needs Ballerina Swan Lake Update 14 (the `bal` in WSO2 Integrator works), Python 3, and the `temporal` CLI or Docker.

```sh
# 1. Temporal: PostgreSQL in Docker, or the CLI dev server for short runs
docker compose -p wfrt-dev -f deploy/temporal-dev/docker-compose.yml up -d
#    temporal server start-dev --port 7300 --http-port 7310 --namespace finance --search-attribute WorkflowKind=Keyword

# 2. The bridge, in the local Ballerina repository
git clone https://github.com/hasithaa/workflow-runtime-bridge && (cd workflow-runtime-bridge && bal pack && bal push --repository local)

# 3. The Runtime API and the sample (copy each Config.toml.example to Config.toml first)
(cd runtime-api && bal run)
(cd samples/expense-approval && bal run)

# 4. Compare the runtime with the integration's own API
python3 tests/contract/contract.py
```

The contract suite runs 28 steps against each host (starts, task completion and failure, role checks, reassign,
deadlines, data events, review decisions, bulk retry) and checks status codes and response fields.

## Known limits

- In-memory registry: registrations are rebuilt from heartbeats after a restart.
- The Workflow Management API trusts `x-user-id` and `x-user-roles` headers; put it behind a gateway that sets them.
- One namespace per runtime process.
- Task results are checked against the memo's JSON schema, not the Ballerina type.
- The Temporal CLI dev server (SQLite) has wedged after hours of use ("interrupted (9)", "cannot start a transaction
  within a transaction") until restarted. Use PostgreSQL for anything long-running.

## License

Apache License 2.0.
