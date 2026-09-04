#!/usr/bin/env bash
# oc-ask — air-gapped, read-only OpenShift diagnostic helper.
#
# Maps natural-language questions to hardcoded playbooks. Every cluster call
# goes through oc_ro, which allowlists get/describe/logs/events and a few
# read-only adm helpers. Write remediations are printed, never executed.
#
# Laptop + kubeconfig only: this does not SSH to masters and does not need
# internet at runtime. Copy oc-ask.sh, oc, and jq onto the laptop first.
#   export KUBECONFIG=/path/to/kubeconfig
#   ./oc-ask.sh "there is a node stuck in deleting state, what is the reason"
#   ./oc-ask.sh "what is the cluster version"
#   ./oc-ask.sh --check
#   ./oc-ask.sh "check masters"

###############################################################################
# CONFIG — edit these on the laptop that holds the kubeconfig
###############################################################################

# Absolute path to the oc binary, or a command name on PATH.
OC="${OC:-oc}"

# jq is used to parse oc -o json (related namespaces, container names, etc.).
# Install jq before going offline; the script still runs without it (jsonpath).
JQ="${JQ:-jq}"

# Kubeconfig on this laptop. Leave empty to use oc's default discovery
# (KUBECONFIG env, ~/.kube/config, or in-cluster config).
KUBECONFIG="${KUBECONFIG:-}"
OC_CONTEXT="${OC_CONTEXT:-}"

# Caps for --check so a fully broken cluster does not dump megabytes of logs.
CHECK_MAX_OPS="${CHECK_MAX_OPS:-5}"
CHECK_MAX_NS="${CHECK_MAX_NS:-4}"
CHECK_MAX_PODS="${CHECK_MAX_PODS:-4}"
CHECK_MAX_CONTAINERS="${CHECK_MAX_CONTAINERS:-3}"
LOG_TAIL="${LOG_TAIL:-40}"

###############################################################################
# bash 4+ (associative arrays, mapfile). macOS /bin/bash is 3.2.
###############################################################################

if ((BASH_VERSINFO[0] < 4)); then
	echo "oc-ask requires bash 4 or newer; this shell is $BASH_VERSION" >&2
	echo "On macOS install bash 5 (brew install bash) and run:" >&2
	echo "  /opt/homebrew/bin/bash $0 $*" >&2
	echo "Linux laptops and bastions usually already ship bash 4+." >&2
	exit 1
fi

# Do not use set -e: a failed oc get must become a finding, not a script abort.
set -u

HAS_JQ=0
if command -v "$JQ" >/dev/null 2>&1; then
	HAS_JQ=1
	JQ="$(command -v "$JQ")"
fi

###############################################################################
# globals
###############################################################################

DRY_RUN=0
FORCE_INTENT=""
OC_GLOBAL=()
CHECK_SEEN_NS=" "

FINDINGS=()
SUGGESTIONS=()
COMMAND_LOG=()
LAST_OUT=""
LAST_ERR=""
LAST_RC=0

_OUTFILE=""
_ERRFILE=""

INTENT_IDS=()
declare -A INTENT_TITLE=()
declare -A INTENT_EXAMPLES=()
declare -A INTENT_FN=()

###############################################################################
# colors (stdout tty only)
###############################################################################

if [[ -t 1 ]]; then
	C_BOLD=$'\033[1m'
	C_DIM=$'\033[2m'
	C_RED=$'\033[31m'
	C_YEL=$'\033[33m'
	C_GRN=$'\033[32m'
	C_RST=$'\033[0m'
else
	C_BOLD="" C_DIM="" C_RED="" C_YEL="" C_GRN="" C_RST=""
fi

usage() {
	cat <<'EOF'
oc-ask.sh — read-only OpenShift diagnostics from a natural-language question.

Talks only to the Kubernetes API using your kubeconfig. It never SSHes to
masters and does not need internet at runtime (copy oc + jq onto the laptop
ahead of time). Host journals, when reachable, come from oc adm node-logs
(API → kubelet), not from logging into the node.

Usage:
  oc-ask.sh [flags] "question"
  oc-ask.sh [flags]                  # interactive prompt
  oc-ask.sh --check                  # walk broken COs → namespaces → pod/container logs
  oc-ask.sh --check authentication   # same, but only this cluster operator
  oc-ask.sh --list
  oc-ask.sh --self-test
  oc-ask.sh --dry-run "question"

Flags:
  --oc PATH         oc binary (overrides OC in the config block)
  --context NAME    kubeconfig context (passed as oc --context)
  --intent ID       skip matching and run this playbook
  --check           automatic deep health check (read-only)
  --list, -l        print playbooks and example questions
  --dry-run, -n     print allowlisted oc commands; do not call the cluster
  --self-test       matcher + allowlist tests (no cluster required)
  --help, -h

Examples:
  export KUBECONFIG=/path/to/kubeconfig
  oc-ask.sh "there is a node stuck in deleting state, what is the reason"
  oc-ask.sh "what is the cluster version"
  oc-ask.sh "is CPMS enabled"
  oc-ask.sh --check
  oc-ask.sh "check this cluster operator"
  oc-ask.sh "check dns issue"
  oc-ask.sh "check ovn"
  oc-ask.sh "check masters"
  oc-ask.sh "check the control plane"
  oc-ask.sh "check cvo"

Control-plane questions follow a fixed path (API only, no SSH):
  Node object / oc adm node-logs → static pod oc logs → CVO → ClusterOperator
  → operator ns → operand pods ON masters → MCP/CPMS/Machine.
Customer workloads scheduled on masters are ignored.

This script never creates, patches, or deletes cluster objects. When a
write is required it prints the command for you to run yourself.
JSON is parsed with jq when it is on PATH.
EOF
}

###############################################################################
# report helpers
###############################################################################

reset_report() {
	FINDINGS=()
	SUGGESTIONS=()
	COMMAND_LOG=()
	LAST_OUT=""
	LAST_ERR=""
	LAST_RC=0
	CHECK_SEEN_NS=" "
	FOCUS_MASTERS=0
}

finding() {
	FINDINGS+=("$1")
}

suggest() {
	SUGGESTIONS+=("$1")
}

suggest_blank() {
	SUGGESTIONS+=("")
}

is_present() {
	local v="${1:-}"
	[[ -n "$v" && "$v" != "<none>" && "$v" != "null" && "$v" != "<no value>" && "$v" != "<nil>" ]]
}

