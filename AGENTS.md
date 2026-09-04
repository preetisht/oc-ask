# oc-ask — agent notes

Standalone bash helper. **Not** part of the OpenShift `oc` binary. Do not add this to `pkg/cli/` or `pkg/cli/cli.go`.

Private GitHub repo: https://github.com/preetisht/oc-ask (`preetisht/oc-ask`). Local path: `/Users/pk/go/src/github.com/Azure/oc-ask`. Sibling of `/Users/pk/go/src/github.com/Azure/oc` (the CLI checkout). An untracked copy may still exist at `oc/contrib/oc-ask.sh`; do not commit it into `oc` unless the user asks.

## Operating constraints (non-negotiable)

The user runs this from a **laptop with kubeconfig only**:

- No SSH to masters, no `oc debug node`, no host `journalctl`.
- No internet at runtime. Do not add LLM/API calls, downloads, or telemetry.
- Every cluster call goes through `oc_ro` (read-only allowlist). Writes are **printed, never executed**.
- Host journals, if any, come from `oc adm node-logs` (API → kubelet). If that fails (RBAC or dead kubelet), continue with Node conditions and `oc logs` on API-visible pods.

Needs bash 4+ (macOS `/bin/bash` is 3.2 — use Homebrew bash). `jq` is optional.

## How the script works

`oc-ask.sh` maps a natural-language question to a hardcoded playbook (keyword scores, no model at runtime). `--self-test` covers matcher + allowlist and does not need a cluster.

**Control-plane playbook** (`check masters` / `check the control plane` / `check cvo`) walks a fixed path and ignores customer pods on masters:

1. L0 Node Ready/conditions + `oc adm node-logs` if NotReady
2. L1 static pods: etcd, kube-apiserver, kube-controller-manager, kube-scheduler
3. L2 CVO (`openshift-cluster-version`; ClusterVersion CR, not a ClusterOperator named `cluster-version`)
4. L3–L4 ClusterOperator → operator ns → operand
5. L5 OpenShift APIs + OVN `ovnkube-control-plane` (was `ovnkube-master` before 4.14)
6. L6 MCP/master, Machine, ControlPlaneMachineSet

Catalog kinds: `static`, `cp-api`, `cp-net`, `node-agent`, `operator`. Empty TSV fields must be `-` (bash IFS collapses adjacent tabs).

`FOCUS_MASTERS` is per-operator: auto-on for `static` and `cp-api`. Do **not** master-only-filter DNS / ovnkube-node / machine-config-daemon (they run on workers too). CPMS questions (`is CPMS enabled`) must stay the `cpms` playbook, not `controlplane`.

Named operator checks (`check etcd`, `check dns`) stay on `playbook_check`. `check cvo` delegates to `playbook_controlplane`.

## When changing code

- Keep the allowlist strict. Never execute patch/delete/debug/must-gather/drain.
- Add or update `--self-test` cases for new intents, aliases, and catalog rows.
- User-facing docs live in `README.md`. Do not duplicate long usage there into code comments.
- Do not commit kubeconfigs or secrets (see `.gitignore`).
