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

section "Rerunning e2e output"
# Build failed-e2e-results.txt from the "Blocking test failures" block of
# openshift-cmd-out-log-0.txt (one quoted test name per line, no leading
# whitespace), then rerun only those tests and print the output.
ssh -o StrictHostKeyChecking=no \
    -i ${WORKSPACE}/deploy/id_rsa \
    root@${BASTION_IP} 'bash -s' <<'REMOTE_EOF' 2>&1 || echo "Rerun of failed e2e tests could not be completed on bastion"
cd /tmp/openshift_ws/src/github.com/openshift/origin/ || exit 1

awk '
    /Blocking test failures:/ { in_block = 1; next }
    in_block && /^[[:space:]]*\*/ {
        sub(/^[[:space:]]*\*[[:space:]]*/, "")
        sub(/[[:space:]]+$/, "")
        print "\"" $0 "\""
        next
    }
    in_block && !/^[[:space:]]*$/ { in_block = 0 }
' /root/e2e_tests_results/openshift-cmd-out-log-0.txt > failed-e2e-results.txt

if [ ! -s failed-e2e-results.txt ]; then
    echo "No blocking test failures found in openshift-cmd-out-log-0.txt, nothing to rerun"
    exit 0
fi

echo "Tests to rerun:"
cat failed-e2e-results.txt
echo ""

export PATH=/usr/local/go/bin:$PATH
export PATH=/usr/bin:$PATH
export KUBECONFIG=/root/.kube/config
export KUBE_TEST_REPO_LIST=/tmp/kube-test-repo-list

oc adm cordon node/worker-0
./openshift-tests run -f ./failed-e2e-results.txt -o output.txt

echo ""
echo "----- output.txt -----"
cat output.txt
REMOTE_EOF


echo ""
echo "$SEPARATOR"
echo "  Collection complete"
echo "$SEPARATOR"
echo ""