#!/usr/bin/env bash
# Builds the sample with both bridges (ICP runtime bridge + workflow runtime bridge) into .run/coexistence.
# Then: start mock_icp.py, the Runtime API and Temporal, run the built jar with the printed config, and check that
# the runtime lists the integration while GET localhost:9445/received shows ICP heartbeats with workflow metadata.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$ROOT/.run/coexistence
rm -rf "$OUT" && mkdir -p "$OUT" && cp "$ROOT"/samples/expense-approval/*.bal "$OUT"/
# remoteManagement makes the compiler plugin generate the glue that hands workflow metadata to the ICP bridge.
sed -e 's/^name = "expense_approval"/name = "expense_approval_both_bridges"/' \
    -e 's/^observabilityIncluded = false/observabilityIncluded = false\nremoteManagement = true/' \
    "$ROOT/samples/expense-approval/Ballerina.toml" > "$OUT/Ballerina.toml"
cat >> "$OUT/Ballerina.toml" <<'TOML'

[[dependency]]
org = "wso2"
name = "icp.runtime.bridge"
version = "1.0.2"
TOML
sed -i.bak 's#^import hasitha/workflow.runtime.bridge as _;#import hasitha/workflow.runtime.bridge as _;\nimport wso2/icp.runtime.bridge as _;#' "$OUT/main.bal" && rm "$OUT/main.bal.bak"
(cd "$OUT" && "${BAL:-bal}" build)
cat <<'TOML'
Add to the sample's Config.toml:

[wso2.icp.runtime.bridge]
serverUrl = "http://localhost:9445"
environment = "dev"
project = "expense"
integration = "expense-approval"
runtime = "expense-approval-1"
secret = "icp-1.local-icp-key-material-at-least-32-bytes"
TOML
