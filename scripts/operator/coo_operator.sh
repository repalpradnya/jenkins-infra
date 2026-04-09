#!/bin/bash

echo 'Creating var.yaml'
rm -rf ~/.ansible
ansible all -m setup -a 'gather_subset=!all'
cd ${WORKSPACE}/ocp4-playbooks-extras 

#added lokicred-secret  

#oc get ns openshift-logging >/dev/null 2>&1 || oc create ns openshift-logging

FILE_PATH="./playbooks/roles/ocp-cluster-logging/files/validate-urls.yml"

echo "Commenting block in $FILE_PATH"

sed -i '/# Set default value for Syslog host/,/cw_secret is undefined/s/^/#/' "$FILE_PATH"

cp examples/ocp_coo_vars.yaml coo_vars.yaml

sed -i \
-e "s|enable_logging_uiplugin:.*$|enable_logging_uiplugin: false|g" \
-e "s|enable_distributed_tracing_uiplugin:.*$|enable_distributed_tracing_uiplugin: false|g" \
-e "s|enable_troubleshootingpanel_uiplugin:.*$|enable_troubleshootingpanel_uiplugin: false|g" \
-e "s|enable_monitoring_uiplugin:.*$|enable_monitoring_uiplugin: false|g" \
-e "s|enable_perses_dashboard:.*$|enable_perses_dashboard: false|g" \
-e "s|ocp_cluster_logging:.*$|ocp_cluster_logging: false|g" \
-e "s|cluster_log_forwarder:.*$|cluster_log_forwarder: false|g" \
-e "s|coo_catalogsource_image:.*$|coo_catalogsource_image: \"${COO_CATALOGSOURCE_IMAGE}\"|" \
coo_vars.yaml

sed -i '/Include the global pull-secret update role/,/name: global-secret-update/ s/^/#/' playbooks/roles/ocp-coo/tasks/install.yaml

cat coo_vars.yaml

cp examples/inventory ./coo-inventory

sed -i "s|localhost|${BASTION_IP}|g" coo-inventory
sed -i 's/ansible_connection=local/ansible_connection=ssh/g' coo-inventory
sed -i "s|ssh|ssh ansible_ssh_private_key_file=${WORKSPACE}/deploy/id_rsa|g" coo-inventory

cat coo-inventory

#debug path exist
cd playbooks/roles/ocp-coo 
ls 
cd files
cat ImageDigestMirrorSet.yml
ls
cd ..
cd tasks
sed -i '/- name: Run ImageDigestMirrorSet/a\          delegate_to: localhost' install.yaml
sed -i '/- name: Create CatalogSource/a\          delegate_to: localhost' install.yaml
sed -i '/- name: Run CatalogSource/a\          delegate_to: localhost' install.yaml
cd ../../../..

# Install dependency
python3 -m pip install --break-system-packages kubernetes openshift

python3 -c "import kubernetes; print('OK')"
ansible-galaxy collection install kubernetes.core
ansible-playbook  -i coo-inventory -e @coo_vars.yaml playbooks/ocp-coo.yml -vvv

