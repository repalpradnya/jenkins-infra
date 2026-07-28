#!/bin/sh
# Note: Cypress seems to need more memory to run, as it executes more and more tests. If running Docker, `--shm-size 4g` (at least) recommended.

# input parameters in input.json file
# {
#   "apiurl": "https://api.rdr-zstream-p9-3f42.redhat.com:6443",
#   "password": "<kubeadmin-password>",
#   "idp": "kube:admin",
#   "idp_user": "user1",
#   "idp_password": "keypass123",
#   "driver": "Cypress",
#   "suite": "Network_Observability",
#   "browser": "Chrome",
#   "jtimeout": 180000,
#   "retries": ""
# }

# $1=message, $2=type (2=block, 1=standout, 0=subtle=default)
function printInfo() {
  msg=$1
  type=$2
  test -z "$type" && type=0
  test $type -gt 0 && echo ""
  len=`expr 100 - ${#msg}`
  echo -n "INFO: $msg "
  cnt=0
  rch="."
  test $type -gt 0 && rch="~"
  test $type -gt 1 && rch="="
  while [ $cnt -lt $len ]; do
    echo -n $rch
    cnt=`expr $cnt + 1`
  done
  echo ""
  test $type -gt 0 && echo ""
}

# $1=(optional) test suite name to run
function run_cypress_tests() {
  local RC=0
  local PLUGINDIR="/root/netobserv-web-console"

  cd "$PLUGINDIR/web"

  # Install dependencies if needed
  if [ ! -d node_modules ]; then
    npm install
  fi

  if [ "$1" == 'e2e' -o -z "$1" ]; then
    printInfo "Starting all NETobserv Cypress tests" 1
    NO_COLOR=1 npm run cypress:run 2>&1 | tee "$HOSTDIR/${SUITE2RUN}-${NOW}.txt"
  else
    printInfo "Starting NETobserv Cypress for spec '$1'" 1
    NO_COLOR=1 npx cypress run --spec "cypress/e2e/**/${1}*" 2>&1 | tee "$HOSTDIR/${SUITE2RUN}-${NOW}.txt"
  fi
  test $? -eq 0 || RC=1

  local RUN=1
  if [ $RC -ne 0 -a $RETRYMAX -ne 0 ]; then
    while [ $RC -ne 0 -a $RUN -le $RETRYMAX ]; do
      rerun_cypress_tests $(date +%s) $RUN
      test $? -eq 0 && RC=0 || RUN=`expr $RUN + 1`
    done
  fi
  test $RC -eq 0 && echo "INFO: Cypress tests passed!!" || echo "WARNING: Cypress tests failed :-("
  report_cypress_rerun
  return $RC
}

