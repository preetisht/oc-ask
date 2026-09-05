# oc-ask

Air-gapped, read-only OpenShift diagnostics from a natural-language question.

You run this from a **laptop that has a kubeconfig**. It talks only to the Kubernetes API. It does **not** SSH to masters, does **not** `oc debug node`, and does **not** need internet at runtime.

Write remediations are **printed, never executed**.

## Requirements

Copy these onto the laptop **before** you go offline:

| Piece | Notes |
| --- | --- |
| `oc-ask.sh` | this repo |
| `oc` | on `PATH`, or set `OC` / pass `--oc` |
| `jq` | optional; JSON walks are better with it |
| kubeconfig | `export KUBECONFIG=/path/to/kubeconfig` |

**bash 4+** is required (associative arrays). macOS `/bin/bash` is 3.2:

```bash
brew install bash   # once, while you still have network
/opt/homebrew/bin/bash ./oc-ask.sh --help
```

Linux laptops usually already have bash 4+.

## Usage

```bash
export KUBECONFIG=/path/to/kubeconfig

./oc-ask.sh "there is a node stuck in deleting state, what is the reason"
./oc-ask.sh "what is the cluster version"
./oc-ask.sh "is CPMS enabled"
./oc-ask.sh --check
./oc-ask.sh "check dns issue"
./oc-ask.sh "check ovn"
./oc-ask.sh "check masters"
./oc-ask.sh "check the control plane"
./oc-ask.sh "check cvo"

./oc-ask.sh --list          # playbooks and example questions
./oc-ask.sh --self-test     # matcher + allowlist (no cluster)
./oc-ask.sh --dry-run "check masters"
./oc-ask.sh                 # interactive prompt
```

Each run **overwrites** `oc_ask_log.txt` in the directory you launched from (not the script's directory). It includes every `oc` command, stdout/stderr, jq results, findings, and a bash trace. If the script fails, send that file. It can contain cluster details from `oc` output.

Disable with `--no-log` or `OC_ASK_LOG=`. Override path with `--log /tmp/oc-ask.txt` or `OC_ASK_LOG`.

`--check` / `check <operator>` still lists ClusterOperators, then for each unhealthy (or named) CO:

1. **Operator-specific path** — native CRs for that operator (Etcd/KubeAPIServer revisions, MCP, CPMS, IngressController, CSRs, …)
2. **Generic walk** — `relatedObjects` namespaces → unhealthy pods → container logs

Unknown or platform-extra COs use the generic walk only.


## What it will and will not do

**Will (API only)**

- `oc get` / `describe` / `logs` / `events` / `explain` / `whoami` / `version`
- `oc auth can-i`
- `oc adm upgrade` (status / recommend only — never `--to`)
- `oc adm top`, `oc adm node-logs` (API server asks kubelet for journald — still not SSH)

**Will not**

- SSH, `oc debug`, `oc exec`, patch, delete, apply, drain, cordon, must-gather
- Log into a master
- Pull anything from the internet

If `oc adm node-logs` fails (missing RBAC or kubelet down), host journals are unavailable. The script continues with Node conditions, events, and `oc logs` on pods the API can already see.

## Control-plane path (`check masters`)

Customer workloads on masters are ignored. Platform components are walked in this order:

1. **L0** Node object (Ready / conditions) + `oc adm node-logs` if NotReady
2. **L1** Static pods: etcd, kube-apiserver, kube-controller-manager, kube-scheduler
3. **L2** CVO (`openshift-cluster-version` / ClusterVersion)
4. **L3–L4** ClusterOperator → operator namespace → operand
5. **L5** OpenShift APIs and OVN control-plane on masters (`ovnkube-control-plane`; was `ovnkube-master` before 4.14)
6. **L6** MCP/master, Machine, ControlPlaneMachineSet

Static-pod and control-plane API operators restrict pod logs to master/control-plane nodes. DaemonSets that also run on workers (CoreDNS, machine-config-daemon, ovnkube-node) are not master-only.

## Playbooks

| Intent | Example question |
| --- | --- |
| `node_deleting` | there is a node stuck in deleting state |
| `node_notready` | why is node X NotReady |
| `cluster_version` | what is the cluster version |
| `cpms` | is CPMS enabled |
| `operators` | are any operators degraded |
| `mcp` | is mcp paused |
| `crashloop` | pods in CrashLoopBackOff |
| `machines` | show machines |
| `events` | recent warning events |
| `whoami` | who am i |
| `overview` | cluster health |
| `check` | is anything broken / check dns issue |
| `controlplane` | check masters / check the control plane / check cvo |

## Config

Edit the block at the top of `oc-ask.sh`, or use the environment / flags:

- `OC`, `JQ`, `KUBECONFIG`, `OC_CONTEXT`
- Caps: `CHECK_MAX_OPS`, `CHECK_MAX_NS`, `CHECK_MAX_PODS`, `CHECK_MAX_CONTAINERS`, `LOG_TAIL`

## License

Not an official OpenShift CLI command. Standalone helper; bring your own `oc`.
