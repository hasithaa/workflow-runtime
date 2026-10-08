# Both bridges in one integration

Checks that an integration can report to ICP (ICP runtime bridge) and to the Workflow Runtime (workflow runtime
bridge) at the same time.

1. `./run.sh` builds `samples/expense-approval` with both bridges into `.run/coexistence`, with
   `remoteManagement = true` so the ICP bridge's compiler plugin generates the glue that hands it workflow metadata.
2. Start `python3 mock_icp.py 9445` (stands in for ICP's heartbeat endpoints), Temporal and the Runtime API.
3. Run the built jar with the sample's config plus the `[wso2.icp.runtime.bridge]` block `run.sh` prints.

Expected, and seen with `wso2/icp.runtime.bridge` 1.0.2 and workflow 1.0.0:

- `GET localhost:9445/received` lists full heartbeats with `workflowMetadata`, `workflowTaskQueue` and the
  `workflowCommands` capability, then delta heartbeats. The ICP bridge sends `workflowMetadata` only after the server
  lists it in `supportedHeartbeatFields`; the mock asks for a second full heartbeat for that reason.
- `GET localhost:9470/runtime/integrations` shows the integration online.
- `tests/contract/contract.py` still passes 28/28.

The ICP bridge sends large heartbeats with chunked transfer encoding; the mock reads both forms.
