#!/bin/bash

echo 'Creating var.yaml'
rm -rf ~/.ansible
ansible all -m setup -a 'gather_subset=!all'
cd ${WORKSPACE}/ocp4-playbooks-extras 


#added lokicred-secret  

oc -n openshift-logging create secret generic lokicred-secret --from-literal=endpoint=https://s3.jp-tok.cloud-object-storage.appdomain.cloud --from-literal=region=jp-tok --from-literal=bucketnames=cos-standard-upi-validation --from-literal=access_key_id=${COS_STANDARD_KEY} --from-literal=access_key_secret=${COS_STANDARD_SECRET}

#FILE_PATH="./playbooks/roles/ocp-cluster-logging/files/validate-urls.yml"

#commenting path in file
#echo "Commenting block in $FILE_PATH"

#sed -i '/# Set default value for Syslog host/,/cw_secret is undefined/s/^/#/' "$FILE_PATH"

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

cd playbooks/roles/ocp-coo/tasks 
sed -i '/- name: Run ImageDigestMirrorSet/a\          delegate_to: localhost' install.yaml
sed -i '/- name: Create CatalogSource/a\          delegate_to: localhost' install.yaml
sed -i '/- name: Run CatalogSource/a\          delegate_to: localhost' install.yaml
cat install.yaml

cd ../../../..

# Install dependency
python3 -m pip install --break-system-packages kubernetes openshift
python3 -c "import kubernetes; print('OK')"

ansible-galaxy collection install kubernetes.core

#debug for secret
oc whoami
oc config current-context
oc project
oc get secret -n openshift-logging | grep lokicred-secret
ansible-playbook  -i coo-inventory -e @coo_vars.yaml playbooks/ocp-coo.yml -vvv

