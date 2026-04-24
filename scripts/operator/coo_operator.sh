#!/bin/bash

echo 'Creating var.yaml'
rm -rf ~/.ansible
ansible all -m setup -a 'gather_subset=!all'
cd ${WORKSPACE}/ocp4-playbooks-extras 


cd playbooks/roles/ocp-cluster-logging/files/
sed -i '/Deploy app centos-logtest that generates structured data/a\  delegate_to: localhost' loggingstack.yml
sed -i '/Wait for centos-logtest- pods to come up/a\  delegate_to: localhost' loggingstack.yml
sed -i '/kubectl wait --all  --namespace=acme-air --for=condition=Ready pods --timeout=300s/a\
\
- name: Check for problematic pods\
  shell: |\
    oc get pods -n acme-air --no-headers | egrep '\''Error|CrashLoopBackOff|ImagePullBackOff|ErrImagePull'\'' | wc -l\
  register: pod_issue_count\
\
- name: Fix MongoDB image (only if real failure)\
  shell: |\
    for d in acmeair-flight-db acmeair-booking-db acmeair-customer-db; do\
      oc patch deployment $d -n acme-air --type='\''json'\'' -p='\''[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"docker.io/ibmcom/icp-mongodb-ppc64le:4.0.12"}]'\'';\
    done\
    oc rollout restart deployment acmeair-flight-db acmeair-booking-db acmeair-customer-db -n acme-air\
  when: pod_issue_count.stdout | int > 0\
\
- name: Wait for acme-air pods to be ready\
  shell: oc get pods -n acme-air --no-headers | grep -v Running | grep -v Completed | wc -l\
  register: pod_status\
  until: pod_status.stdout | int == 0\
  retries: 20\
  delay: 30\
' loggingstack.yml 

# sed -i '/Deployment of acmeair-mainservice-java pods/a\  delegate_to: localhost' loggingstack.yml
# grep -q "Wait for Loki deployments" clusterlogging.yml || \
# sed -i '/when: clo_version | float >= 6.0/a\
# \
# - name: Wait for Loki deployments\
#   shell: oc get deployment -n openshift-logging | grep lokistack | wc -l\
#   register: loki_deploy\
#   until: loki_deploy.stdout | int >= 4\
#   retries: 20\
#   delay: 30\
#   when: clo_version | float >= 5.9\
# ' clusterlogging.yml
# cat clusterlogging.yml
cat loggingstack.yml
cd ../../../..

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


# ssh -i ${WORKSPACE}/deploy/id_rsa root@${BASTION_IP} <<'EOF'
# export KUBECONFIG=openstack-upi/auth/kubeconfig 

# echo "Checking kubeconfig..."
# ls -l $KUBECONFIG

# echo "Checking cluster access..."
# oc whoami || exit 1

# echo "Removing taints..."
# oc adm taint nodes --all node-role.kubernetes.io/master- || true
# oc adm taint nodes --all node-role.kubernetes.io/control-plane- || true

# echo "Current nodes:"
# oc get nodes -o wide
# EOF


# Install dependency
python3 -m pip install --break-system-packages kubernetes openshift
python3 -c "import kubernetes; print('OK')"

ansible-galaxy collection install kubernetes.core
ansible-playbook  -i coo-inventory -e @coo_vars.yaml playbooks/ocp-coo.yml -vvv

ssh -i ${WORKSPACE}/deploy/id_rsa root@${BASTION_IP} <<'EOF'
oc get pods -n acme-air 
oc get all -n acme-air

echo "================ DEBUG START ================"

echo "==== LokiStack YAML ===="
oc get lokistack -n openshift-logging -o yaml || true

echo "==== LokiStack Describe ===="
oc describe lokistack -n openshift-logging || true

echo "==== Pods ===="
oc get pods -n openshift-logging -o wide || true

echo "==== Deployments ===="
oc get deployment -n openshift-logging || true

echo "==== Events ===="
oc get events -n openshift-logging --sort-by=.metadata.creationTimestamp | tail -50 || true

echo "==== Operator Logs ===="
oc logs deployment/cluster-logging-operator -n openshift-logging || true

echo "================ DEBUG END ================"

EOF


echo "Cluster will be kept alive for debugging..."
sleep 3600   # 1 hour