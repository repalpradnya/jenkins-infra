#!/bin/bash
# cron_cluster_health.sh
# Captures general OpenShift cluster health and version information.

set -uo pipefail

export TZ='Asia/Kolkata'

SEPARATOR="================================================================"

section() {
    echo ""
    echo "$SEPARATOR"
    echo "  $1"
    echo "$SEPARATOR"
    echo ""
}

section "oc version"
oc version

section "kubectl version"
kubectl version

section "oc get nodes"
oc get nodes

section "oc adm top nodes"
oc adm top nodes

section "oc get clusteroperators"
oc get co

section "Pods not Running or Completed"
oc get pods -A | grep -v "Running\|Completed" || echo "All pods are Running or Completed"

section "Cluster Version History"
oc get clusterversion -o json | jq '.items[0].status.history'

section "Bastion OS Release"
if [ -n "${BASTION_IP:-}" ] && [ -f "${WORKSPACE}/deploy/id_rsa" ]; then
    ssh -o StrictHostKeyChecking=no \
        -i ${WORKSPACE}/deploy/id_rsa \
        root@${BASTION_IP} \
        "cat /etc/os-release" 2>/dev/null || echo "Failed to retrieve OS release from bastion"
else
    echo "Bastion not found: BASTION_IP or id_rsa key is missing"
fi

section "Master-0 RHCOS Release"
oc debug node/master-0 -- chroot /host cat /etc/os-release

section "Worker-0 RHCOS Release"
oc debug node/worker-0 -- chroot /host cat /etc/os-release

section "E2E Test Summary"

echo ""
echo "Directory:"
ssh -o StrictHostKeyChecking=no \
    -i ${WORKSPACE}/deploy/id_rsa \
    root@${BASTION_IP} \
    "ls -lh /root/e2e_tests_results/" 2>/dev/null \
    || echo "e2e_tests_results not found on bastion"

section "summary.txt"
ssh -o StrictHostKeyChecking=no \
    -i ${WORKSPACE}/deploy/id_rsa \
    root@${BASTION_IP} \
    "cat /root/e2e_tests_results/summary.txt" 2>/dev/null \
    || echo "summary.txt not found on bastion"

section "failed-e2e-results.txt"
ssh -o StrictHostKeyChecking=no \
    -i ${WORKSPACE}/deploy/id_rsa \
    root@${BASTION_IP} \
    "cat /root/e2e_tests_results/failed-e2e-results.txt" 2>/dev/null \
    || echo "failed-e2e-results.txt not found on bastion"


section "Blocking test failures (latest openshift-cmd-out-log-N.txt)"
# summary.txt and failed-e2e-results.txt can be empty, so read the result
# straight from the e2e log. The log is named openshift-cmd-out-log-<N>.txt
# (N = 0, 1, 2, 3, ...); use the highest N and print everything from the last
# "Blocking test failures:" / "Failing tests:" header to the end of the file
# (includes the "N blocking fail, N informing fail, N pass ..." last line).
ssh -o StrictHostKeyChecking=no \
    -i ${WORKSPACE}/deploy/id_rsa \
    root@${BASTION_IP} 'bash -s' <<'REMOTE_EOF' 2>&1 || echo "Could not read openshift-cmd-out-log-N.txt on bastion"
LOG=$(ls /root/e2e_tests_results/openshift-cmd-out-log-*.txt 2>/dev/null | sort -V | tail -n 1)
if [ -z "$LOG" ]; then
    echo "openshift-cmd-out-log-N.txt not found on bastion"
    exit 0
fi
echo "Source: $LOG"
echo ""

START=$(grep -nE '^[[:space:]]*(Blocking test failures|Failing tests):[[:space:]]*$' "$LOG" | tail -n 1 | cut -d: -f1)

if [ -n "$START" ]; then
    tail -n +"$START" "$LOG"
else
    echo "No blocking test failures or failed tests found in $(basename "$LOG")"
fi
REMOTE_EOF

section "Rerunning e2e output"
# Build failed-e2e-results.txt from the "Blocking test failures:" or
# "Failing tests:" section of the latest openshift-cmd-out-log-N.txt (one quoted
# test name per line, no leading whitespace, duplicates removed), then rerun
# only those tests. The full openshift-tests output is kept on the bastion
# (rerun-console.txt / output.txt); only the part from the last
# "Blocking test failures:" / "Failing tests:" header to the end of the rerun
# output is printed here.
ssh -o StrictHostKeyChecking=no \
    -i ${WORKSPACE}/deploy/id_rsa \
    root@${BASTION_IP} 'bash -s' <<'REMOTE_EOF' 2>&1 || echo "Rerun of failed e2e tests could not be completed on bastion"
cd /tmp/openshift_ws/src/github.com/openshift/origin/ || exit 1

LOG=$(ls /root/e2e_tests_results/openshift-cmd-out-log-*.txt 2>/dev/null | sort -V | tail -n 1)
if [ -z "$LOG" ]; then
    echo "openshift-cmd-out-log-N.txt not found on bastion, nothing to rerun"
    exit 0
fi

awk '
    /^[[:space:]]*(Blocking test failures|Failing tests):[[:space:]]*$/ { in_block = 1; found = 0; next }
    in_block && /^[[:space:]]*$/ {
        if (found) in_block = 0
        next
    }
    in_block {
        sub(/^[[:space:]]*\*[[:space:]]*/, "")
        sub(/^[[:space:]]+/, "")
        sub(/[[:space:]]+$/, "")
        found = 1
        if (!seen[$0]++) print "\"" $0 "\""
    }
' "$LOG" > failed-e2e-results.txt

if [ ! -s failed-e2e-results.txt ]; then
    echo "No blocking/failing tests found in $(basename "$LOG"), nothing to rerun"
    exit 0
fi

echo "Tests to rerun (from $(basename "$LOG")):"
cat failed-e2e-results.txt
echo ""

export PATH=/usr/local/go/bin:$PATH
export PATH=/usr/bin:$PATH
export KUBECONFIG=/root/.kube/config
export KUBE_TEST_REPO_LIST=/tmp/kube-test-repo-list

oc adm cordon node/worker-0 >/dev/null
./openshift-tests run -f ./failed-e2e-results.txt -o output.txt > rerun-console.txt 2>&1

echo "Rerun result (from Blocking test failures to end of output):"
extract_blocking() {
    start=$(grep -nE '^[[:space:]]*(Blocking test failures|Failing tests):[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | cut -d: -f1)
    [ -n "$start" ] && tail -n +"$start" "$1"
}
extract_blocking rerun-console.txt > rerun-failures.txt
[ -s rerun-failures.txt ] || extract_blocking output.txt > rerun-failures.txt

if [ -s rerun-failures.txt ]; then
    cat rerun-failures.txt
else
    echo "No blocking test failures or failed tests in the rerun. Last lines of output:"
    tail -n 3 rerun-console.txt
fi
REMOTE_EOF


echo ""
echo "$SEPARATOR"
echo "  Collection complete"
echo "$SEPARATOR"
echo ""