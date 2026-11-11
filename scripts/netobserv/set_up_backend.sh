#!/bin/bash
set -euo pipefail

# Setup and run NETobserv operator backend (Ginkgo) e2e tests -- backend counterpart of set_up.sh
HOSTDIR=/host

[ -d "$HOSTDIR" ] || mkdir "$HOSTDIR"

echo "Step-1: Fetching cluster credentials from the bastion"
echo ""

# Copy kubeconfig to shared /host path
scp -i "${WORKSPACE}/deploy/id_rsa" -o StrictHostKeyChecking=no \
    root@"${BASTION_IP}":/root/openstack-upi/auth/kubeconfig "$HOSTDIR"
export KUBECONFIG="$HOSTDIR/kubeconfig"

# kubeadmin password (suite reads QE_KUBEADMIN_PASSWORD)
mkdir -p ~/.kube
scp -i "${WORKSPACE}/deploy/id_rsa" -o StrictHostKeyChecking=no \
    root@"${BASTION_IP}":/root/openstack-upi/auth/kubeadmin-password ~/.kube
export QE_KUBEADMIN_PASSWORD=$(cat ~/.kube/kubeadmin-password)

echo "Step-2: Adding cluster host entries to /etc/hosts..."
OCP_ROUTES=$(oc get routes -A --no-headers | awk '{ print $2 }')
echo "${BASTION_IP} ${OCP_ROUTES}" | tee -a /etc/hosts

echo "Step-3: Running NETobserv backend tests via backend.sh..."
# Catalog image: comes from the pipeline env (MULTISTAGE_PARAM_OVERRIDE_NETOBSERV_CS_IMAGE);
# backend.sh defaults to catalog-zstream:latest if unset.
# Optional: GINKGO_FOCUS, NETOBSERV_OPERATOR_BRANCH.
# backend.sh always ends with `exit 0` so failures show in artifacts but the build stays GREEN.
bash "${WORKSPACE}/scripts/netobserv/backend.sh" || true
