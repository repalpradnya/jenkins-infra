#!/bin/bash
set -euo pipefail

# Setup and run NETobserv console plugin Cypress e2e tests
NETOBSERV_PLUGIN_REPO="https://github.com/netobserv/netobserv-web-console.git"
HOSTDIR=/host
PLUGINDIR=/root/netobserv-web-console

# Create /host directory if it does not exist
if [ ! -d "$HOSTDIR" ]; then
  mkdir "$HOSTDIR"
fi

# ── Step 1: Clone the NETobserv console plugin repo ──────────────────────────
echo "Step-1: Cloning network-observability-console-plugin repository"
echo ""
cd /root
if [ -d "$PLUGINDIR" ]; then
  echo "Plugin directory already exists, pulling latest..."
  cd "$PLUGINDIR" && git pull
else
  git clone "$NETOBSERV_PLUGIN_REPO"
  cd "$PLUGINDIR"
fi

# ── Step 2: Extract cluster credentials ──────────────────────────────────────
echo "Step-2: Setting the input params for running the console UI e2e tests"
echo ""

APIURL=$(oc whoami --show-server)
echo "Cluster server URL: ${APIURL}"
echo ""

# Fetch kubeadmin password from bastion
scp -i "${WORKSPACE}/deploy/id_rsa" -o StrictHostKeyChecking=no \
    root@"${BASTION_IP}":/root/openstack-upi/auth/kubeadmin-password ~/.kube
KUBEADPASSWD=$(cat ~/.kube/kubeadmin-password)

# Copy kubeconfig to shared /host path
scp -i "${WORKSPACE}/deploy/id_rsa" -o StrictHostKeyChecking=no \
    root@"${BASTION_IP}":/root/openstack-upi/auth/kubeconfig "$HOSTDIR"
export KUBECONFIG="$HOSTDIR/kubeconfig"

# ── Step 3: Create htpasswd IDP user for multi-user auth test ─────────────────
IDP_NAME="htpasswd_identity_provider"
HTPASS_USER="user01"
HTPASS_PASSWD="${HTPASS_PASSWD:-keypass123}"

ansible-galaxy collection install community.general
echo "Setting up htpasswd IDP..."
cd /root
git clone https://github.com/ocp-power-automation/ocp4-playbooks-extras || true
cd ocp4-playbooks-extras
cp examples/inventory inventory
sed -i "s|localhost|${BASTION_IP}|g" inventory
sed -i 's/ansible_connection=local/ansible_connection=ssh/g' inventory
sed -i "s|ssh|ssh ansible_ssh_private_key_file=${WORKSPACE}/deploy/id_rsa|g" inventory
cp examples/all.yaml .
sed -i 's/htpasswd_identity_provider: false/htpasswd_identity_provider: true/g' all.yaml
sed -i 's/htpasswd_username: ""/htpasswd_username: '"${HTPASS_USER}"'/g' all.yaml
sed -i 's/htpasswd_password: ""/htpasswd_password: '"${HTPASS_PASSWD}"'/g' all.yaml
sed -i 's/htpasswd_user_role: ""/htpasswd_user_role: "self-provisioner"/g' all.yaml
# Run only the htpasswd playbook — avoids unrelated role errors in main.yml
ansible-playbook -i inventory -e @all.yaml playbooks/ocp-htpasswd-identity-provider.yml
if [ $? -ne 0 ]; then
  echo "Error creating htpasswd IDP user. Exiting..."
  exit 1
fi

# ── Step 4: Add cluster routes to /etc/hosts ──────────────────────────────────
echo "Step-4: Adding cluster host entries to /etc/hosts..."
OCP_ROUTES=$(oc get routes -A --no-headers | awk '{ print $2 }')
echo "${BASTION_IP} ${OCP_ROUTES}" | tee -a /etc/hosts

# ── Step 5: Write input.json for reference/archiving ─────────────────────────
CONSOLE_URL=$(oc get consoles.config.openshift.io cluster -o jsonpath='{.status.consoleURL}')

# Apply defaults for variables that may not be set in all environments
SUITE2RUN="${SUITE2RUN:-Network_Observability}"
RETRIES="${RETRIES:-2}"
OCP_RELEASE="${OCP_RELEASE:-}"

# Cypress logs in as kubeadmin (kube:admin IDP) — the htpasswd user01 is only used by
# multi-user RBAC tests that call 'oc adm policy add-cluster-role-to-user' at runtime.
cat > "$HOSTDIR/input.json" <<EOF
{
  "apiurl": "${APIURL}",
  "console_url": "${CONSOLE_URL}",
  "idp": "kube:admin",
  "idp_user": "kubeadmin",
  "idp_password": "${KUBEADPASSWD}",
  "driver": "Cypress",
  "suite": "${SUITE2RUN}",
  "browser": "electron",
  "jtimeout": 180000,
  "retries": "${RETRIES}",
  "ocp_version": "${OCP_RELEASE}"
}
EOF
echo "input.json written to $HOSTDIR/input.json"
echo ""

# ── Step 6: Run NETobserv Cypress e2e tests ───────────────────────────────────
echo "Step-6: Running NETobserv Cypress e2e tests via frontend.sh..."
# Export kubeadmin password under the name frontend.sh expects
export OCADMPW="${KUBEADPASSWD}"
source "${WORKSPACE}/scripts/netobserv/frontend.sh"