trim() {
	local s="${1:-}"
	s="${s#"${s%%[![:space:]]*}"}"
	s="${s%"${s##*[![:space:]]}"}"
	printf '%s' "$s"
}

print_report() {
	local i
	echo
	echo "${C_BOLD}--- Commands (read-only) ---${C_RST}"
	if ((${#COMMAND_LOG[@]} == 0)); then
		echo "${C_DIM}(none)${C_RST}"
	else
		for i in "${COMMAND_LOG[@]}"; do
			echo "${C_DIM}$i${C_RST}"
		done
	fi

	echo
	echo "${C_BOLD}--- Findings ---${C_RST}"
	if ((${#FINDINGS[@]} == 0)); then
		echo "- (no structured findings; see command output above if any)"
	else
		for i in "${FINDINGS[@]}"; do
			echo "- $i"
		done
	fi

	echo
	echo "${C_BOLD}--- Suggested write operations (NOT executed) ---${C_RST}"
	if ((${#SUGGESTIONS[@]} == 0)); then
		echo "${C_GRN}None. This question was answered with read-only data.${C_RST}"
	else
		echo "${C_YEL}These would change the cluster. oc-ask did not run them.${C_RST}"
		for i in "${SUGGESTIONS[@]}"; do
			if [[ -z "$i" ]]; then
				echo
			else
				echo "$i"
			fi
		done
	fi
	echo
}

end_if_dry_run() {
	if [[ "$DRY_RUN" -eq 1 ]]; then
		finding "Dry-run mode: commands were allowlisted but not executed, so results were not interpreted."
		print_report
		return 0
	fi
	return 1
}

###############################################################################
# oc_ro — the only path to the cluster
###############################################################################

init_tempfiles() {
	if [[ -n "$_OUTFILE" ]]; then
		return 0
	fi
	_OUTFILE="$(mktemp "${TMPDIR:-/tmp}/oc-ask.out.XXXXXX")"
	_ERRFILE="$(mktemp "${TMPDIR:-/tmp}/oc-ask.err.XXXXXX")"
	trap 'rm -f "$_OUTFILE" "$_ERRFILE"' EXIT
}

format_cmd() {
	local out="$OC" a
	if ((${#OC_GLOBAL[@]} > 0)); then
		for a in "${OC_GLOBAL[@]}"; do
			out+=" $(printf '%q' "$a")"
		done
	fi
	for a in "$@"; do
		out+=" $(printf '%q' "$a")"
	done
	printf '%s' "$out"
}

# oc_ro_validate returns 0 if the argv is a permitted read-only oc invocation.
# It never executes oc. Used by oc_ro and --self-test.
oc_ro_validate() {
	if [[ $# -lt 1 ]]; then
		echo "oc_ro: no arguments" >&2
		return 2
	fi

	local arg
	for arg in "$@"; do
		case "$arg" in
		--force | --force=* | --grace-period | --grace-period=* | \
			--to | --to=* | --to-latest | --to-latest=* | \
			--to-image | --to-image=* | --clear | --clear=* | \
			--overwrite | --overwrite=* | --patch | --patch=* | \
			--type=json | --type=merge | --type=strategic | --type=jsonmerge)
			echo "oc_ro: refused mutating flag: $arg" >&2
			return 2
			;;
		esac
	done

	local cmd="$1"
	shift
	case "$cmd" in
	get | describe | logs | events | explain | whoami | version | api-resources | api-versions)
		return 0
		;;
	auth)
		if [[ "${1:-}" == "can-i" ]]; then
			return 0
		fi
		echo "oc_ro: only 'oc auth can-i' is allowed" >&2
		return 2
		;;
	adm)
		local sub="${1:-}"
		shift || true
		case "$sub" in
		upgrade)
			local next="${1:-}"
			case "$next" in
			status | recommend | '' | --*)
				return 0
				;;
			*)
				echo "oc_ro: refused oc adm upgrade $next" >&2
				return 2
				;;
			esac
			;;
		top | node-logs)
			return 0
			;;
		*)
			echo "oc_ro: refused oc adm ${sub:-<missing>}" >&2
			return 2
			;;
		esac
		;;
	patch | delete | apply | edit | create | replace | scale | autoscale | \
		label | annotate | expose | set | debug | run | exec | rsh | attach | \
		cp | login | logout | drain | cordon | uncordon | taint | \
		new-app | new-project | start-build | cancel-build | tag | import-image | \
		rollout | rollback | process | idle | proxy | wait | kustomize | \
		must-gather | inspect | prune | migrate | policy)
		echo "oc_ro: refused mutating or non-allowlisted command: $cmd" >&2
		return 2
		;;
	*)
		echo "oc_ro: command not allowlisted: $cmd" >&2
		return 2
		;;
	esac
}

oc_ro() {
	LAST_OUT=""
	LAST_ERR=""
	LAST_RC=0

	if ! oc_ro_validate "$@"; then
		LAST_RC=2
		finding "internal: refused non-read-only oc invocation: $*"
		return 2
	fi

	COMMAND_LOG+=("$(format_cmd "$@")")

	if [[ "$DRY_RUN" -eq 1 ]]; then
		LAST_RC=0
		return 0
	fi

	init_tempfiles
	: >"$_OUTFILE"
	: >"$_ERRFILE"
	if ((${#OC_GLOBAL[@]})); then
		"$OC" "${OC_GLOBAL[@]}" "$@" >"$_OUTFILE" 2>"$_ERRFILE"
		LAST_RC=$?
	else
		"$OC" "$@" >"$_OUTFILE" 2>"$_ERRFILE"
		LAST_RC=$?
	fi
	LAST_OUT="$(cat "$_OUTFILE")"
	LAST_ERR="$(cat "$_ERRFILE")"
	return "$LAST_RC"
}

JQ_OUT=""

# Pipe LAST_OUT (or $2) through jq -r. Logs the jq filter in COMMAND_LOG.
# Returns 1 if jq is missing, JSON is empty, or jq fails.
jq_eval() {
	local query="$1"
	local json="${2-}"
	JQ_OUT=""
	if [[ -z "$json" ]]; then
		json="${LAST_OUT}"
	fi
	if [[ "$HAS_JQ" -ne 1 ]]; then
		return 1
	fi
	COMMAND_LOG+=("| $JQ -r $(printf '%q' "$query")")
	if [[ "$DRY_RUN" -eq 1 ]]; then
		return 0
	fi
	if [[ -z "$json" ]]; then
		return 1
	fi
	local rc=0
	JQ_OUT="$(printf '%s' "$json" | "$JQ" -r "$query" 2>/dev/null)" || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		JQ_OUT=""
		return 1
	fi
	if [[ "$JQ_OUT" == "null" ]]; then
		JQ_OUT=""
	fi
	return 0
}

# Print generated namespaced oc commands so the user can copy them.
gen_logs_cmd() {
	local ns="$1" pod="$2" container="${3-}"
	if [[ -n "$container" ]]; then
		printf 'oc logs -n %s %s -c %s --tail=%s' "$ns" "$pod" "$container" "$LOG_TAIL"
	else
		printf 'oc logs -n %s %s --all-containers --tail=%s' "$ns" "$pod" "$LOG_TAIL"
	fi
}

gen_describe_pod_cmd() {
	printf 'oc describe pod -n %s %s' "$1" "$2"
}

gen_delete_pod_cmd() {
	printf 'oc delete pod -n %s %s' "$1" "$2"
}

append_log_excerpt() {
	local label="$1"
	local text="${2-}"
	local n="${3:-25}"
	if ! lines_nonempty "$text"; then
		finding "$label: (empty or unavailable)"
		return 0
	fi
	finding "$label:"
	local line
	while IFS= read -r line; do
		finding "    $line"
	done <<<"$(printf '%s\n' "$text" | tail -n "$n")"
}

# Unhealthy pod names in a namespace (CrashLoop / ImagePull / not Running, except Succeeded).
jq_unhealthy_pods_query='
.items[]?
| select(
    (.status.phase != "Succeeded") and (
      (.status.phase != "Running" and .status.phase != "Unknown")
      or (.status.phase == "Unknown")
      or any(
        ((.status.containerStatuses // []) + (.status.initContainerStatuses // []))[];
        ((.state.waiting.reason // "") == "CrashLoopBackOff")
        or ((.state.waiting.reason // "") == "ImagePullBackOff")
        or ((.state.waiting.reason // "") == "ErrImagePull")
        or ((.state.waiting.reason // "") == "CreateContainerError")
        or ((.state.waiting.reason // "") == "RunContainerError")
        or ((.state.terminated.reason // "") == "OOMKilled")
        or ((.state.terminated.reason // "") == "Error")
      )
    )
  )
| [.metadata.name, .status.phase] | @tsv
'

jq_unhealthy_pods_cluster_query='
.items[]?
| select(
    (.status.phase != "Succeeded") and (
      (.status.phase != "Running")
      or any(
        ((.status.containerStatuses // []) + (.status.initContainerStatuses // []))[];
        ((.state.waiting.reason // "") == "CrashLoopBackOff")
        or ((.state.waiting.reason // "") == "ImagePullBackOff")
        or ((.state.waiting.reason // "") == "ErrImagePull")
        or ((.state.waiting.reason // "") == "CreateContainerError")
        or ((.state.waiting.reason // "") == "OOMKilled")
        or ((.state.terminated.reason // "") == "OOMKilled")
        or ((.state.terminated.reason // "") == "Error")
      )
    )
  )
| [.metadata.namespace, .metadata.name, .status.phase] | @tsv
'

jq_container_status_query='
((.status.containerStatuses // []) + (.status.initContainerStatuses // []))[]?
| [
    .name,
    (.state.waiting.reason // .state.terminated.reason // (if .state.running then "Running" else "" end)),
    (.restartCount | tostring),
    (if .ready then "ready" else "not-ready" end)
  ]
| @tsv
'

# relatedObjects: namespace resources, plus .namespace on namespaced objects.
jq_co_namespaces_query='
[.status.relatedObjects[]?
 | select((.resource == "namespaces") or ((.namespace != null) and (.namespace != "")))
 | (if .resource == "namespaces" then .name else .namespace end)
]
| unique | .[]
'

jq_bad_co_query='
.items[]
| select(
    any(.status.conditions[]?;
      (.type == "Degraded" and .status == "True")
      or (.type == "Available" and .status == "False")
    )
  )
| .metadata.name
'

# Per-container logs for one pod. Always includes -n <namespace>.
emit_pod_container_logs() {
	local ns="$1" pod="$2"
	local json cname reason restarts ready ncont=0

	finding "Pod $ns/$pod — generated: $(gen_describe_pod_cmd "$ns" "$pod")"
	oc_ro get pod -n "$ns" "$pod" -o json || true
	json="$LAST_OUT"

	if [[ "$HAS_JQ" -eq 1 ]] && [[ -n "$json" ]]; then
		jq_eval "$jq_container_status_query" "$json" || true
		local line
		while IFS=$'\t' read -r cname reason restarts ready; do
			[[ -z "${cname:-}" ]] && continue
			ncont=$((ncont + 1))
			if [[ "$ncont" -gt "$CHECK_MAX_CONTAINERS" ]]; then
				finding "    (further containers omitted; raise CHECK_MAX_CONTAINERS)"
				break
			fi
			finding "    container $cname reason=${reason:-?} restarts=${restarts:-0} $ready"
			finding "    generated: $(gen_logs_cmd "$ns" "$pod" "$cname")"
			oc_ro logs -n "$ns" "$pod" -c "$cname" --tail="$LOG_TAIL" || true
			append_log_excerpt "    current logs -n $ns $pod -c $cname" "$LAST_OUT" 20
			if [[ "${restarts:-0}" =~ ^[0-9]+$ ]] && [[ "${restarts:-0}" -gt 0 ]]; then
				finding "    generated: $(gen_logs_cmd "$ns" "$pod" "$cname") -p"
				oc_ro logs -n "$ns" "$pod" -c "$cname" --tail="$LOG_TAIL" -p || true
				append_log_excerpt "    previous logs -n $ns $pod -c $cname" "$LAST_OUT" 15
			fi
		done <<<"${JQ_OUT}"
	fi

	if [[ "$ncont" -eq 0 ]]; then
		finding "    generated: $(gen_logs_cmd "$ns" "$pod")"
		oc_ro logs -n "$ns" "$pod" --all-containers --tail="$LOG_TAIL" || true
		append_log_excerpt "    current logs -n $ns $pod --all-containers" "$LAST_OUT" 20
	fi

	oc_ro get events -n "$ns" --field-selector "involvedObject.name=$pod,involvedObject.kind=Pod" || true
	if lines_nonempty "$LAST_OUT"; then
		append_log_excerpt "    events for pod $ns/$pod" "$LAST_OUT" 8
	fi
	suggest "# Recreate this pod (WRITE; controller usually replaces it):"
	suggest "$(gen_delete_pod_cmd "$ns" "$pod")"
}

# List unhealthy pods in a namespace and pull their container logs.
drill_namespace_pods() {
	local ns="$1"
	local json line pname phase npods=0

	if [[ "$CHECK_SEEN_NS" == *" $ns "* ]]; then
		return 0
	fi
	finding "Namespace $ns — generated: oc get pods -n $ns -o json"
	CHECK_SEEN_NS+=" $ns "
	oc_ro get pods -n "$ns" -o json || true
	json="$LAST_OUT"
	if [[ "$LAST_RC" -ne 0 ]]; then
		finding "    could not list pods in $ns: $(trim "$LAST_ERR")"
		return 0
	fi

	if [[ "$HAS_JQ" -ne 1 || -z "$json" ]]; then
		oc_ro get pods -n "$ns" --no-headers || true
		if lines_nonempty "$LAST_OUT"; then
			finding "    pods in $ns (table; install jq for unhealthy-pod selection):"
			append_log_excerpt "    " "$LAST_OUT" 20
		else
			finding "    no pods in $ns (or jq missing so automated selection was skipped)."
		fi
		return 0
	fi

	if [[ "$FOCUS_MASTERS" -eq 1 && -n "$MASTER_NODES" ]]; then
		jq_eval_masters "$jq_master_pod_summary_query" "$json" || true
		finding "    $ns platform pods on masters: ${JQ_OUT:-unknown}"
		jq_eval_masters "$jq_unhealthy_on_masters_query" "$json" || true
	else
		jq_eval "$jq_unhealthy_pods_query" "$json" || true
	fi
	if ! lines_nonempty "$JQ_OUT"; then
		if [[ "$FOCUS_MASTERS" -eq 1 ]]; then
			finding "    no unhealthy platform pods on masters in $ns"
		else
			finding "    no CrashLoop/ImagePull/non-Running pods in $ns"
		fi
		return 0
	fi

	while IFS=$'\t' read -r pname phase nodehint; do
		[[ -z "${pname:-}" ]] && continue
		npods=$((npods + 1))
		if [[ "$npods" -gt "$CHECK_MAX_PODS" ]]; then
			finding "    (further unhealthy pods in $ns omitted; raise CHECK_MAX_PODS)"
			break
		fi
		if [[ -n "${nodehint:-}" && "$pname" != "$phase" ]]; then
			finding "    unhealthy pod $ns/$pname phase=$phase node=${nodehint}"
		else
			finding "    unhealthy pod $ns/$pname phase=$phase"
		fi
		emit_pod_container_logs "$ns" "$pname"
	done <<<"$JQ_OUT"
}

# ClusterOperator → catalog namespaces + relatedObjects → pods (optionally masters-only).
# Static and cp-api operators auto-restrict to master nodes unless the caller already did.
drill_cluster_operator() {
	local op="$1"
	local saved_focus="$FOCUS_MASTERS"
	local json ns nns=0
	local -A seen_ns=()
	local kind=""
	kind="$(cp_kind_for_co "$op")" || true
	if [[ "$FOCUS_MASTERS" -eq 0 && ( "$kind" == "static" || "$kind" == "cp-api" ) ]]; then
		FOCUS_MASTERS=1
		finding "clusteroperator/$op is a control-plane $kind component; restricting pod logs to master/control-plane nodes."
		if [[ -z "$MASTER_NODES" ]]; then
			load_master_nodes || true
		fi
	fi

	if [[ "$op" == "cluster-version" ]]; then
		finding "CVO is ClusterVersion + namespace openshift-cluster-version (not a ClusterOperator named cluster-version)."
		oc_ro get clusterversion version -o jsonpath='desired={.status.desired.version} history0={.status.history[0].version}' || true
		finding "    ClusterVersion: $LAST_OUT"
		drill_namespace_pods openshift-cluster-version
		FOCUS_MASTERS="$saved_focus"
		return 0
	fi

	finding "ClusterOperator $op — generated: oc get clusteroperator $op -o json"
	oc_ro get clusteroperator "$op" -o json || true
	json="$LAST_OUT"
	if [[ "$LAST_RC" -ne 0 || -z "$json" ]]; then
		finding "    could not GET clusteroperator/$op: $(trim "$LAST_ERR")"
		# still try catalog namespaces
		local catns
		while IFS= read -r catns; do
			[[ -z "$catns" ]] && continue
			drill_namespace_pods "$catns"
		done <<<"$(cp_namespaces_for_co "$op" || true)"
		FOCUS_MASTERS="$saved_focus"
		return 0
	fi

	local nslist=""
	if [[ "$HAS_JQ" -eq 1 ]]; then
		jq_eval '.status.conditions[]? | select(.type=="Degraded" or .type=="Available" or .type=="Progressing") | "\(.type)=\(.status) \(.reason): \(.message)"' "$json" || true
		if lines_nonempty "$JQ_OUT"; then
			local cline
			while IFS= read -r cline; do
				[[ -z "$cline" ]] && continue
				finding "    $cline"
			done <<<"$JQ_OUT"
		fi
		jq_eval "$jq_co_namespaces_query" "$json" || true
		nslist="$JQ_OUT"
	else
		oc_ro get clusteroperator "$op" -o jsonpath='{range .status.relatedObjects[*]}{.resource}{"\t"}{.name}{"\t"}{.namespace}{"\n"}{end}' || true
		finding "    relatedObjects (jq not found; using jsonpath):"
		append_log_excerpt "    " "$LAST_OUT" 30
		local resource name nsf
		while IFS=$'\t' read -r resource name nsf; do
			[[ -z "${resource:-}" ]] && continue
			if [[ "$resource" == "namespaces" ]]; then
				nslist+="$name"$'\n'
			elif [[ -n "$nsf" ]]; then
				nslist+="$nsf"$'\n'
			fi
		done <<<"$LAST_OUT"
	fi

	local extra catns
	extra="$(cp_namespaces_for_co "$op" || true)"
	finding "    catalog + related namespaces for $op:"
	# Catalog namespaces first so CHECK_MAX_NS cannot drop the operand ns.
	while IFS= read -r ns; do
		[[ -z "$ns" || "$ns" == "null" ]] && continue
		[[ -n "${seen_ns[$ns]:-}" ]] && continue
		seen_ns["$ns"]=1
		nns=$((nns + 1))
		if [[ "$nns" -gt "$CHECK_MAX_NS" ]]; then
			finding "    (further namespaces omitted; raise CHECK_MAX_NS)"
			break
		fi
		finding "    → $ns"
		drill_namespace_pods "$ns"
	done <<<"$(printf '%s\n%s\n' "$extra" "$nslist")"

	suggest "# Local dump of this operator (cluster-read, writes a directory):"
	suggest "oc adm inspect clusteroperator/$op"
	FOCUS_MASTERS="$saved_focus"
}

require_oc() {
	local resolved=""
	if [[ "$OC" == */* ]]; then
		if [[ -x "$OC" ]]; then
			resolved="$OC"
		fi
	else
		resolved="$(command -v "$OC" 2>/dev/null || true)"
	fi
	if [[ -z "$resolved" ]]; then
		echo "oc binary not found: $OC" >&2
		echo "Set OC at the top of this script or pass --oc /path/to/oc" >&2
		exit 1
	fi
	OC="$resolved"
	if [[ -n "$KUBECONFIG" ]]; then
		export KUBECONFIG
	fi
	OC_GLOBAL=()
	if [[ -n "$OC_CONTEXT" ]]; then
		OC_GLOBAL+=(--context "$OC_CONTEXT")
	fi
}

###############################################################################
# intent catalog + matcher
###############################################################################

register_intent() {
	local id="$1" title="$2" fn="$3" examples="$4"
	INTENT_IDS+=("$id")
	INTENT_TITLE["$id"]="$title"
	INTENT_FN["$id"]="$fn"
	INTENT_EXAMPLES["$id"]="$examples"
}

register_all_intents() {
	INTENT_IDS=()
	register_intent "node_deleting" \
		"Node stuck deleting / Terminating" \
		"playbook_node_deleting" \
		"there is a node stuck in deleting state, what is the reason|why is node X terminating|node stuck deleting"
	register_intent "node_notready" \
		"Node NotReady or SchedulingDisabled" \
		"playbook_node_notready" \
		"why is node X NotReady|node is SchedulingDisabled|node unreachable"
	register_intent "cluster_version" \
		"Cluster version and upgrade status" \
		"playbook_cluster_version" \
		"what is the cluster version|what version is the cluster on|is an upgrade in progress"
	register_intent "cpms" \
		"ControlPlaneMachineSet (CPMS) enabled?" \
		"playbook_cpms" \
		"is CPMS enabled|is CPMS enabled or not|is the control plane machine set active"
	register_intent "operators" \
		"Cluster operators degraded / unavailable" \
		"playbook_operators" \
		"are any operators degraded|which cluster operators are failing|degraded clusteroperator"
	register_intent "mcp" \
		"MachineConfigPool stuck or paused" \
		"playbook_mcp" \
		"is mcp paused|machine config pool not updating|mcp stuck"
	register_intent "crashloop" \
		"CrashLooping / restarting pods" \
		"playbook_crashloop" \
		"pods in CrashLoopBackOff|why are pods restarting|imagepullbackoff"
	register_intent "machines" \
		"Machine API / machines / machinesets" \
		"playbook_machines" \
		"machine api status|show machines|machineset replicas"
	register_intent "events" \
		"Recent Warning events" \
		"playbook_events" \
		"recent warning events|show cluster warnings|any warning events"
	register_intent "whoami" \
		"Who am I / which cluster am I talking to" \
		"playbook_whoami" \
		"whoami|who am i|which cluster am i logged into"
	register_intent "overview" \
		"Cluster health overview" \
		"playbook_overview" \
		"cluster health|cluster overview|health check"
	register_intent "check" \
		"Deep check: degraded COs → namespaces → pod/container logs" \
		"playbook_check" \
		"oc-ask.sh --check|is anything broken|check this cluster operator|check dns issue|check ovn|check authentication"
	register_intent "controlplane" \
		"Control-plane / master nodes (static pods, CVO, OVN master, MCD)" \
		"playbook_controlplane" \
		"check masters|check the control plane|check control plane|what is on the master nodes|check cvo"
}

# score_intent ID NORMALIZED_QUESTION -> integer on stdout
score_intent() {
	local id="$1" q="$2"
	local s=0

	case "$id" in
	node_deleting)
		[[ "$q" =~ node ]] && s=$((s + 2))
		[[ "$q" =~ (delet|terminat) ]] && s=$((s + 4))
		[[ "$q" =~ stuck ]] && s=$((s + 1))
		[[ "$q" =~ (removing|gone|disappear) ]] && s=$((s + 1))
		;;
	node_notready)
		[[ "$q" =~ node ]] && s=$((s + 1))
		[[ "$q" =~ not[[:space:]]*ready ]] && s=$((s + 4))
		[[ "$q" =~ scheduling[[:space:]]*disabled ]] && s=$((s + 4))
		[[ "$q" =~ schedulingdisabled ]] && s=$((s + 4))
		[[ "$q" =~ (unreachable|notready|cordon) ]] && s=$((s + 3))
		# "stuck" without delete/terminate leans NotReady, not deleting
		if [[ "$q" =~ stuck ]] && ! [[ "$q" =~ (delet|terminat) ]]; then
			s=$((s + 2))
		fi
		;;
	cluster_version)
		[[ "$q" =~ cluster[[:space:]]+version ]] && s=$((s + 5))
		[[ "$q" =~ ocp[[:space:]]+version ]] && s=$((s + 5))
		[[ "$q" =~ openshift[[:space:]]+version ]] && s=$((s + 4))
		[[ "$q" =~ upgrade ]] && s=$((s + 3))
		[[ "$q" =~ what[[:space:]]+version ]] && s=$((s + 3))
		[[ "$q" =~ version[[:space:]]+is[[:space:]]+the[[:space:]]+cluster ]] && s=$((s + 4))
		[[ "$q" =~ cluster[[:space:]]+on ]] && [[ "$q" =~ version ]] && s=$((s + 2))
		# "cvo" as a health check belongs to controlplane, not version number
		if [[ "$q" =~ cvo ]] && [[ "$q" =~ (check|issue|problem|broken|fail|degrad|health) ]]; then
			s=0
		elif [[ "$q" =~ cvo ]]; then
			s=$((s + 3))
		fi
		;;
	cpms)
		[[ "$q" =~ cpms ]] && s=$((s + 6))
		[[ "$q" =~ control[[:space:]]*plane[[:space:]]*machine ]] && s=$((s + 6))
		[[ "$q" =~ controlplanemachineset ]] && s=$((s + 6))
		;;
	operators)
		[[ "$q" =~ degrad ]] && s=$((s + 3))
		[[ "$q" =~ (cluster[[:space:]]*operator|clusteroperator) ]] && s=$((s + 3))
		[[ "$q" =~ operator ]] && s=$((s + 2))
		[[ "$q" =~ failing ]] && [[ "$q" =~ operator ]] && s=$((s + 2))
		[[ "$q" =~ available ]] && [[ "$q" =~ operator ]] && s=$((s + 1))
		;;
	mcp)
		[[ "$q" =~ mcp ]] && s=$((s + 5))
		[[ "$q" =~ machine[[:space:]]*config ]] && s=$((s + 4))
		[[ "$q" =~ machineconfigpool ]] && s=$((s + 5))
		[[ "$q" =~ rendered[[:space:]]*machine ]] && s=$((s + 3))
		[[ "$q" =~ paused ]] && [[ "$q" =~ (mcp|machine|pool) ]] && s=$((s + 2))
		;;
	crashloop)
		[[ "$q" =~ crashloop ]] && s=$((s + 6))
		[[ "$q" =~ imagepull ]] && s=$((s + 4))
		[[ "$q" =~ oomkilled ]] && s=$((s + 4))
		[[ "$q" =~ pod ]] && [[ "$q" =~ (restart|crash|fail|error|pending) ]] && s=$((s + 3))
		[[ "$q" =~ container[[:space:]]+creating ]] && s=$((s + 2))
		;;
	machines)
		[[ "$q" =~ machineset ]] && s=$((s + 4))
		[[ "$q" =~ machine[[:space:]]*api ]] && s=$((s + 4))
		[[ "$q" =~ machines ]] && s=$((s + 3))
		[[ "$q" =~ machine ]] && s=$((s + 1))
		# do not steal MachineConfig / CPMS questions
		if [[ "$q" =~ machine[[:space:]]*config ]] || [[ "$q" =~ mcp ]] || [[ "$q" =~ control[[:space:]]*plane[[:space:]]*machine ]] || [[ "$q" =~ cpms ]]; then
			s=0
		fi
		;;
	events)
		[[ "$q" =~ events ]] && s=$((s + 4))
		[[ "$q" =~ warnings ]] && s=$((s + 3))
		[[ "$q" =~ warning[[:space:]]+events ]] && s=$((s + 4))
		;;
	whoami)
		[[ "$q" =~ whoami ]] && s=$((s + 6))
		[[ "$q" =~ who[[:space:]]+am[[:space:]]+i ]] && s=$((s + 6))
		[[ "$q" =~ what[[:space:]]+user ]] && s=$((s + 3))
		[[ "$q" =~ logged[[:space:]]+in ]] && s=$((s + 3))
		[[ "$q" =~ which[[:space:]]+cluster ]] && [[ "$q" =~ (am[[:space:]]+i|logged|talking|connected) ]] && s=$((s + 3))
		[[ "$q" =~ kubeconfig ]] && s=$((s + 2))
		[[ "$q" =~ context ]] && [[ "$q" =~ (current|which|what) ]] && s=$((s + 2))
		;;
	overview)
		[[ "$q" =~ overview ]] && s=$((s + 4))
		[[ "$q" =~ cluster[[:space:]]+health ]] && s=$((s + 5))
		[[ "$q" =~ health[[:space:]]+check ]] && s=$((s + 4))
		[[ "$q" =~ status[[:space:]]+of[[:space:]]+the[[:space:]]+cluster ]] && s=$((s + 4))
		[[ "$q" =~ health ]] && [[ "$q" =~ cluster ]] && s=$((s + 2))
		;;
	check)
		[[ "$q" =~ anything[[:space:]]+broken ]] && s=$((s + 6))
		[[ "$q" =~ what[[:space:]]+is[[:space:]]+broken ]] && s=$((s + 6))
		[[ "$q" =~ what[[:space:]]+is[[:space:]]+wrong ]] && s=$((s + 6))
		[[ "$q" =~ check[[:space:]]+(the[[:space:]]+)?cluster ]] && s=$((s + 5))
		[[ "$q" =~ check[[:space:]]+this[[:space:]]+cluster[[:space:]]+operator ]] && s=$((s + 8))
		[[ "$q" =~ full[[:space:]]+(check|diagnostic) ]] && s=$((s + 5))
		[[ "$q" =~ deep[[:space:]]+(check|dive|health) ]] && s=$((s + 5))
		[[ "$q" =~ diagnose ]] && s=$((s + 3))
		if [[ "$q" =~ (^|[[:space:]])check([[:space:]]|$) ]] && [[ "$q" =~ (issue|problem|broken|fail|error|operator) ]]; then
			s=$((s + 4))
		fi
		local extracted=""
		extracted="$(extract_operator_from_question "$q")" || true
		if [[ -n "$extracted" && "$extracted" != "cluster-version" ]]; then
			if [[ "$q" =~ (check|issue|problem|broken|fail|degrad|debug|wrong) ]]; then
				s=$((s + 7))
			fi
		fi
		;;
	controlplane)
		if [[ "$q" =~ control[[:space:]]*plane ]] && ! [[ "$q" =~ control[[:space:]]*plane[[:space:]]*machine ]]; then
			s=$((s + 8))
		fi
		[[ "$q" =~ check[[:space:]]+masters ]] && s=$((s + 8))
		[[ "$q" =~ master[[:space:]]+nodes ]] && s=$((s + 7))
		[[ "$q" =~ masters ]] && s=$((s + 6))
		[[ "$q" =~ static[[:space:]]+pods ]] && s=$((s + 5))
		[[ "$q" =~ cvo ]] && s=$((s + 8))
		[[ "$q" =~ cluster[[:space:]]+version[[:space:]]+operator ]] && s=$((s + 8))
		;;
	esac
	printf '%s' "$s"
}

normalize_question() {
	local s="$1"
	# lowercase via bash
	s="${s,,}"
	# keep letters, digits, dots, hyphens; turn the rest into spaces
	s="$(printf '%s' "$s" | tr -c 'a-z0-9.-' ' ')"
	s="$(printf '%s' "$s" | tr -s ' ')"
	s="$(trim "$s")"
	printf '%s' "$s"
}

# match_intent QUESTION
# prints: BEST_ID<TAB>BEST_SCORE<TAB>SECOND_ID<TAB>SECOND_SCORE
match_intent() {
	local q
	q="$(normalize_question "$1")"
	local best_id="" best_s=0 second_id="" second_s=0
	local id s
	for id in "${INTENT_IDS[@]}"; do
		s="$(score_intent "$id" "$q")"
		if ((s > best_s)); then
			second_id="$best_id"
			second_s="$best_s"
			best_id="$id"
			best_s="$s"
		elif ((s > second_s)); then
			second_id="$id"
			second_s="$s"
		fi
	done
	printf '%s\t%s\t%s\t%s' "$best_id" "$best_s" "$second_id" "$second_s"
}

THRESHOLD=2

list_intents() {
	local id
	echo "${C_BOLD}Known playbooks and example questions${C_RST}"
	echo
	for id in "${INTENT_IDS[@]}"; do
		echo "${C_BOLD}$id${C_RST} — ${INTENT_TITLE[$id]}"
		local ex="${INTENT_EXAMPLES[$id]}"
		local part
		IFS='|' read -ra parts <<<"$ex"
		for part in "${parts[@]}"; do
			echo "    e.g. $part"
		done
		echo
	done
	echo "Tip: include a resource name when you have one (node hostname, or dns/ovn/auth/ingress/etcd)."
	echo "Tip: \"check masters\" / \"check the control plane\" uses kubeconfig only (no SSH to masters)."
}

###############################################################################
# resource name extraction
###############################################################################

# Words from the question that look like k8s names (not stopwords).
question_tokens() {
	local q="$1"
	local t
	for t in $q; do
		case "$t" in
		the | a | an | is | are | or | not | of | in | on | at | to | for | and | \
			what | why | how | which | who | am | i | my | me | any | there | \
			stuck | state | reason | enabled | cluster | node | nodes | pod | pods | \
			operator | operators | version | status | show | list | get | please | \
			deleting | delete | terminating | ready | notready | machine | machines)
			continue
			;;
		esac
		printf '%s\n' "$t"
	done
}

pick_named_from_list() {
	local question="$1"
	shift
	local qn n
	qn="$(normalize_question "$question")"
	for n in "$@"; do
		[[ -z "$n" ]] && continue
		if [[ "$qn" == *"${n,,}"* ]]; then
			printf '%s' "$n"
			return 0
		fi
	done
	return 1
}

# Map casual names ("dns", "ovn", "auth") to ClusterOperator metadata.name.
# Longer keys first so "kube-apiserver" wins over a hypothetical "api".
OPERATOR_ALIAS_KEYS=(
	kube-controller-manager kube-storage-version-migrator openshift-controller-manager
	ovnkube-control-plane ovnkube-master cluster-config-operator config-operator
	control-plane-machine-set operator-lifecycle-manager cluster-autoscaler
	cloud-controller-manager csi-snapshot-controller kube-apiserver kube-scheduler
	openshift-apiserver openshift-samples image-registry machine-approver
	machine-config authentication ingress-operator dns-operator
	oauth-apiserver oauthapiserver cluster-version clusterversion cluster-config
	machine-api node-tuning service-ca marketplace monitoring
	ovnkube webconsole imageregistry coredns prometheus grafana
	alertmanager serviceca scheduler apiserver ingress network
	console storage registry oauth tuned router haproxy
	insights samples etcd auth dns ovn sdn cni csi olm mco mcd ccm kas oas mai nfd cvo
)

declare -A OPERATOR_ALIAS=(
	[dns]=dns [coredns]=dns [dns-operator]=dns
	[network]=network [ovn]=network [ovnkube]=network [sdn]=network [cni]=network [networking]=network
	[auth]=authentication [oauth]=authentication [authentication]=authentication
	[ingress]=ingress [router]=ingress [haproxy]=ingress [ingress-operator]=ingress [route]=ingress
	[etcd]=etcd
	[mco]=machine-config [machine-config]=machine-config [machineconfig]=machine-config
	[console]=console [webconsole]=console
	[registry]=image-registry [image-registry]=image-registry [imageregistry]=image-registry
	[monitoring]=monitoring [prometheus]=monitoring [grafana]=monitoring [alertmanager]=monitoring
	[storage]=storage [csi]=storage [csi-snapshot-controller]=csi-snapshot-controller
	[olm]=operator-lifecycle-manager [operator-lifecycle-manager]=operator-lifecycle-manager
	[kube-apiserver]=kube-apiserver [apiserver]=kube-apiserver [kas]=kube-apiserver
	[kube-scheduler]=kube-scheduler [scheduler]=kube-scheduler
	[kube-controller-manager]=kube-controller-manager
	[openshift-apiserver]=openshift-apiserver [oas]=openshift-apiserver
	[openshift-controller-manager]=openshift-controller-manager
	[machine-api]=machine-api [mai]=machine-api
	[machine-approver]=machine-approver
	[control-plane-machine-set]=control-plane-machine-set
	[node-tuning]=node-tuning [tuned]=node-tuning
	[service-ca]=service-ca [serviceca]=service-ca
	[marketplace]=marketplace [insights]=insights [samples]=openshift-samples [openshift-samples]=openshift-samples
	[cluster-autoscaler]=cluster-autoscaler
	[cloud-controller-manager]=cloud-controller-manager [ccm]=cloud-controller-manager [cloud]=cloud-controller-manager
	[kube-storage-version-migrator]=kube-storage-version-migrator
	[oauth-apiserver]=authentication [oauthapiserver]=authentication
	[cvo]=cluster-version [cluster-version]=cluster-version [clusterversion]=cluster-version
	[ovnkube-control-plane]=network [ovnkube-master]=network
	[config-operator]=config [cluster-config-operator]=config [cluster-config]=config
	[mcd]=machine-config
)

# Prints canonical ClusterOperator name if the question names one (or a common alias).
extract_operator_from_question() {
	local q padded key spaced canon
	q="$(normalize_question "$1")"
	padded=" $q "
	for key in "${OPERATOR_ALIAS_KEYS[@]}"; do
		spaced="${key//-/ }"
		if [[ "$padded" == *" $key "* || "$padded" == *" $spaced "* ]]; then
			canon="${OPERATOR_ALIAS[$key]:-}"
			if [[ -n "$canon" ]]; then
				printf '%s' "$canon"
				return 0
			fi
		fi
	done
	return 1
}

# OpenShift control-plane catalog for self-managed / IPI-style masters.
# Customer namespaces on masters are ignored.
#
# Sources (OpenShift 4 docs + operator git):
#   docs.redhat.com OCP architecture "Control plane" tables:
#     K8s on masters: kube-apiserver, etcd, kube-controller-manager, kube-scheduler
#     OpenShift on masters: openshift-apiserver, openshift-controller-manager,
#       oauth-apiserver, oauth-server (Authentication operator)
#     host systemd (not Operators): kubelet, crio — must be up before any pod
#     installer-* / revision-pruner-* in openshift-etcd, openshift-kube-apiserver,
#       openshift-kube-controller-manager, openshift-kube-scheduler
#   CVO vs OLM: ClusterOperators are CVO-managed; OLM does not manage them
#   OVN-Kubernetes 4.14+: ovnkube-master renamed ovnkube-control-plane (cluster
#     manager / IPAM on masters). ovnkube-node is a DaemonSet on every node.
#   CVO operator Deployments typically use
#     nodeSelector node-role.kubernetes.io/master or .../control-plane
#     plus master/control-plane NoSchedule tolerations (not customer workloads).
#
# kind:
#   static     — kubelet static pods from /etc/kubernetes/manifests (every master)
#   cp-api     — OpenShift/K8s API or controller that belongs on masters
#   cp-net     — OVN control-plane on masters (not ovnkube-node)
#   node-agent — DaemonSet on every node including masters
#   operator   — CVO operator Deployment typically pinned to masters; operand
#                may live on workers/infra (ingress routers, registry, …)
#
# columns: co<TAB>operator_ns<TAB>operand_ns(csv)<TAB>kind<TAB>what_on_masters
# Use "-" for an empty operator_ns (bash IFS collapses adjacent tabs).
cp_catalog_print() {
	cat <<'EOF'
etcd	openshift-etcd-operator	openshift-etcd	static	etcd static pod; installer-*; revision-pruner-*
kube-apiserver	openshift-kube-apiserver-operator	openshift-kube-apiserver	static	kube-apiserver static pod; installer-*; revision-pruner-*
kube-controller-manager	openshift-kube-controller-manager-operator	openshift-kube-controller-manager	static	kube-controller-manager + cluster-policy-controller; installer-*; revision-pruner-*
kube-scheduler	openshift-kube-scheduler-operator	openshift-kube-scheduler	static	kube-scheduler static pod; installer-*; revision-pruner-*
openshift-apiserver	openshift-apiserver-operator	openshift-apiserver	cp-api	OpenShift API server
openshift-controller-manager	openshift-controller-manager-operator	openshift-controller-manager,openshift-route-controller-manager	cp-api	OpenShift + route controller managers
authentication	openshift-authentication-operator	openshift-authentication,openshift-oauth-apiserver	cp-api	OAuth server + OAuth API server
cloud-controller-manager	openshift-cloud-controller-manager-operator	openshift-cloud-controller-manager	cp-api	cloud controller manager (platform-dependent)
network	openshift-network-operator	openshift-ovn-kubernetes,openshift-network-operator,openshift-multus,openshift-sdn	cp-net	ovnkube-control-plane (was ovnkube-master); ovnkube-node is a node-agent on all nodes
dns	openshift-dns-operator	openshift-dns	node-agent	dns-operator on masters; dns-default CoreDNS DS on every node
machine-config	openshift-machine-config-operator	openshift-machine-config-operator	node-agent	MCO/MCC on masters; machine-config-daemon on every node
node-tuning	openshift-cluster-node-tuning-operator	openshift-cluster-node-tuning-operator	node-agent	NTO on masters; tuned DS on every node
machine-api	openshift-machine-api	openshift-machine-api	operator	Machine API controllers + CPMS (typically masters)
control-plane-machine-set	openshift-machine-api	openshift-machine-api	operator	ControlPlaneMachineSet controller
cloud-credential	openshift-cloud-credential-operator	openshift-cloud-credential-operator	operator	Cloud Credential Operator
config	openshift-config-operator	openshift-config,openshift-config-managed	operator	cluster-config-operator
console	openshift-console-operator	openshift-console	operator	console-operator on masters
ingress	openshift-ingress-operator	openshift-ingress-operator	operator	ingress-operator on masters (routers usually workers/infra — omitted)
storage	openshift-cluster-storage-operator	openshift-cluster-storage-operator	operator	cluster-storage-operator on masters
csi-snapshot-controller	openshift-cluster-storage-operator	openshift-cluster-storage-operator	operator	csi-snapshot-controller on masters
monitoring	openshift-monitoring	openshift-monitoring	operator	cluster-monitoring-operator typically on masters
insights	openshift-insights	openshift-insights	operator	insights-operator on masters
image-registry	openshift-image-registry	openshift-image-registry	operator	registry-operator on masters (registry pods often infra)
kube-storage-version-migrator	openshift-kube-storage-version-migrator-operator	openshift-kube-storage-version-migrator	operator	migrator on control-plane nodes
service-ca	openshift-service-ca-operator	openshift-service-ca	operator	service-ca
machine-approver	openshift-cluster-machine-approver	openshift-cluster-machine-approver	operator	CSR approver
operator-lifecycle-manager	openshift-operator-lifecycle-manager	openshift-operator-lifecycle-manager	operator	OLM / packageserver typically master-scheduled
marketplace	openshift-marketplace	openshift-marketplace	operator	marketplace
cluster-autoscaler	openshift-machine-api	openshift-machine-api	operator	cluster-autoscaler-operator
cluster-version	-	openshift-cluster-version	operator	CVO (ClusterVersion CR; not a ClusterOperator name)
EOF
}

# Prints catalog kind (static|cp-api|cp-net|node-agent|operator) for a CO name.
cp_kind_for_co() {
	local want="$1" co ons opns kind
	while IFS=$'\t' read -r co ons opns kind _; do
		[[ -z "$co" ]] && continue
		if [[ "$co" == "$want" ]]; then
			printf '%s' "$kind"
			return 0
		fi
	done <<<"$(cp_catalog_print)"
	return 1
}

print_cp_catalog_findings() {
	local co ons opns kind what
	finding "Platform on masters (CVO ClusterOperators + node agents). Customer pods ignored."
	finding "  static = kubelet static pods; cp-api = APIs/controllers; cp-net = OVN control-plane;"
	finding "  node-agent = DS on every node; operator = CVO operator Deployment typically on masters."
	while IFS=$'\t' read -r co ons opns kind what; do
		[[ -z "$co" ]] && continue
		finding "  [$kind] $co — $what"
	done <<<"$(cp_catalog_print)"
}

# This playbook actually walks these layers in order. Do not skip to logs first.
# Every layer is Kubernetes API via kubeconfig. No SSH, no oc debug onto the node.
explain_controlplane_path() {
	finding "Access model: this laptop's kubeconfig → API server. No SSH to masters, no internet."
	finding "Troubleshooting path (lowest API-visible layer first):"
	finding "  L0 Node object (Ready/conditions) + oc adm node-logs (API→kubelet journal)."
	finding "     kubelet/crio are host systemd; this script cannot log into the master."
	finding "     If node-logs fails (RBAC or kubelet down), host journals are simply unavailable."
	finding "  L1 static pods via oc logs: etcd, kube-apiserver, kube-controller-manager, kube-scheduler"
	finding "     (mirror pods in the API; installer-* / revision-pruner-* in those four namespaces)."
	finding "  L2 CVO (openshift-cluster-version) owns ClusterVersion and the payload."
	finding "  L3 ClusterOperator status (Available / Degraded / Progressing) + relatedObjects."
	finding "  L4 operator namespace (*-operator) — the manager; then operand pods ON masters only."
	finding "  L5 OpenShift APIs on masters: openshift-apiserver, oauth-apiserver, oauth-server,"
	finding "     openshift-controller-manager; OVN: ovnkube-control-plane (4.14+; was ovnkube-master)."
	finding "  L6 if the machine itself is wrong: MCP/master, Machine, ControlPlaneMachineSet."
	finding "CVO-managed operators (not OLM) typically pin their operator pods to master/control-plane."
	finding "Customer workloads on masters are out of scope."
}

MASTER_NODES=""
FOCUS_MASTERS=0

load_master_nodes() {
	MASTER_NODES=""
	local json names=""
	oc_ro get nodes -o json || true
	json="$LAST_OUT"
	if [[ "$HAS_JQ" -eq 1 && -n "$json" ]]; then
		jq_eval '.items[] | select(.metadata.labels["node-role.kubernetes.io/master"] != null or .metadata.labels["node-role.kubernetes.io/control-plane"] != null) | .metadata.name' "$json" || true
		names="$(printf '%s' "$JQ_OUT" | tr '\n' ' ')"
	else
		oc_ro get nodes -l node-role.kubernetes.io/master -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' || true
		names="$LAST_OUT"
		if [[ -z "$(trim "$names")" ]]; then
			oc_ro get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' || true
			names="$LAST_OUT"
		fi
	fi
	MASTER_NODES="$(trim "$names")"
	if [[ -z "$MASTER_NODES" ]]; then
		finding "No nodes with master or control-plane role were found."
		return 1
	fi
	finding "Control-plane nodes: $MASTER_NODES"
	return 0
}

# Host journals without SSH: API server asks kubelet for journald.
# Needs nodes/proxy (or equivalent) RBAC and a kubelet that is still serving.
# Returns 0 if any log text was retrieved.
api_node_unit_logs() {
	local node="$1" unit="$2"
	oc_ro adm node-logs "$node" -u "$unit" --tail=40 || true
	if [[ "$LAST_RC" -eq 0 ]] && lines_nonempty "$LAST_OUT"; then
		finding "    $unit journal via API (oc adm node-logs; not SSH) for $node:"
		append_log_excerpt "    $unit $node" "$LAST_OUT" 15
		return 0
	fi
	finding "    $unit journal not reachable via API for $node: $(trim "${LAST_ERR:-empty}")."
	finding "    This utility does not SSH or oc debug onto the node. Using Node conditions and pod oc logs instead."
	return 1
}

jq_eval_masters() {
	local query="$1"
	local json="${2-}"
	JQ_OUT=""
	if [[ -z "$json" ]]; then
		json="${LAST_OUT}"
	fi
	if [[ "$HAS_JQ" -ne 1 ]]; then
		return 1
	fi
	COMMAND_LOG+=("| $JQ -r --arg masters $(printf '%q' "$MASTER_NODES") $(printf '%q' "$query")")
	if [[ "$DRY_RUN" -eq 1 || -z "$json" ]]; then
		return 0
	fi
	local rc=0
	JQ_OUT="$(printf '%s' "$json" | "$JQ" -r --arg masters "$MASTER_NODES" "$query" 2>/dev/null)" || rc=$?
	if [[ "$rc" -ne 0 || "$JQ_OUT" == "null" ]]; then
		JQ_OUT=""
		return 1
	fi
	return 0
}

jq_unhealthy_on_masters_query='
($masters | split(" ") | map(select(. != ""))) as $m
| .items[]?
| select((.spec.nodeName as $n | $m | index($n)) != null)
| select(
    (.status.phase != "Succeeded") and (
      (.status.phase != "Running")
      or any(
        ((.status.containerStatuses // []) + (.status.initContainerStatuses // []))[];
        ((.state.waiting.reason // "") == "CrashLoopBackOff")
        or ((.state.waiting.reason // "") == "ImagePullBackOff")
        or ((.state.waiting.reason // "") == "ErrImagePull")
        or ((.state.waiting.reason // "") == "Error")
        or ((.state.terminated.reason // "") == "OOMKilled")
        or ((.state.terminated.reason // "") == "Error")
      )
    )
  )
| [.metadata.name, .status.phase, .spec.nodeName] | @tsv
'

jq_master_pod_summary_query='
($masters | split(" ") | map(select(. != ""))) as $m
| [.items[]? | select((.spec.nodeName as $n | $m | index($n)) != null)] as $p
| "on_masters=\($p|length) running=\($p | map(select(.status.phase=="Running")) | length)"
'

jq_master_ns_counts_query='
($masters | split(" ") | map(select(. != ""))) as $m
| [.items[]?
   | select((.spec.nodeName as $n | $m | index($n)) != null)
   | select((.metadata.namespace | startswith("openshift-")) or .metadata.namespace == "kube-system")
  ]
| group_by(.metadata.namespace)
| .[]
| "\(.[0].metadata.namespace)\tcount=\(length)\trunning=\(map(select(.status.phase=="Running")) | length)"
'

jq_unhealthy_platform_on_masters_query='
($masters | split(" ") | map(select(. != ""))) as $m
| .items[]?
| select((.spec.nodeName as $n | $m | index($n)) != null)
| select((.metadata.namespace | startswith("openshift-")) or .metadata.namespace == "kube-system")
| select(
    (.status.phase != "Succeeded") and (
      (.status.phase != "Running")
      or any(
        ((.status.containerStatuses // []) + (.status.initContainerStatuses // []))[];
        ((.state.waiting.reason // "") == "CrashLoopBackOff")
        or ((.state.waiting.reason // "") == "ImagePullBackOff")
        or ((.state.waiting.reason // "") == "ErrImagePull")
        or ((.state.waiting.reason // "") == "Error")
        or ((.state.terminated.reason // "") == "OOMKilled")
        or ((.state.terminated.reason // "") == "Error")
      )
    )
  )
| [.metadata.namespace, .metadata.name, .status.phase, .spec.nodeName] | @tsv
'

is_platform_ns() {
	local ns="$1"
	[[ "$ns" == openshift-* || "$ns" == kube-system ]]
}

cp_namespaces_for_co() {
	local want="$1" line co ons opns
	while IFS=$'\t' read -r co ons opns _ _; do
		[[ -z "$co" ]] && continue
		if [[ "$co" == "$want" ]]; then
			local n
			if [[ -n "$ons" && "$ons" != "-" ]]; then
				printf '%s\n' "$ons"
			fi
			local parts
			IFS=',' read -ra parts <<<"$opns"
			for n in "${parts[@]}"; do
				n="$(trim "$n")"
				[[ -n "$n" ]] && printf '%s\n' "$n"
			done
			return 0
		fi
	done <<<"$(cp_catalog_print)"
	return 1
}

###############################################################################
# shared gather snippets
###############################################################################

lines_nonempty() {
	local s="${1:-}"
	[[ -n "$(trim "$s")" ]]
}

count_lines() {
	local s="${1:-}"
	if [[ -z "$(trim "$s")" ]]; then
		echo 0
		return
	fi
	printf '%s\n' "$s" | grep -c . || true
}

first_line() {
	local s="${1:-}"
	printf '%s\n' "$s" | head -n 1
}

###############################################################################
# playbooks
###############################################################################

# Reads: whoami, version --client, auth can-i. Writes suggested: oc login (kubeconfig only).
playbook_whoami() {
	local user server ctx console can_nodes clientver
	oc_ro whoami || true
	user="$LAST_OUT"
	oc_ro whoami --show-server || true
	server="$LAST_OUT"
	oc_ro whoami -c || true
	ctx="$LAST_OUT"
	oc_ro whoami --show-console || true
	console="$LAST_OUT"
	oc_ro version --client || true
	clientver="$LAST_OUT"
	oc_ro auth can-i get nodes --all-namespaces || true
	can_nodes="$LAST_OUT"

	end_if_dry_run && return 0

	if is_present "$user"; then
		finding "Current user: $(trim "$user")"
	else
		finding "oc whoami failed: $(trim "$LAST_ERR")"
		suggest "# You may need to log in (this is a write to local kubeconfig, not the cluster):"
		suggest "oc login"
		print_report
		return 0
	fi
	is_present "$server" && finding "API server: $(trim "$server")"
	is_present "$ctx" && finding "kubeconfig context: $(trim "$ctx")"
	is_present "$console" && finding "Console URL: $(trim "$console")"
	if is_present "$clientver"; then
		finding "Client: $(trim "$(printf '%s\n' "$clientver" | head -n 1)")"
	fi
	if [[ "$(trim "$can_nodes")" == "yes" ]]; then
		finding "This identity can get nodes cluster-wide."
	else
		finding "This identity cannot get nodes cluster-wide (auth can-i returned: $(trim "$can_nodes")). Some playbooks will be incomplete."
	fi
	print_report
}

# Reads: clusterversion, adm upgrade, clusteroperator. Writes suggested: oc adm upgrade --to* (not run).
playbook_cluster_version() {
	local desired current channel conds updates history adm_out co_out
	oc_ro get clusterversion version -o jsonpath='{.status.desired.version}' || true
	desired="$LAST_OUT"
	oc_ro get clusterversion version -o jsonpath='{.status.history[0].version}' || true
	current="$LAST_OUT"
	oc_ro get clusterversion version -o jsonpath='{.spec.channel}' || true
	channel="$LAST_OUT"
	oc_ro get clusterversion version -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}' || true
	conds="$LAST_OUT"
	oc_ro get clusterversion version -o jsonpath='{range .status.availableUpdates[*]}{.version}{"\n"}{end}' || true
	updates="$LAST_OUT"
	oc_ro get clusterversion version -o jsonpath='{range .status.history[*]}{.version}{"\t"}{.state}{"\t"}{.completionTime}{"\n"}{end}' || true
	history="$LAST_OUT"
	oc_ro adm upgrade || true
	adm_out="$LAST_OUT"
	oc_ro get clusteroperator || true
	co_out="$LAST_OUT"

	end_if_dry_run && return 0

	if ! is_present "$desired" && ! is_present "$current"; then
		finding "Could not read ClusterVersion/version. Is this an OpenShift cluster, and can this user get clusterversions.config.openshift.io?"
		[[ -n "$LAST_ERR" ]] && finding "error: $(trim "$LAST_ERR")"
		print_report
		return 0
	fi

	finding "Desired version: ${desired:-unknown}"
	finding "Latest history version: ${current:-unknown}"
	is_present "$channel" && finding "Channel: $channel"

	local line ctype cstatus creason cmsg progressing=0 failing=0 retrieved=0
	while IFS=$'\t' read -r ctype cstatus creason cmsg; do
		[[ -z "${ctype:-}" ]] && continue
		case "$ctype" in
		Available)
			finding "ClusterVersion Available=$cstatus reason=$creason — $cmsg"
			;;
		Progressing)
			finding "ClusterVersion Progressing=$cstatus reason=$creason — $cmsg"
			[[ "$cstatus" == "True" ]] && progressing=1
			;;
		Failing)
			finding "ClusterVersion Failing=$cstatus reason=$creason — $cmsg"
			[[ "$cstatus" == "True" ]] && failing=1
			;;
		RetrievedUpdates)
			finding "RetrievedUpdates=$cstatus reason=$creason"
			[[ "$cstatus" == "True" ]] && retrieved=1
			;;
		ImplicitlyEnabledCapabilities | ReleaseAccepted | Upgradeable)
			finding "ClusterVersion $ctype=$cstatus reason=$creason — $cmsg"
			;;
		esac
	done <<<"$conds"

	if [[ "$progressing" -eq 1 ]]; then
		finding "An upgrade or reconciliation appears to be in progress."
	else
		finding "No ClusterVersion Progressing=True at the moment."
	fi
	if [[ "$failing" -eq 1 ]]; then
		finding "ClusterVersion is Failing. Inspect conditions above and degraded operators."
	fi

	if lines_nonempty "$updates"; then
		finding "Available updates: $(printf '%s' "$updates" | tr '\n' ' ' | awk '{$1=$1;print}')"
	else
		if [[ "$retrieved" -eq 1 ]]; then
			finding "No availableUpdates listed (cluster may already be on the latest recommended version for this channel)."
		else
			finding "Could not list availableUpdates (RetrievedUpdates may be False, or Cincinnati/OSUS is unreachable)."
		fi
	fi

	if lines_nonempty "$history"; then
		finding "Recent version history (version, state, completionTime):"
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			finding "    $line"
		done <<<"$history"
	fi

	if lines_nonempty "$adm_out"; then
		finding "oc adm upgrade output:"
		while IFS= read -r line; do
			finding "    $line"
		done <<<"$adm_out"
	fi

	# degraded COs — light check; full detail is the operators playbook
	if lines_nonempty "$co_out"; then
		local deg
		deg="$(printf '%s\n' "$co_out" | awk 'NR>1 && $3=="True" {print $1}' || true)"
		# default columns: NAME VERSION AVAILABLE PROGRESSING DEGRADED SINCE MESSAGE
		# Actually: NAME  VERSION  AVAILABLE  PROGRESSING  DEGRADED  SINCE  MESSAGE
		deg="$(printf '%s\n' "$co_out" | awk 'NR>1 && $5=="True" {print $1}' || true)"
		if lines_nonempty "$deg"; then
			finding "Degraded cluster operators: $(printf '%s' "$deg" | tr '\n' ' ')"
			suggest "# A write is not always required; first inspect the operator:"
			suggest "oc describe clusteroperator $(first_line "$deg")"
			suggest "# If you need a full dump of related objects (still cluster-read, writes a local directory):"
			suggest "oc adm inspect clusteroperator/$(first_line "$deg")"
		else
			finding "No cluster operator has DEGRADED=True in the table."
		fi
	fi

	if [[ "$progressing" -eq 1 || "$failing" -eq 1 ]]; then
		suggest "# Upgrades are controlled by ClusterVersion. Do not patch unless you intend to change the target:"
		suggest "oc adm upgrade   # read-only status; adding --to / --to-latest / --to-image WRITES"
		suggest "oc adm upgrade status --details=all"
	fi
	print_report
}

# Reads: controlplanemachineset, master Machines. Writes suggested: patch spec.state=Active (one-way).
playbook_cpms() {
	local table state replicas ready current updated name conds
	oc_ro get controlplanemachineset -n openshift-machine-api || true
	table="$LAST_OUT"
	local get_rc="$LAST_RC"

	oc_ro get controlplanemachineset -n openshift-machine-api -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.state}{"\t"}{.spec.replicas}{"\t"}{.status.replicas}{"\t"}{.status.readyReplicas}{"\t"}{.status.updatedReplicas}{"\n"}{end}' || true
	local rows="$LAST_OUT"
	oc_ro get controlplanemachineset -n openshift-machine-api -o jsonpath='{range .items[*]}{range .status.conditions[*]}{.type}{"="}{.status}{" "}{.reason}{" — "}{.message}{"\n"}{end}{end}' || true
	conds="$LAST_OUT"
	oc_ro get machines -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-role=master -o custom-columns=NAME:.metadata.name,NODE:.status.nodeRef.name,PHASE:.status.phase,DEL:.metadata.deletionTimestamp --no-headers || true
	local masters="$LAST_OUT"

	end_if_dry_run && return 0

	if [[ "$get_rc" -ne 0 ]]; then
		finding "Could not list ControlPlaneMachineSets in openshift-machine-api (rc=$get_rc)."
		finding "error: $(trim "$LAST_ERR")"
		finding "This cluster may lack Machine API (e.g. some hosted/SNO topologies), or this user cannot get machine.openshift.io resources."
		print_report
		return 0
	fi

	if ! lines_nonempty "$rows" && ! lines_nonempty "$table"; then
		finding "No ControlPlaneMachineSet objects exist in openshift-machine-api."
		finding "CPMS is not present, so it is not enabled."
		suggest "# Creating/enabling CPMS is a write and is platform-specific. Typical (irreversible Active) change:"
		suggest "oc patch controlplanemachineset/cluster -n openshift-machine-api --type=merge -p '{\"spec\":{\"state\":\"Active\"}}'"
		suggest "# That patch only works if the CR already exists and is Inactive. Once Active, spec.state cannot be set back to Inactive."
		print_report
		return 0
	fi

	while IFS=$'\t' read -r name state replicas current ready updated; do
		[[ -z "${name:-}" ]] && continue
		finding "ControlPlaneMachineSet/$name spec.state=${state:-<unset>} spec.replicas=${replicas:-?} status.replicas=${current:-?} ready=${ready:-?} updated=${updated:-?}"
		case "${state:-}" in
		Active)
			finding "CPMS is enabled (spec.state=Active). It will reconcile control-plane Machines."
			;;
		Inactive | '')
			finding "CPMS is NOT enabled (spec.state=${state:-unset/default Inactive}). It will not modify control-plane Machines."
			suggest "# Enabling CPMS is a one-way write (cannot be made Inactive again):"
			suggest "oc patch controlplanemachineset/$name -n openshift-machine-api --type=merge -p '{\"spec\":{\"state\":\"Active\"}}'"
			;;
		*)
			finding "Unexpected spec.state='$state'."
			;;
		esac
	done <<<"$rows"

	if lines_nonempty "$conds"; then
		finding "CPMS conditions:"
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			finding "    $line"
		done <<<"$conds"
	fi
	if lines_nonempty "$masters"; then
		finding "Control-plane Machines (role=master):"
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			finding "    $line"
		done <<<"$masters"
	fi
	print_report
}

_node_is_control_plane() {
	local labels="$1"
	[[ "$labels" == *node-role.kubernetes.io/master* || "$labels" == *node-role.kubernetes.io/control-plane* ]]
}

# Reads: node, pods on node, volumeattachments, machines, events, CPMS/MCP, node-logs (API).
# Writes suggested: force-delete pods, delete VA, patch finalizers. Never SSH/debug node.
_inspect_one_node_deleting() {
	local node="$1"
	local ts fins unsched taints labels conds roles

	oc_ro get node "$node" -o jsonpath='{.metadata.deletionTimestamp}' || true
	ts="$LAST_OUT"
	oc_ro get node "$node" -o jsonpath='{.metadata.finalizers}' || true
	fins="$LAST_OUT"
	oc_ro get node "$node" -o jsonpath='{.spec.unschedulable}' || true
	unsched="$LAST_OUT"
	oc_ro get node "$node" -o jsonpath='{range .spec.taints[*]}{.key}{":"}{.effect}{" "}{end}' || true
	taints="$LAST_OUT"
	oc_ro get node "$node" -o jsonpath='{.metadata.labels}' || true
	labels="$LAST_OUT"
	oc_ro get node "$node" -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{" "}{end}' || true
	conds="$LAST_OUT"

	finding "Node $node deletionTimestamp=${ts:-<not set>}"
	if ! is_present "$ts"; then
		finding "Node $node is not in deletion (no deletionTimestamp). If you expected Terminating, the name may be wrong or the node already left the API."
	fi
	finding "Finalizers: ${fins:-<none>}"
	finding "spec.unschedulable=${unsched:-false}  taints: ${taints:-<none>}"
	finding "Conditions: ${conds:-<none>}"

	if _node_is_control_plane "$labels"; then
		finding "This is a control-plane node (master/control-plane role)."
		roles="cp"
	else
		roles="worker"
	fi

	oc_ro get pods -A --field-selector "spec.nodeName=$node" -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,DEL:.metadata.deletionTimestamp,FINALIZERS:.metadata.finalizers --no-headers || true
	local pods="$LAST_OUT"
	local pod_count
	pod_count="$(count_lines "$pods")"
	finding "Pods still assigned to this node: $pod_count"
	local terminating=0
	local pod_line ns pname
	if lines_nonempty "$pods"; then
		while IFS= read -r pod_line; do
			[[ -z "$pod_line" ]] && continue
			finding "    $pod_line"
			# custom-columns: NS NAME PHASE DEL FINALIZERS
			local delcol
			delcol="$(printf '%s\n' "$pod_line" | awk '{print $4}')"
			if is_present "$delcol" || [[ "$pod_line" == *"Terminating"* ]]; then
				terminating=$((terminating + 1))
				ns="$(printf '%s\n' "$pod_line" | awk '{print $1}')"
				pname="$(printf '%s\n' "$pod_line" | awk '{print $2}')"
				suggest "# Force-delete a pod stuck Terminating (WRITE, disruptive):"
				suggest "oc delete pod -n $ns $pname --force --grace-period=0"
			fi
		done <<<"$pods"
	fi
	if [[ "$pod_count" -gt 0 && "$terminating" -eq 0 ]]; then
		suggest "# Pods still scheduled here will block node deletion until they leave. Drain is a WRITE:"
		suggest "oc adm drain $node --ignore-daemonsets --delete-emptydir-data"
	fi

	oc_ro get volumeattachments -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,ATTACHED:.status.attached,DEL:.metadata.deletionTimestamp --no-headers || true
	local vas="$LAST_OUT"
	local va_hit=0 va_name va_node
	if lines_nonempty "$vas"; then
		while IFS= read -r pod_line; do
			va_name="$(printf '%s\n' "$pod_line" | awk '{print $1}')"
			va_node="$(printf '%s\n' "$pod_line" | awk '{print $2}')"
			if [[ "$va_node" == "$node" ]]; then
				va_hit=1
				finding "VolumeAttachment on this node: $pod_line"
				suggest "# Stuck VolumeAttachment can block node deletion (WRITE):"
				suggest "oc delete volumeattachment $va_name"
			fi
		done <<<"$vas"
	fi
	if [[ "$va_hit" -eq 0 ]]; then
		finding "No VolumeAttachments reference this node."
	fi

	oc_ro get machines -n openshift-machine-api -o custom-columns=NAME:.metadata.name,NODE:.status.nodeRef.name,PHASE:.status.phase,DEL:.metadata.deletionTimestamp,ERR:.status.errorMessage,FINALIZERS:.metadata.finalizers --no-headers || true
	local machs="$LAST_OUT" machine_hit=0 mname mnode mphase
	if lines_nonempty "$machs"; then
		while IFS= read -r pod_line; do
			mname="$(printf '%s\n' "$pod_line" | awk '{print $1}')"
			mnode="$(printf '%s\n' "$pod_line" | awk '{print $2}')"
			mphase="$(printf '%s\n' "$pod_line" | awk '{print $3}')"
			if [[ "$mnode" == "$node" || "$mname" == *"$node"* ]]; then
				machine_hit=1
				finding "Matching Machine: $pod_line"
				local mdel
				mdel="$(printf '%s\n' "$pod_line" | awk '{print $4}')"
				if is_present "$mdel"; then
					finding "Machine $mname is also deleting (phase=$mphase). Node cleanup often waits on the Machine / cloud provider."
				else
					finding "Machine $mname still exists and is not deleting (phase=$mphase). The node object may be deleting independently of the Machine."
				fi
				if [[ "$pod_line" == *"finalizer"* || "$pod_line" == *"machine.openshift.io"* ]]; then
					suggest "# DANGEROUS: stripping Machine finalizers can leak cloud VMs/disks:"
					suggest "oc patch machine $mname -n openshift-machine-api --type=merge -p '{\"metadata\":{\"finalizers\":[]}}'"
				fi
			fi
		done <<<"$machs"
	else
		finding "No Machines listed (Machine API missing, empty, or forbidden)."
	fi
	if [[ "$machine_hit" -eq 0 ]]; then
		finding "No Machine in openshift-machine-api references this node."
	fi

	oc_ro get events --field-selector "involvedObject.name=$node" --sort-by=.lastTimestamp || true
	if lines_nonempty "$LAST_OUT"; then
		finding "Recent events for node/$node (last 15 lines):"
		while IFS= read -r line; do
			finding "    $line"
		done <<<"$(printf '%s\n' "$LAST_OUT" | tail -n 15)"
	fi

	if is_present "$fins"; then
		suggest "# DANGEROUS: removing node finalizers can orphan cloud resources:"
		suggest "oc patch node $node --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
	fi

	if [[ "$roles" == "cp" ]]; then
		finding "Control-plane node: also check CPMS / master MCP."
		oc_ro get controlplanemachineset -n openshift-machine-api -o jsonpath='{range .items[*]}{.metadata.name}{" state="}{.spec.state}{" ready="}{.status.readyReplicas}{"/"}{.spec.replicas}{"\n"}{end}' || true
		if lines_nonempty "$LAST_OUT"; then
			finding "    CPMS: $LAST_OUT"
		fi
		oc_ro get mcp master -o jsonpath='paused={.spec.paused} ready={.status.readyMachineCount}/{.status.machineCount} degraded={.status.degradedMachineCount}' || true
		if lines_nonempty "$LAST_OUT"; then
			finding "    MCP/master: $LAST_OUT"
		fi
		suggest "# Do not force-delete a control-plane node until etcd/quorum and CPMS are understood."
	fi

	oc_ro adm node-logs "$node" -u kubelet --tail=50 || true
	if [[ "$LAST_RC" -eq 0 ]] && lines_nonempty "$LAST_OUT"; then
		finding "kubelet journal for $node (last 15 lines):"
		while IFS= read -r line; do
			finding "    $line"
		done <<<"$(printf '%s\n' "$LAST_OUT" | tail -n 15)"
	else
		finding "oc adm node-logs $node failed or empty (API→kubelet; this is not SSH): $(trim "${LAST_ERR:-}")"
		finding "This utility does not SSH or oc debug onto the node. Host journal is unavailable; Node conditions/events and pod oc logs are the remaining API signal."
	fi
}

# Reads: nodes (deletionTimestamp). Delegates to _inspect_one_node_deleting.
playbook_node_deleting() {
	local question="$1"
	local all deleting=() target=""

	oc_ro get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.deletionTimestamp}{"\n"}{end}' || true
	all="$LAST_OUT"
	if [[ "$DRY_RUN" -eq 1 ]]; then
		oc_ro get pods -A --field-selector spec.nodeName=_dry_run --no-headers || true
		oc_ro get volumeattachments --no-headers || true
		oc_ro get machines -n openshift-machine-api --no-headers || true
		oc_ro get events --field-selector involvedObject.kind=Node || true
		oc_ro get controlplanemachineset -n openshift-machine-api || true
		oc_ro adm node-logs --role master -u kubelet --tail=20 || true
	fi

	end_if_dry_run && return 0

	local line n ts
	local node_names=()
	while IFS=$'\t' read -r n ts; do
		[[ -z "${n:-}" ]] && continue
		node_names+=("$n")
		if is_present "$ts"; then
			deleting+=("$n")
			finding "Node $n has deletionTimestamp=$ts"
		fi
	done <<<"$all"

	if ((${#node_names[@]} == 0)); then
		finding "Could not list nodes. Check authentication and RBAC (get nodes)."
		print_report
		return 0
	fi

	target=""
	if ((${#node_names[@]} > 0)); then
		target="$(pick_named_from_list "$question" "${node_names[@]}")" || true
	fi

	if [[ -n "$target" ]]; then
		finding "Question named node: $target"
		_inspect_one_node_deleting "$target"
	elif ((${#deleting[@]} > 0)); then
		finding "No node name in the question; inspecting every node that is deleting (${#deleting[@]})."
		local d
		for d in "${deleting[@]}"; do
			_inspect_one_node_deleting "$d"
		done
	else
		finding "No node currently has a deletionTimestamp. Nothing is stuck in deleting at the API level."
		finding "If a node recently disappeared, check Machines and cloud provider console — the Node object may already be gone."
		oc_ro get machines -n openshift-machine-api -o custom-columns=NAME:.metadata.name,NODE:.status.nodeRef.name,PHASE:.status.phase,DEL:.metadata.deletionTimestamp,ERR:.status.errorMessage --no-headers || true
		if lines_nonempty "$LAST_OUT"; then
			finding "Machines:"
			while IFS= read -r line; do
				finding "    $line"
			done <<<"$LAST_OUT"
		fi
	fi
	print_report
}

# Reads: nodes -o wide, Ready conditions, events, node-logs (API). Writes suggested: uncordon.
# Never SSH or oc debug onto the node.
playbook_node_notready() {
	local question="$1"
	oc_ro get nodes -o wide || true
	local table="$LAST_OUT"
	oc_ro get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\t"}{.reason}{"\t"}{.message}{end}{"\t"}{.spec.unschedulable}{"\n"}{end}' || true
	local rows="$LAST_OUT"

	end_if_dry_run && return 0

	if ! lines_nonempty "$rows"; then
		finding "Could not list node Ready conditions."
		[[ -n "$table" ]] && finding "oc get nodes -o wide:" && while IFS= read -r line; do finding "    $line"; done <<<"$table"
		print_report
		return 0
	fi

	local names=() notready=() unsched=()
	local n ready reason msg uns
	while IFS=$'\t' read -r n ready reason msg uns; do
		[[ -z "${n:-}" ]] && continue
		names+=("$n")
		if [[ "$ready" != "True" ]]; then
			notready+=("$n")
			finding "Node $n Ready=$ready reason=$reason — $msg"
		fi
		if [[ "$uns" == "true" ]]; then
			unsched+=("$n")
			finding "Node $n is unschedulable (SchedulingDisabled / cordoned)."
		fi
	done <<<"$rows"

	local target=""
	if ((${#names[@]} > 0)); then
		target="$(pick_named_from_list "$question" "${names[@]}")" || true
	fi

	local inspect=()
	if [[ -n "$target" ]]; then
		inspect=("$target")
	else
		if ((${#notready[@]} > 0)); then
			inspect=("${notready[@]}")
		fi
		if ((${#unsched[@]} > 0)); then
			local u
			for u in "${unsched[@]}"; do
				[[ -z "$u" ]] && continue
				local seen=0 x
				if ((${#inspect[@]} > 0)); then
					for x in "${inspect[@]}"; do
						[[ "$x" == "$u" ]] && seen=1
					done
				fi
				if [[ "$seen" -eq 0 ]]; then
					inspect+=("$u")
				fi
			done
		fi
	fi

	if ((${#inspect[@]} == 0)); then
		finding "All nodes report Ready=True and none are unschedulable."
		print_report
		return 0
	fi

	local node taints conds
	for node in "${inspect[@]}"; do
		finding "Detail for $node:"
		oc_ro describe node "$node" || true
		# describe is noisy; pull structured fields too
		oc_ro get node "$node" -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{" ("}{.reason}{") "}{end}' || true
		conds="$LAST_OUT"
		finding "    conditions: $conds"
		oc_ro get node "$node" -o jsonpath='{range .spec.taints[*]}{.key}{":"}{.effect}{" "}{end}' || true
		taints="$LAST_OUT"
		finding "    taints: ${taints:-<none>}"
		oc_ro get events --field-selector "involvedObject.name=$node" --sort-by=.lastTimestamp || true
		if lines_nonempty "$LAST_OUT"; then
			finding "    last events:"
			while IFS= read -r line; do
				finding "        $line"
			done <<<"$(printf '%s\n' "$LAST_OUT" | tail -n 10)"
		fi
		oc_ro adm node-logs "$node" -u kubelet --tail=50 || true
		if [[ "$LAST_RC" -eq 0 ]] && lines_nonempty "$LAST_OUT"; then
			finding "    kubelet journal (last 15 lines):"
			while IFS= read -r line; do
				finding "        $line"
			done <<<"$(printf '%s\n' "$LAST_OUT" | tail -n 15)"
		else
			finding "    oc adm node-logs failed or empty (API→kubelet, not SSH; often RBAC or dead kubelet): $(trim "$LAST_ERR")"
			finding "    This utility does not SSH or oc debug onto the node."
		fi
		if [[ "$taints" == *node.kubernetes.io/unschedulable* ]] || [[ " ${unsched[*]-} " == *" $node "* ]]; then
			suggest "# Uncordon is a WRITE (allows scheduling again):"
			suggest "oc adm uncordon $node"
		fi
	done
	print_report
}

# Reads: clusteroperator (+ conditions/relatedObjects). Writes suggested: inspect (local), must-gather.
playbook_operators() {
	local question="$1"
	oc_ro get clusteroperator || true
	local table="$LAST_OUT"
	oc_ro get clusteroperator -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Available")]}{.status}{end}{"\t"}{range .status.conditions[?(@.type=="Progressing")]}{.status}{end}{"\t"}{range .status.conditions[?(@.type=="Degraded")]}{.status}{"\t"}{.reason}{"\t"}{.message}{end}{"\n"}{end}' || true
	local rows="$LAST_OUT"

	end_if_dry_run && return 0

	if ! lines_nonempty "$rows" && ! lines_nonempty "$table"; then
		finding "Could not list clusteroperators."
		print_report
		return 0
	fi

	local names=() bad=()
	local n avail prog deg reason msg
	while IFS=$'\t' read -r n avail prog deg reason msg; do
		[[ -z "${n:-}" ]] && continue
		names+=("$n")
		if [[ "$deg" == "True" || "$avail" == "False" ]]; then
			bad+=("$n")
			finding "$n Available=$avail Progressing=$prog Degraded=$deg reason=$reason"
			finding "    $msg"
		fi
	done <<<"$rows"

	if ((${#bad[@]} == 0)); then
		finding "No cluster operator is Degraded=True or Available=False."
	fi

	local target=""
	target="$(extract_operator_from_question "$question")" || true
	if [[ -z "$target" ]] && ((${#names[@]} > 0)); then
		target="$(pick_named_from_list "$question" "${names[@]}")" || true
	fi
	local inspect=()
	if [[ -n "$target" ]]; then
		inspect=("$target")
	elif ((${#bad[@]} > 0)); then
		inspect=("${bad[@]}")
	fi

	local op ndrill=0
	if ((${#inspect[@]} > 0)); then
		for op in "${inspect[@]}"; do
			[[ -z "$op" ]] && continue
			ndrill=$((ndrill + 1))
			if [[ "$ndrill" -gt "$CHECK_MAX_OPS" ]]; then
				finding "Further operators omitted; raise CHECK_MAX_OPS or: oc-ask.sh --check $op"
				break
			fi
			drill_cluster_operator "$op"
			suggest "# Full must-gather creates namespace/pods on the cluster (WRITE) — not run:"
			suggest "oc adm must-gather"
		done
	fi

	if ((${#inspect[@]} == 0)) && lines_nonempty "$table"; then
		finding "All operators look healthy in the summary table."
	fi
	print_report
}

# Reads: mcp, machine-config operator. Writes suggested: unpause patch, reboot-machine-config-pool.
playbook_mcp() {
	oc_ro get mcp || true
	local table="$LAST_OUT"
	oc_ro get machineconfigpool -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.paused}{"\t"}{.status.machineCount}{"\t"}{.status.readyMachineCount}{"\t"}{.status.updatedMachineCount}{"\t"}{.status.degradedMachineCount}{"\t"}{.status.conditions[?(@.type=="Updating")].status}{"\t"}{.status.conditions[?(@.type=="Degraded")].status}{"\t"}{.spec.configuration.name}{"\n"}{end}' || true
	local rows="$LAST_OUT"
	oc_ro get clusteroperator machine-config -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{" ("}{.reason}{") "}{end}' || true
	local mco="$LAST_OUT"

	end_if_dry_run && return 0

	if ! lines_nonempty "$rows" && ! lines_nonempty "$table"; then
		finding "Could not list MachineConfigPools (not OpenShift, no MCO, or missing RBAC)."
		print_report
		return 0
	fi

	local n paused count ready updated degraded updating degcond cfg
	while IFS=$'\t' read -r n paused count ready updated degraded updating degcond cfg; do
		[[ -z "${n:-}" ]] && continue
		finding "MCP/$n paused=${paused:-false} machines=$count ready=$ready updated=$updated degraded=$degraded Updating=$updating Degraded=$degcond configuration=$cfg"
		if [[ "$paused" == "true" ]]; then
			finding "Pool $n is paused — nodes will not receive MachineConfig updates until unpaused."
			suggest "# Unpausing is a WRITE and will start rollouts:"
			suggest "oc patch mcp $n --type=merge -p '{\"spec\":{\"paused\":false}}'"
		fi
		if [[ "$degcond" == "True" || "${degraded:-0}" != "0" && "${degraded:-0}" != "" ]]; then
			finding "Pool $n is degraded. Describe the pool and machine-config operator."
			oc_ro describe mcp "$n" || true
			suggest "# Rebooting a pool is a WRITE:"
			suggest "oc adm reboot-machine-config-pool mcp/$n"
		fi
		if [[ "$updating" == "True" ]]; then
			finding "Pool $n is Updating=True (a config rollout is in progress)."
		fi
		if [[ "${ready:-0}" != "${count:-0}" && "$updating" != "True" && "$paused" != "true" ]]; then
			finding "Pool $n readyMachineCount ($ready) != machineCount ($count) while not Updating and not paused — nodes may be stuck."
		fi
	done <<<"$rows"

	if lines_nonempty "$mco"; then
		finding "clusteroperator/machine-config: $mco"
	fi
	print_report
}

# Reads: pods -A JSON via jq (namespace + container), per-container logs. Writes suggested: namespaced delete/debug.
playbook_crashloop() {
	local rows="" json=""
	if [[ "$HAS_JQ" -eq 1 ]]; then
		oc_ro get pods -A -o json || true
		json="$LAST_OUT"
	else
		oc_ro get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .status.containerStatuses[*]}{.name}{":"}{.restartCount}{":"}{.state.waiting.reason}{":"}{.state.terminated.reason}{";"}{end}{"\n"}{end}' || true
		rows="$LAST_OUT"
	fi

	end_if_dry_run && return 0

	local hits=()
	if [[ "$HAS_JQ" -eq 1 ]]; then
		if [[ -z "$json" ]]; then
			finding "Could not list pods cluster-wide (RBAC?)."
			print_report
			return 0
		fi
		jq_eval "$jq_unhealthy_pods_cluster_query" "$json" || true
		rows="$JQ_OUT"
		local ns name phase
		while IFS=$'\t' read -r ns name phase; do
			[[ -z "${ns:-}" ]] && continue
			hits+=("$ns $name $phase")
			finding "Pod $ns/$name phase=$phase — generated: $(gen_logs_cmd "$ns" "$name")"
		done <<<"$rows"
	else
		if ! lines_nonempty "$rows"; then
			finding "Could not list pods cluster-wide (RBAC?)."
			print_report
			return 0
		fi
		local ns name phase rest
		while IFS=$'\t' read -r ns name phase rest; do
			[[ -z "${ns:-}" ]] && continue
			if [[ "$rest" == *CrashLoopBackOff* || "$rest" == *ImagePullBackOff* || "$rest" == *ErrImagePull* || "$rest" == *OOMKilled* || "$rest" == *Error* ]]; then
				hits+=("$ns $name $phase")
				finding "Pod $ns/$name phase=$phase containers=$rest"
			fi
		done <<<"$rows"
	fi

	if ((${#hits[@]} == 0)); then
		finding "No pods report CrashLoopBackOff, ImagePullBackOff, ErrImagePull, OOMKilled, or non-Running (except Succeeded)."
		print_report
		return 0
	fi

	finding "Pulling per-container logs for up to 8 failing pods (namespace is always set on generated commands)."
	local i=0 entry pns pname
	for entry in "${hits[@]}"; do
		((i++ >= 8)) && break
		pns="$(printf '%s\n' "$entry" | awk '{print $1}')"
		pname="$(printf '%s\n' "$entry" | awk '{print $2}')"
		emit_pod_container_logs "$pns" "$pname"
		suggest "# oc debug creates a copy pod (WRITE) — not run:"
		suggest "oc debug -n $pns pod/$pname"
	done
	print_report
}

# Reads: machines, machinesets, CPMS. Writes suggested: delete machine, scale machineset.
playbook_machines() {
	oc_ro get machines -n openshift-machine-api -o wide || true
	local mtable="$LAST_OUT"
	oc_ro get machinesets -n openshift-machine-api || true
	local mstable="$LAST_OUT"
	oc_ro get controlplanemachineset -n openshift-machine-api || true
	local cp="$LAST_OUT"
	oc_ro get machines -n openshift-machine-api -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.nodeRef.name}{"\t"}{.status.errorMessage}{"\t"}{.metadata.deletionTimestamp}{"\n"}{end}' || true
	local rows="$LAST_OUT"

	end_if_dry_run && return 0

	if ! lines_nonempty "$mtable" && ! lines_nonempty "$rows"; then
		finding "No Machines found in openshift-machine-api (or the API/namespace is missing)."
		print_report
		return 0
	fi

	if lines_nonempty "$mstable"; then
		finding "MachineSets:"
		while IFS= read -r line; do
			finding "    $line"
		done <<<"$mstable"
	fi
	if lines_nonempty "$cp"; then
		finding "ControlPlaneMachineSet:"
		while IFS= read -r line; do
			finding "    $line"
		done <<<"$cp"
	else
		finding "No ControlPlaneMachineSet listed."
	fi

	local n phase node err del failed=0
	while IFS=$'\t' read -r n phase node err del; do
		[[ -z "${n:-}" ]] && continue
		finding "Machine $n phase=$phase node=${node:-<none>} deletionTimestamp=${del:-<none>}"
		if is_present "$err"; then
			finding "    errorMessage: $err"
			failed=1
		fi
		if [[ "$phase" == "Failed" || "$phase" == "Deleting" ]]; then
			failed=1
			finding "    Machine $n is $phase."
		fi
	done <<<"$rows"

	if [[ "$failed" -eq 1 ]]; then
		suggest "# Deleting a Failed Machine is a WRITE; the machineset/CPMS may create a replacement:"
		suggest "oc delete machine -n openshift-machine-api <name>"
		suggest "# Scaling a MachineSet is a WRITE:"
		suggest "oc scale machineset <name> -n openshift-machine-api --replicas=<n>"
	fi
	print_report
}

# Reads: events -A type=Warning. Writes suggested: adm inspect (local dump).
playbook_events() {
	oc_ro get events -A --field-selector type=Warning || true
	local ev="$LAST_OUT"

	end_if_dry_run && return 0

	if ! lines_nonempty "$ev"; then
		finding "No Warning events returned (or listing events is forbidden / empty)."
		print_report
		return 0
	fi

	local total
	total="$(count_lines "$ev")"
	finding "Warning events listed: $total (showing last 40 lines)."
	while IFS= read -r line; do
		finding "    $line"
	done <<<"$(printf '%s\n' "$ev" | tail -n 40)"
	suggest "# Events are read-only. If you need a durable dump:"
	suggest "oc adm inspect clusteroperators,clusterversions"
	print_report
}

# Reads: whoami, clusterversion, nodes, clusteroperator, mcp, CPMS. Suggests more specific playbooks.
playbook_overview() {
	oc_ro whoami || true
	local user="$LAST_OUT"
	oc_ro get clusterversion version -o jsonpath='{.status.desired.version}{" / history0="}{.status.history[0].version}' || true
	local ver="$LAST_OUT"
	oc_ro get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\t"}{.metadata.deletionTimestamp}{"\n"}{end}' || true
	local nodes="$LAST_OUT"
	oc_ro get clusteroperator -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Degraded")]}{.status}{end}{"\t"}{range .status.conditions[?(@.type=="Available")]}{.status}{end}{"\n"}{end}' || true
	local cos="$LAST_OUT"
	oc_ro get mcp -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.paused}{"\t"}{.status.readyMachineCount}{"/"}{.status.machineCount}{"\t"}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}' || true
	local mcps="$LAST_OUT"
	oc_ro get controlplanemachineset -n openshift-machine-api -o jsonpath='{range .items[*]}{.metadata.name}{" state="}{.spec.state}{" ready="}{.status.readyReplicas}{"/"}{.spec.replicas}{end}' || true
	local cpms="$LAST_OUT"

	end_if_dry_run && return 0

	is_present "$user" && finding "User: $(trim "$user")"
	is_present "$ver" && finding "ClusterVersion desired/history0: $ver"

	local n ready del nr=0 deln=0
	while IFS=$'\t' read -r n ready del; do
		[[ -z "${n:-}" ]] && continue
		if [[ "$ready" != "True" ]]; then
			nr=$((nr + 1))
			finding "Node $n Ready=$ready"
		fi
		if is_present "$del"; then
			deln=$((deln + 1))
			finding "Node $n is deleting ($del)"
		fi
	done <<<"$nodes"
	finding "Nodes NotReady=$nr deleting=$deln"

	local deg=0 unavail=0 name d a
	while IFS=$'\t' read -r name d a; do
		[[ -z "${name:-}" ]] && continue
		[[ "$d" == "True" ]] && deg=$((deg + 1)) && finding "Operator $name is Degraded"
		[[ "$a" == "False" ]] && unavail=$((unavail + 1)) && finding "Operator $name is Available=False"
	done <<<"$cos"
	finding "ClusterOperators degraded=$deg available=False:$unavail"

	if lines_nonempty "$mcps"; then
		while IFS=$'\t' read -r name d a; do
			[[ -z "${name:-}" ]] && continue
			finding "MCP/$name paused=$d ready/count=$a"
		done <<<"$mcps"
	fi
	if is_present "$cpms"; then
		finding "CPMS: $cpms"
	else
		finding "CPMS: not found or not readable."
	fi

	if [[ "$nr" -gt 0 ]]; then
		suggest "# Dig into NotReady nodes: re-run with a more specific question, e.g."
		suggest "#   oc-ask.sh \"why is node <name> NotReady\""
	fi
	if [[ "$deln" -gt 0 ]]; then
		suggest "# Dig into deleting nodes:"
		suggest "#   oc-ask.sh \"there is a node stuck in deleting state\""
	fi
	if [[ "$deg" -gt 0 ]]; then
		suggest "# Dig into operators (or run a full walk of CO → namespace → logs):"
		suggest "#   oc-ask.sh --check"
	fi
	print_report
}

# Reads: master nodes, MCP/master, CVO, catalog COs, platform pods ON masters only.
# Walks L0 host → L1 static pods → L2 CVO → L3/L4/L5 operators → L6 MCP/CPMS.
# Ignores customer pods. Deep-dives logs only for unhealthy pods and degraded COs.
playbook_controlplane() {
	explain_controlplane_path
	print_cp_catalog_findings
	FOCUS_MASTERS=1

	# L6 machine layer is listed after L0 in the path, but MCP/CPMS explain NotReady
	# nodes, so fetch them next to ClusterVersion before diving into pods.
	oc_ro get clusterversion version -o jsonpath='desired={.status.desired.version} history0={.status.history[0].version}' || true
	finding "L2 ClusterVersion: ${LAST_OUT:-unavailable}"
	oc_ro get mcp master -o jsonpath='paused={.spec.paused} ready={.status.readyMachineCount}/{.status.machineCount} degraded={.status.degradedMachineCount}' || true
	finding "L6 MCP/master: ${LAST_OUT:-unavailable}"
	oc_ro get controlplanemachineset -n openshift-machine-api -o jsonpath='{range .items[*]}{.metadata.name}{" state="}{.spec.state}{" ready="}{.status.readyReplicas}{"/"}{.spec.replicas}{end}' || true
	if lines_nonempty "$LAST_OUT"; then
		finding "L6 CPMS: $LAST_OUT"
	fi

	load_master_nodes || true

	# L0 host via API only: Node conditions + oc adm node-logs (no SSH).
	local n ready conds
	for n in $MASTER_NODES; do
		[[ -z "$n" ]] && continue
		oc_ro get node "$n" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' || true
		ready="$LAST_OUT"
		oc_ro get node "$n" -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}); {end}' || true
		conds="$LAST_OUT"
		finding "L0 master $n Ready=${ready:-unknown} conditions: ${conds:-unavailable}"
		if [[ "$ready" != "True" ]]; then
			api_node_unit_logs "$n" kubelet || true
			api_node_unit_logs "$n" crio || true
		fi
	done

	oc_ro get pods -A -o json || true
	local podjson="$LAST_OUT"
	oc_ro get clusteroperator -o json || true
	local cojson="$LAST_OUT"

	if [[ "$DRY_RUN" -eq 1 ]]; then
		oc_ro get clusteroperator etcd -o json || true
		oc_ro get pods -n openshift-etcd -o json || true
		oc_ro get pods -n openshift-kube-apiserver -o json || true
		oc_ro adm node-logs --role master -u kubelet --tail=20 || true
		oc_ro adm node-logs --role master -u crio --tail=20 || true
	fi

	end_if_dry_run && return 0

	# Inventory: platform namespace counts on masters (not every pod name).
	if [[ "$HAS_JQ" -eq 1 && -n "$podjson" && -n "$MASTER_NODES" ]]; then
		jq_eval_masters "$jq_master_ns_counts_query" "$podjson" || true
		if lines_nonempty "$JQ_OUT"; then
			finding "Platform pods on master nodes by namespace (customer namespaces omitted):"
			local line
			while IFS= read -r line; do
				[[ -z "$line" ]] && continue
				finding "    $line"
			done <<<"$JQ_OUT"
		else
			finding "No openshift-* / kube-system pods found on master nodes (permissions or empty)."
		fi
	fi

	local drilled=" "
	local co ons opns kind what

	# L1 static pods — always (logs only if unhealthy).
	finding "L1 static-pod ClusterOperators (every master):"
	for co in etcd kube-apiserver kube-controller-manager kube-scheduler; do
		drilled+=" $co "
		drill_cluster_operator "$co"
	done

	# L2 CVO
	finding "L2 Cluster Version Operator:"
	drilled+=" cluster-version "
	drill_cluster_operator cluster-version

	# L5 OpenShift APIs + OVN control-plane — always inspect; logs only if unhealthy.
	finding "L5 OpenShift APIs and OVN control-plane on masters:"
	for co in openshift-apiserver openshift-controller-manager authentication network; do
		drilled+=" $co "
		drill_cluster_operator "$co"
	done

	# L3 remaining catalog COs: only if Degraded or Available=False.
	local bad=""
	if [[ "$HAS_JQ" -eq 1 && -n "$cojson" ]]; then
		jq_eval "$jq_bad_co_query" "$cojson" || true
		bad="$JQ_OUT"
	fi
	finding "L3 remaining catalog ClusterOperators that are Degraded/Unavailable:"
	local any_deg=0
	while IFS=$'\t' read -r co ons opns kind what; do
		[[ -z "$co" || "$co" == "cluster-version" ]] && continue
		[[ "$drilled" == *" $co "* ]] && continue
		if [[ -n "$bad" ]] && printf '%s\n' "$bad" | grep -qx "$co"; then
			any_deg=1
			finding "Catalog: $co ($kind) — $what"
			drill_cluster_operator "$co"
		fi
	done <<<"$(cp_catalog_print)"
	if [[ "$any_deg" -eq 0 ]]; then
		finding "    none of the remaining catalog operators are Degraded/Unavailable."
	fi

	# Unhealthy platform pods on masters whose namespaces were not already walked.
	if [[ "$HAS_JQ" -eq 1 && -n "$podjson" && -n "$MASTER_NODES" ]]; then
		jq_eval_masters "$jq_unhealthy_platform_on_masters_query" "$podjson" || true
		local ns pname phase node extra=0
		while IFS=$'\t' read -r ns pname phase node; do
			[[ -z "${ns:-}" ]] && continue
			if [[ "$CHECK_SEEN_NS" == *" $ns "* ]]; then
				continue
			fi
			if ! is_platform_ns "$ns"; then
				continue
			fi
			extra=$((extra + 1))
			if [[ "$extra" -gt 6 ]]; then
				finding "Further unhealthy platform pods on masters omitted."
				break
			fi
			finding "Unhealthy platform pod on a master (namespace not yet walked): $ns/$pname phase=$phase node=$node"
			emit_pod_container_logs "$ns" "$pname"
		done <<<"${JQ_OUT}"
	fi

	suggest "# Host login is out of scope (no SSH, no oc debug). This check stays on the API."
	print_report
}

# Reads: COs/nodes/MCP as JSON via jq, then related namespaces, unhealthy pods, per-container logs.
# Writes suggested: namespaced delete/debug, inspect, must-gather — never executed.
playbook_check() {
	local filter="${1-}"
	local early=""
	early="$(extract_operator_from_question "$filter")" || true
	if [[ "$early" == "cluster-version" ]]; then
		playbook_controlplane "$filter"
		return 0
	fi
	if [[ "$HAS_JQ" -eq 1 ]]; then
		finding "jq is $JQ — ClusterOperator JSON will be piped through jq to find related namespaces and containers."
	else
		finding "jq not found on PATH; --check will use jsonpath fallbacks (less precise). Install jq for the full walk."
	fi

	oc_ro get clusteroperator -o json || true
	local cojson="$LAST_OUT"
	oc_ro get nodes -o json || true
	local nodejson="$LAST_OUT"
	oc_ro get mcp -o json || true
	local mcpjson="$LAST_OUT"
	oc_ro get pods -A -o json || true
	local podjson="$LAST_OUT"
	if [[ "$DRY_RUN" -eq 1 ]]; then
		oc_ro get clusteroperator authentication -o json || true
		oc_ro get pods -n openshift-authentication-operator -o json || true
		oc_ro logs -n openshift-authentication-operator unused-pod -c unused-container --tail="$LOG_TAIL" || true
	fi

	end_if_dry_run && return 0

	local badops=() op
	if [[ "$HAS_JQ" -eq 1 && -n "$cojson" ]]; then
		jq_eval "$jq_bad_co_query" "$cojson" || true
		while IFS= read -r op; do
			[[ -z "$op" || "$op" == "null" ]] && continue
			badops+=("$op")
		done <<<"${JQ_OUT}"
	fi

	if [[ -n "$filter" ]]; then
		local target=""
		local resolved=""
		resolved="$(extract_operator_from_question "$filter")" || true
		if [[ -n "$resolved" ]]; then
			target="$resolved"
		elif ((${#badops[@]} > 0)); then
			target="$(pick_named_from_list "$filter" "${badops[@]}")" || true
		fi
		if [[ -z "$target" ]]; then
			# allow --check authentication even if the operator is not currently degraded
			target="$(trim "$filter")"
			# if filter looks like a sentence, don't use it as an operator name
			if [[ "$target" == *" "* ]]; then
				target=""
			fi
		fi
		if [[ -n "$target" ]]; then
			finding "Focusing check on clusteroperator/$target (from: $filter)"
			badops=("$target")
		fi
	fi

	if ((${#badops[@]} == 0)); then
		finding "No cluster operator is Degraded=True or Available=False."
	else
		finding "Unhealthy cluster operators: ${badops[*]}"
		local n=0
		for op in "${badops[@]}"; do
			n=$((n + 1))
			if [[ "$n" -gt "$CHECK_MAX_OPS" ]]; then
				finding "Further operators omitted (CHECK_MAX_OPS=$CHECK_MAX_OPS). Re-run: oc-ask.sh --check $op"
				break
			fi
			drill_cluster_operator "$op"
		done
	fi

	if [[ "$HAS_JQ" -eq 1 && -n "$nodejson" ]]; then
		jq_eval '.items[] | select(any(.status.conditions[]?; .type=="Ready" and .status!="True") or (.metadata.deletionTimestamp != null)) | "\(.metadata.name) Ready=\((.status.conditions[]? | select(.type=="Ready") | .status) // "?") deleting=\(.metadata.deletionTimestamp // "no")"' "$nodejson" || true
		if lines_nonempty "$JQ_OUT"; then
			finding "Problem nodes:"
			local nline
			while IFS= read -r nline; do
				[[ -z "$nline" ]] && continue
				finding "    $nline"
			done <<<"$JQ_OUT"
		else
			finding "All nodes Ready=True and none are deleting."
		fi
	fi

	if [[ "$HAS_JQ" -eq 1 && -n "$mcpjson" ]]; then
		jq_eval '.items[] | select((.spec.paused==true) or ((.status.degradedMachineCount // 0) > 0) or any(.status.conditions[]?; .type=="Degraded" and .status=="True")) | "\(.metadata.name) paused=\(.spec.paused) ready=\(.status.readyMachineCount)/\(.status.machineCount) degradedMachines=\(.status.degradedMachineCount // 0)"' "$mcpjson" || true
		if lines_nonempty "$JQ_OUT"; then
			finding "Problem MachineConfigPools:"
			local mline
			while IFS= read -r mline; do
				[[ -z "$mline" ]] && continue
				finding "    $mline"
			done <<<"$JQ_OUT"
			suggest "# Unpausing or rebooting an MCP is a WRITE — not run."
		else
			finding "No MCP is paused or degraded."
		fi
	fi

	# CrashLooping pods in namespaces the CO walk did not already visit.
	if [[ "$HAS_JQ" -eq 1 && -n "$podjson" ]]; then
		jq_eval "$jq_unhealthy_pods_cluster_query" "$podjson" || true
		local ns name phase extra=0
		while IFS=$'\t' read -r ns name phase; do
			[[ -z "${ns:-}" ]] && continue
			if [[ "$CHECK_SEEN_NS" == *" $ns "* ]]; then
				continue
			fi
			extra=$((extra + 1))
			if [[ "$extra" -gt 6 ]]; then
				finding "Further cluster-wide unhealthy pods omitted."
				break
			fi
			finding "Unhealthy pod outside already-walked operator namespaces: $ns/$name phase=$phase"
			emit_pod_container_logs "$ns" "$name"
		done <<<"${JQ_OUT}"
		if [[ "$extra" -eq 0 ]]; then
			finding "No additional unhealthy pods outside operator-related namespaces."
		fi
	fi

	suggest "# Cluster-wide must-gather creates objects on the cluster (WRITE) — not run:"
	suggest "oc adm must-gather"
	print_report
}

###############################################################################
# dispatch
###############################################################################

run_playbook() {
	local id="$1" question="$2"
	local fn="${INTENT_FN[$id]:-}"
	if [[ -z "$fn" ]]; then
		echo "Unknown intent: $id" >&2
		return 1
	fi
	echo "${C_BOLD}Intent:${C_RST} $id — ${INTENT_TITLE[$id]}"
	echo "${C_DIM}Question: $question${C_RST}"
	"$fn" "$question"
}

dispatch_question() {
	local question="$1"
	local id="${FORCE_INTENT}"
	reset_report

	if [[ -z "$id" ]]; then
		local best_id best_s second_id second_s
		IFS=$'\t' read -r best_id best_s second_id second_s <<<"$(match_intent "$question")"
		if [[ -z "$best_id" || "$best_s" -lt "$THRESHOLD" ]]; then
			echo "Could not match that question to a playbook (best score ${best_s:-0})."
			echo
			list_intents
			return 1
		fi
		if [[ -n "$second_id" && "$second_s" -ge "$THRESHOLD" && $((best_s - second_s)) -le 1 ]]; then
			echo "Ambiguous question. Closest playbooks:"
			echo "  $best_id ($best_s) — ${INTENT_TITLE[$best_id]}"
			echo "  $second_id ($second_s) — ${INTENT_TITLE[$second_id]}"
			echo
			echo "Re-run with --intent $best_id or --intent $second_id, or phrase more specifically."
			return 1
		fi
		id="$best_id"
		echo "${C_DIM}Matched $id with score $best_s${C_RST}"
	else
		if [[ -z "${INTENT_FN[$id]:-}" ]]; then
			echo "Unknown --intent $id" >&2
			list_intents
			return 1
		fi
	fi
	run_playbook "$id" "$question"
}

interactive_loop() {
	echo "oc-ask interactive (read-only). Type a question, 'list', or 'quit'."
	local line
	while true; do
		printf 'oc-ask> '
		if ! IFS= read -r line; then
			echo
			break
		fi
		line="$(trim "$line")"
		[[ -z "$line" ]] && continue
		case "${line,,}" in
		quit | exit | q)
			break
			;;
		list | help | ?)
			list_intents
			;;
		check | --check)
			reset_report
			echo "${C_BOLD}Intent:${C_RST} check — walk broken operators to pod/container logs"
			playbook_check ""
			;;
		*)
			dispatch_question "$line" || true
			;;
		esac
	done
}

###############################################################################
# --self-test (no cluster)
###############################################################################

SELFTEST_FAIL=0

assert_eq() {
	local got="$1" want="$2" msg="$3"
	if [[ "$got" != "$want" ]]; then
		echo "FAIL: $msg (got='$got' want='$want')"
		SELFTEST_FAIL=$((SELFTEST_FAIL + 1))
	else
		echo "ok: $msg"
	fi
}

assert_rc() {
	local rc="$1" want="$2" msg="$3"
	if [[ "$rc" -ne "$want" ]]; then
		echo "FAIL: $msg (rc=$rc want=$want)"
		SELFTEST_FAIL=$((SELFTEST_FAIL + 1))
	else
		echo "ok: $msg"
	fi
}

assert_match() {
	local q="$1" want="$2"
	local best_id best_s second_id second_s
	IFS=$'\t' read -r best_id best_s second_id second_s <<<"$(match_intent "$q")"
	if [[ "$best_id" != "$want" ]]; then
		echo "FAIL: match '$q' -> '$best_id' (score $best_s) want '$want'"
		SELFTEST_FAIL=$((SELFTEST_FAIL + 1))
	elif [[ "$best_s" -lt "$THRESHOLD" ]]; then
		echo "FAIL: match '$q' -> $want but score $best_s < threshold $THRESHOLD"
		SELFTEST_FAIL=$((SELFTEST_FAIL + 1))
	else
		echo "ok: match '$q' -> $want ($best_s)"
	fi
}

run_self_test() {
	echo "${C_BOLD}oc-ask self-test${C_RST}"
	echo
	echo "== intent matcher =="
	assert_match "there is a node stuck in deleting state, what is the reason" "node_deleting"
	assert_match "why is node master-1 terminating" "node_deleting"
	assert_match "node stuck deleting" "node_deleting"
	assert_match "what is the cluster version" "cluster_version"
	assert_match "what version is the cluster on" "cluster_version"
	assert_match "is there an upgrade in progress" "cluster_version"
	assert_match "is CPMS enabled" "cpms"
	assert_match "is CPMS enabled or not" "cpms"
	assert_match "is the control plane machine set active" "cpms"
	assert_match "are any operators degraded" "operators"
	assert_match "which cluster operators are failing" "operators"
	assert_match "is mcp paused" "mcp"
	assert_match "machine config pool not updating" "mcp"
	assert_match "mcp stuck" "mcp"
	assert_match "pods in CrashLoopBackOff" "crashloop"
	assert_match "why are pods restarting" "crashloop"
	assert_match "why is node X NotReady" "node_notready"
	assert_match "node is SchedulingDisabled" "node_notready"
	assert_match "machine api status" "machines"
	assert_match "show machines" "machines"
	assert_match "recent warning events" "events"
	assert_match "whoami" "whoami"
	assert_match "who am i" "whoami"
	assert_match "which cluster am i logged into" "whoami"
	assert_match "cluster health" "overview"
	assert_match "cluster overview" "overview"
	assert_match "what is wrong with the cluster" "check"
	assert_match "is anything broken" "check"
	assert_match "check the cluster" "check"
	assert_match "check this cluster operator" "check"
	assert_match "check dns issue" "check"
	assert_match "check ovn" "check"
	assert_match "check the ingress operator" "check"
	assert_match "dns operator is degraded" "check"
	assert_match "check etcd" "check"
	assert_match "check kube-apiserver" "check"
	assert_match "check masters" "controlplane"
	assert_match "check the control plane" "controlplane"
	assert_match "check control plane" "controlplane"
	assert_match "check cvo" "controlplane"
	assert_match "what is on the master nodes" "controlplane"
	assert_match "is the control plane machine set active" "cpms"

	echo
	echo "== allowlist accepts =="
	oc_ro_validate get nodes
	assert_rc $? 0 "get nodes"
	oc_ro_validate describe node foo
	assert_rc $? 0 "describe node"
	oc_ro_validate logs pod/foo --tail=10
	assert_rc $? 0 "logs"
	oc_ro_validate events -A
	assert_rc $? 0 "events"
	oc_ro_validate explain controlplanemachineset
	assert_rc $? 0 "explain"
	oc_ro_validate whoami --show-server
	assert_rc $? 0 "whoami"
	oc_ro_validate version --client
	assert_rc $? 0 "version"
	oc_ro_validate api-resources
	assert_rc $? 0 "api-resources"
	oc_ro_validate api-versions
	assert_rc $? 0 "api-versions"
	oc_ro_validate auth can-i get nodes --all-namespaces
	assert_rc $? 0 "auth can-i"
	oc_ro_validate adm upgrade
	assert_rc $? 0 "adm upgrade (status)"
	oc_ro_validate adm upgrade --include-not-recommended
	assert_rc $? 0 "adm upgrade --include-not-recommended"
	oc_ro_validate adm upgrade status --details=all
	assert_rc $? 0 "adm upgrade status"
	oc_ro_validate adm upgrade recommend
	assert_rc $? 0 "adm upgrade recommend"
	oc_ro_validate adm top nodes
	assert_rc $? 0 "adm top"
	oc_ro_validate adm node-logs master-0 -u kubelet
	assert_rc $? 0 "adm node-logs"

	echo
	echo "== allowlist rejects =="
	oc_ro_validate patch node foo --type=merge -p '{}'
	assert_rc $? 2 "patch"
	oc_ro_validate delete pod bar
	assert_rc $? 2 "delete without extra flags"
	oc_ro_validate apply -f x.yaml
	assert_rc $? 2 "apply"
	oc_ro_validate edit mcp worker
	assert_rc $? 2 "edit"
	oc_ro_validate debug node/foo
	assert_rc $? 2 "debug"
	oc_ro_validate adm must-gather
	assert_rc $? 2 "must-gather"
	oc_ro_validate adm inspect clusteroperator
	assert_rc $? 2 "inspect (not in allowlist; local dump is opt-in elsewhere)"
	oc_ro_validate adm drain foo
	assert_rc $? 2 "drain"
	oc_ro_validate adm cordon foo
	assert_rc $? 2 "cordon"
	oc_ro_validate adm upgrade --to 4.16.0
	assert_rc $? 2 "adm upgrade --to"
	oc_ro_validate adm upgrade --to-latest
	assert_rc $? 2 "adm upgrade --to-latest"
	oc_ro_validate adm upgrade --to-image registry.example.com/ocp
	assert_rc $? 2 "adm upgrade --to-image"
	oc_ro_validate get pods --force
	assert_rc $? 2 "get --force"
	oc_ro_validate exec pod/foo -- rm -rf /
	assert_rc $? 2 "exec"
	oc_ro_validate scale deploy/foo --replicas=3
	assert_rc $? 2 "scale"
	oc_ro_validate create ns cheat
	assert_rc $? 2 "create"

	echo
	echo "== jq parsing =="
	if [[ "$HAS_JQ" -eq 1 ]]; then
		jq_eval "$jq_bad_co_query" '{"items":[{"metadata":{"name":"authentication"},"status":{"conditions":[{"type":"Degraded","status":"True"}]}}]}'
		assert_eq "$(trim "$JQ_OUT")" "authentication" "jq selects degraded clusteroperator"
		jq_eval "$jq_co_namespaces_query" '{"status":{"relatedObjects":[{"resource":"namespaces","name":"openshift-apiserver"},{"resource":"deployments","name":"apiserver","namespace":"openshift-apiserver"}]}}'
		assert_eq "$(trim "$JQ_OUT")" "openshift-apiserver" "jq unique related namespaces"
		jq_eval "$jq_container_status_query" '{"status":{"containerStatuses":[{"name":"kube-apiserver","ready":false,"restartCount":12,"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}'
		assert_eq "$(trim "$JQ_OUT")" $'kube-apiserver\tCrashLoopBackOff\t12\tnot-ready' "jq container status tsv"
		assert_eq "$(gen_logs_cmd openshift-apiserver kube-apiserver kube-apiserver)" "oc logs -n openshift-apiserver kube-apiserver -c kube-apiserver --tail=$LOG_TAIL" "namespaced logs command"
		assert_eq "$(gen_delete_pod_cmd openshift-ovn-kubernetes ovnkube-node-abc)" "oc delete pod -n openshift-ovn-kubernetes ovnkube-node-abc" "namespaced delete command"
	else
		echo "skip: jq not installed"
	fi

	echo
	echo "== operator aliases =="
	assert_eq "$(extract_operator_from_question 'check dns issue')" "dns" "alias dns"
	assert_eq "$(extract_operator_from_question 'check ovn networking')" "network" "alias ovn"
	assert_eq "$(extract_operator_from_question 'check the auth operator')" "authentication" "alias auth"
	assert_eq "$(extract_operator_from_question 'ingress is broken')" "ingress" "alias ingress"
	assert_eq "$(extract_operator_from_question 'check etcd')" "etcd" "alias etcd"
	assert_eq "$(extract_operator_from_question 'check cvo')" "cluster-version" "alias cvo"
	assert_eq "$(extract_operator_from_question 'check ovnkube-control-plane')" "network" "alias ovnkube-control-plane"
	assert_eq "$(extract_operator_from_question 'check ovnkube-master')" "network" "alias ovnkube-master"
	assert_eq "$(extract_operator_from_question 'check the config-operator')" "config" "alias config-operator"
	assert_eq "$(extract_operator_from_question 'check this cluster operator')" "" "no operator named in generic check"
	assert_eq "$(cp_kind_for_co etcd)" "static" "catalog kind etcd"
	assert_eq "$(cp_kind_for_co authentication)" "cp-api" "catalog kind authentication"
	assert_eq "$(cp_kind_for_co network)" "cp-net" "catalog kind network"
	assert_eq "$(cp_kind_for_co dns)" "node-agent" "catalog kind dns"
	assert_eq "$(cp_kind_for_co cluster-version)" "operator" "catalog kind cluster-version"
	[[ "$(cp_namespaces_for_co cluster-version)" == *openshift-cluster-version* ]] || SELFTEST_FAIL=$((SELFTEST_FAIL + 1))
	echo "ok: catalog CVO ns"
	[[ "$(cp_namespaces_for_co etcd)" == *openshift-etcd* ]] || SELFTEST_FAIL=$((SELFTEST_FAIL + 1))
	echo "ok: catalog etcd operand ns"
	[[ "$(cp_namespaces_for_co kube-apiserver)" == *openshift-kube-apiserver* ]] || SELFTEST_FAIL=$((SELFTEST_FAIL + 1))
	echo "ok: catalog kube-apiserver operand ns"
	[[ "$(cp_namespaces_for_co authentication)" == *openshift-oauth-apiserver* ]] || SELFTEST_FAIL=$((SELFTEST_FAIL + 1))
	echo "ok: catalog oauth-apiserver ns"
	[[ "$(cp_namespaces_for_co network)" == *openshift-ovn-kubernetes* ]] || SELFTEST_FAIL=$((SELFTEST_FAIL + 1))
	echo "ok: catalog ovn ns"
	[[ "$(cp_namespaces_for_co config)" == *openshift-config-operator* ]] || SELFTEST_FAIL=$((SELFTEST_FAIL + 1))
	echo "ok: catalog config operator ns"

	echo
	echo "== normalize =="
	assert_eq "$(normalize_question '  What IS the Cluster-Version?? ')" "what is the cluster-version" "normalize punctuation"

	echo
	if [[ "$SELFTEST_FAIL" -eq 0 ]]; then
		echo "${C_GRN}All self-tests passed.${C_RST}"
		return 0
	fi
	echo "${C_RED}$SELFTEST_FAIL self-test(s) failed.${C_RST}"
	return 1
}

###############################################################################
# main
###############################################################################

register_all_intents

DO_LIST=0
DO_SELFTEST=0
DO_CHECK=0
ARGS=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	-l | --list)
		DO_LIST=1
		shift
		;;
	-n | --dry-run)
		DRY_RUN=1
		shift
		;;
	--self-test)
		DO_SELFTEST=1
		shift
		;;
	--check)
		DO_CHECK=1
		shift
		;;
	--oc)
		OC="${2:-}"
		shift 2
		;;
	--context)
		OC_CONTEXT="${2:-}"
		shift 2
		;;
	--intent)
		FORCE_INTENT="${2:-}"
		shift 2
		;;
	--)
		shift
		ARGS+=("$@")
		break
		;;
	-*)
		echo "Unknown flag: $1" >&2
		usage >&2
		exit 1
		;;
	*)
		ARGS+=("$1")
		shift
		;;
	esac
done

if [[ "$DO_SELFTEST" -eq 1 ]]; then
	run_self_test
	exit $?
fi

if [[ "$DO_LIST" -eq 1 ]]; then
	list_intents
	exit 0
fi

require_oc

QUESTION="$(trim "${ARGS[*]-}")"

if [[ "$DO_CHECK" -eq 1 ]]; then
	reset_report
	echo "${C_BOLD}Intent:${C_RST} check — walk broken operators to pod/container logs"
	[[ -n "$QUESTION" ]] && echo "${C_DIM}Focus: $QUESTION${C_RST}"
	playbook_check "$QUESTION"
	exit $?
fi

if [[ -z "$QUESTION" ]]; then
	if [[ -t 0 ]]; then
		interactive_loop
		exit 0
	fi
	usage >&2
	exit 1
fi

dispatch_question "$QUESTION"