# $1=epoch (just to be unique across runs inside the same container), $2=next run#
function rerun_cypress_tests() {
  local PLUGINDIR="/root/netobserv-web-console/web"
  mkdir -p "$OUTDIR/cypress-$1"
  mv "$OUTDIR/cypress" "$OUTDIR"/cypress_report*.json "$OUTDIR/cypress-$1" 2>/dev/null || true
  FAILED_SPECS=`mktemp`
  jq -r '.results[] | {file: .file, test: {title: (.suites[0].tests[]          | .title), result: (.suites[0].tests[]          | .state)}} | select(.test.result|test("^fail")) | .file' "$OUTDIR/cypress-$1"/*.json >  $FAILED_SPECS 2>/dev/null || true
  jq -r '.results[] | {file: .file, test: {title: (.suites[0].suites[].tests[] | .title), result: (.suites[0].suites[].tests[] | .state)}} | select(.test.result|test("^fail")) | .file' "$OUTDIR/cypress-$1"/*.json >> $FAILED_SPECS 2>/dev/null || true
  local RC=0
  for SPEC in $(cat $FAILED_SPECS | sort | uniq); do
    printInfo "Starting Cypress rerun for $SPEC (#$2)" 1
    cd "$PLUGINDIR" && NO_COLOR=1 npx cypress run --spec "$SPEC" 2>&1 | tee "$HOSTDIR/$(basename $SPEC .cy.ts)-${RC}-${NOW}.txt"
    CYRC=$?
    test $CYRC -eq 0 && echo "INFO: Cypress rerun for $SPEC passed!! :-)" || echo "WARNING: Cypress rerun for $SPEC failed :-("
    test $CYRC -ne 0 && RC=1
  done
  rm -f $FAILED_SPECS
  return $RC
}

function report_cypress_rerun() {
  printInfo "Failed Cypress Suite(s)" 2
  VERDICT_C=0
  SUITES=`mktemp`
  jq -r '.results[0].suites[0].title' $OUTDIR/cypress_report*.json | egrep -v 'null|Skipping' | sort | uniq > $SUITES
  while read SUITE; do
    grep -h testsuite $OUTDIR/junit_cypress-*.xml | egrep -v 'Root Suite|/testsuite|Mocha Tests' | sort | grep "$SUITE" | tail -1 | grep -v 'failures="0"'
    VERDICT_C=`expr $VERDICT_C + $?`
  done < $SUITES
  rm -f $SUITES
  printInfo " " 2
}

# ------------------- Not required ---------------
function adjust_for_dvt() {
  printInfo "Trimming for DVT..."
  SUITE2RUN=dashboards #NEEDSATTN
  CYDIR=frontend/packages/integration-tests-cypress
  mv $CYDIR/cypress.json $CYDIR/cypress.json~ ; jq '.video=false' $CYDIR/cypress.json~ > $CYDIR/cypress.json
  mv $CYDIR/tests/crud/annotations.spec.ts \
     $CYDIR/tests/i18n/* \
     /tmp/
}

HOSTDIR=/host #NEEDSATTN
[ -f /input.json ] && PARAMSJ=/input.json || PARAMSJ=$HOSTDIR/input.json
jq '. | del(.password)' $PARAMSJ

OAPIURL=$(jq -r .apiurl $PARAMSJ)
if [ -z "$OAPIURL" ]; then
  printInfo "ERROR: no OpenShift cluster URL provided -- aborting..."
  exit 1
fi

OCADMPW=$(jq -r .password $PARAMSJ)
if [ -z "$OCADMPW" ]; then
  printInfo "ERROR: no kubeadmin password  provided -- aborting..."
  exit 2
else
  export BRIDGE_KUBEADMIN_PASSWORD=$OCADMPW
fi

# Check for IDP user other than kubeadmin
if [ -z $(jq -r .idp $PARAMSJ) ]; then
  printInfo "WARNING: IDP not found in the input parameters, using default kubeadmin."
  export CYPRESS_LOGIN_IDP="kube:admin"
  export CYPRESS_LOGIN_USERS="kubeadmin:${OCADMPW}"
elif [ -n "$(jq -r .idp_user $PARAMSJ)" ] && [ -n "$(jq -r .idp_password $PARAMSJ)" ]; then
  export CYPRESS_LOGIN_IDP=$(jq -r .idp $PARAMSJ)
  export CYPRESS_LOGIN_USERS=$(jq -r .idp_user $PARAMSJ)":"$(jq -r .idp_password $PARAMSJ)
  printInfo "Configured $(jq -r .idp $PARAMSJ) IDP for multi-user auth test"
fi

# Check if kubeconfig is on the path $HOSTDIR/kubeconfig
if [ -e $HOSTDIR/kubeconfig ]; then
  export KUBECONFIG=$HOSTDIR/kubeconfig
  export CYPRESS_KUBECONFIG_PATH=$HOSTDIR/kubeconfig
else
  printInfo "ERROR: No kubeconfig provided -- aborting...."
  exit 1
fi

NOW=$(date +%Y%m%d-%H%M)
PLUGINDIR=/root/netobserv-web-console

# Login to the cluster
oc login -u kubeadmin -p "$OCADMPW" "$OAPIURL" --insecure-skip-tls-verify

CONSOLE_URL=$(oc get consoles.config.openshift.io cluster -o jsonpath='{.status.consoleURL}')

# Set Cypress env vars required by the NETobserv plugin's cypress.config.ts
export IS_OPENSHIFT="true"
export CYPRESS_BASE_URL="${CONSOLE_URL}"
export CYPRESS_LOGIN_USERS="${OCADMPW}"
if [ -n "$(jq -r '.idp_user // empty' $PARAMSJ)" ] && [ -n "$(jq -r '.idp_password // empty' $PARAMSJ)" ]; then
  export CYPRESS_LOGIN_IDP=$(jq -r .idp $PARAMSJ)
  export CYPRESS_LOGIN_USERS="$(jq -r .idp_user $PARAMSJ):$(jq -r .idp_password $PARAMSJ)"
fi

SUITE2RUN=$(jq -r .suite $PARAMSJ)
[ -z "$SUITE2RUN" -o "$SUITE2RUN" == "null" ] && SUITE2RUN="Network_Observability"

RETRYMAX=$(jq -r .retries $PARAMSJ)
[ -z "$RETRYMAX" -o "$RETRYMAX" == "null" ] && RETRYMAX=2

DRIVER=$(jq -r .driver $PARAMSJ)

OUTDIR="${PLUGINDIR}/web/gui_test_screenshots"
VERDICT_P=0 # Protractor not used
VERDICT_C=1 # did Cypress tests pass(=0) after all?

echo ""
printInfo "Kicking off NETobserv Cypress test suite: $SUITE2RUN" 1
run_cypress_tests "$SUITE2RUN"
VERDICT_C=$?

echo ""
if [ -w "$HOSTDIR" ]; then
  cp -r "$OUTDIR" "$HOSTDIR/out-$NOW" 2>/dev/null || true
  printInfo "Copied output to directory: out-$NOW"
else
  echo "WARN: $HOSTDIR not writeable, unable to copy output..."
fi

exit $VERDICT_C