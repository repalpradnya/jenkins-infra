#!/bin/bash

echo 'Creating var.yaml'
rm -rf ~/.ansible
ansible all -m setup -a 'gather_subset=!all'
cd ${WORKSPACE}/ocp4-playbooks-extras 

cp examples/ocp_coo_vars.yaml coo_vars.yaml

sed -i \
-e "s|enable_logging_uiplugin:.*$|enable_logging_uiplugin: true|g" \
-e "s|enable_distributed_tracing_uiplugin:.*$|enable_distributed_tracing_uiplugin: true|g" \
-e "s|enable_troubleshootingpanel_uiplugin:.*$|enable_troubleshootingpanel_uiplugin: true|g" \
-e "s|enable_monitoring_uiplugin:.*$|enable_monitoring_uiplugin: true|g" \
-e "s|enable_perses_dashboard:.*$|enable_perses_dashboard: true|g" \
-e "s|coo_catalogsource_image:.*$|coo_catalogsource_image: \"${COO_CATALOGSOURCE_IMAGE}\"|" \
-e "s|coo_enable_global_secret :.*$|coo_enable_global_secret: false|g" \
coo_vars.yaml

cat coo_vars.yaml

cp examples/inventory ./coo-inventory

sed -i "s|localhost|${BASTION_IP}|g" coo-inventory
sed -i 's/ansible_connection=local/ansible_connection=ssh/g' coo-inventory
sed -i "s|ssh|ssh ansible_ssh_private_key_file=${WORKSPACE}/deploy/id_rsa|g" coo-inventory
cat coo-inventory

ssh -i ${WORKSPACE}/deploy/id_rsa root@${BASTION_IP} <<EOF
oc get ns openshift-logging >/dev/null 2>&1 || oc create ns openshift-logging

oc create secret generic lokicred-secret \
  --from-literal=endpoint=https://s3.jp-tok.cloud-object-storage.appdomain.cloud \
  --from-literal=region=jp-tok \
  --from-literal=bucketnames=cos-standard-upi-validation \
  --from-literal=access_key_id=${COS_STANDARD_KEY} \
  --from-literal=access_key_secret=${COS_STANDARD_SECRET} \
  -n openshift-logging \
  --dry-run=client -o yaml | oc apply -f -
EOF


cd playbooks/roles/ocp-coo/tasks 
sed -i '/- name: Run ImageDigestMirrorSet/a\          delegate_to: localhost' install.yaml
sed -i '/- name: Create CatalogSource/a\          delegate_to: localhost' install.yaml
sed -i '/- name: Run CatalogSource/a\          delegate_to: localhost' install.yaml
cat install.yaml

cd ../../../..


ssh -i id_rsa root@<bastion_ip> <<EOF
export KUBECONFIG=/root/auth/kubeconfig

echo "Checking cluster access..."
oc whoami || exit 1

echo "Removing taints..."
oc adm taint nodes --all node-role.kubernetes.io/master- || true
oc adm taint nodes --all node-role.kubernetes.io/control-plane- || true

echo "Current nodes:"
oc get nodes -o wide
EOF
# Install dependency
python3 -m pip install --break-system-packages kubernetes openshift
python3 -c "import kubernetes; print('OK')"

ansible-galaxy collection install kubernetes.core
ansible-playbook  -i coo-inventory -e @coo_vars.yaml playbooks/ocp-coo.yml -vvv

