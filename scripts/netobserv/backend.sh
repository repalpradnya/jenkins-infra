#!/bin/bash
# Run the NetObserv operator backend (Ginkgo) e2e tests against an existing OCP cluster.
# Automates: netobserv-operator-backend-test-runbook
#
# What the test suite (BeforeSuite) already does by itself, so it is NOT done here:
#   - creates the openshift-netobserv-operator namespace
#   - creates the CatalogSource "netobserv-konflux-fbc" using $MULTISTAGE_PARAM_OVERRIDE_NETOBSERV_CS_IMAGE
#   - applies testdata/subscription/image-digest-mirror-set.yaml (IDMS)
#   - creates OperatorGroup + Subscription
# What it does NOT do, and this script therefore does:
#   - apply the ImageContentSourcePolicy (brew-registry)  -> manifests/icsp.yaml
#   - (optionally) pre-apply the IDMS and wait for the MachineConfigPools, so the suite does not
#     start while nodes are still rolling out the mirror config
#
# Inputs (environment variables):
#   KUBECONFIG                                   kubeconfig of the cluster (default /host/kubeconfig)
#   QE_KUBEADMIN_PASSWORD | OCADMPW              kubeadmin password (required by the suite)
#   MULTISTAGE_PARAM_OVERRIDE_NETOBSERV_CS_IMAGE catalog image (default: catalog-zstream:latest)
#   NETOBSERV_OPERATOR_BRANCH                    branch of netobserv-operator to test (default: repo default)
#   GINKGO_FOCUS                                 optional --focus string for a specific test
#   GINKGO_TIMEOUT                               ginkgo --timeout (default 8h)
#   APPLY_ICSP                                   true|false (default true)
#   MCP_WAIT_TIMEOUT                             seconds to wait for MCP rollout (default 3600)

HOSTDIR=${HOSTDIR:-/host}
WORKDIR=${WORKDIR:-/root}
REPO_URL="https://github.com/netobserv/netobserv-operator.git"
REPODIR="${WORKDIR}/netobserv-operator"
BACKENDDIR="${REPODIR}/integration-tests/backend"
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOW=$(date +%Y%m%d-%H%M)

APPLY_ICSP="${APPLY_ICSP:-true}"
MCP_WAIT_TIMEOUT="${MCP_WAIT_TIMEOUT:-3600}"
GINKGO_TIMEOUT="${GINKGO_TIMEOUT:-8h}"

printInfo() { echo ""; echo "INFO: $1 ......"; echo ""; }

# ── Cluster access ───────────────────────────────────────────────────────────
export KUBECONFIG="${KUBECONFIG:-$HOSTDIR/kubeconfig}"
if [ ! -e "$KUBECONFIG" ]; then
  echo "ERROR: kubeconfig '$KUBECONFIG' not found -- aborting..."
  exit 1
fi

export QE_KUBEADMIN_PASSWORD="${QE_KUBEADMIN_PASSWORD:-${OCADMPW:-}}"
if [ -z "$QE_KUBEADMIN_PASSWORD" ] && [ -f "$HOME/.kube/kubeadmin-password" ]; then
  export QE_KUBEADMIN_PASSWORD=$(cat "$HOME/.kube/kubeadmin-password")
fi
if [ -z "$QE_KUBEADMIN_PASSWORD" ]; then
  echo "ERROR: no kubeadmin password (QE_KUBEADMIN_PASSWORD / OCADMPW) -- aborting..."
  exit 2
fi

export MULTISTAGE_PARAM_OVERRIDE_NETOBSERV_CS_IMAGE="${MULTISTAGE_PARAM_OVERRIDE_NETOBSERV_CS_IMAGE:-quay.io/redhat-user-workloads/ocp-network-observab-tenant/catalog-zstream:latest}"

oc whoami --show-server || { echo "ERROR: cannot talk to the cluster with $KUBECONFIG -- aborting..."; exit 3; }

# ── Step 1-2: ICSP (+ IDMS) prerequisites ────────────────────────────────────
wait_for_mcp() {
  printInfo "Waiting for MachineConfigPools to finish updating (timeout ${MCP_WAIT_TIMEOUT}s)"
  sleep 60   # give the MCO time to notice the change and flip to Updating
  oc wait mcp --all --for=condition=Updated=True --timeout="${MCP_WAIT_TIMEOUT}s" \
    || echo "WARNING: MachineConfigPools not Updated within ${MCP_WAIT_TIMEOUT}s, continuing..."
}

apply_mirror_config() {
  local changed=0 out

  if [ "$APPLY_ICSP" = "true" ]; then
    printInfo "Applying ImageContentSourcePolicy (brew-registry)"
    out=$(oc apply -f "$SCRIPTDIR/manifests/icsp.yaml") || { echo "ERROR: ICSP apply failed"; return 1; }
    echo "$out"
    echo "$out" | grep -qE 'created|configured' && changed=1
  fi

  # Same file the suite applies itself; applying early lets us wait for the rollout before testing.
  printInfo "Applying ImageDigestMirrorSet from the operator repo"
  out=$(oc apply -f "$BACKENDDIR/testdata/subscription/image-digest-mirror-set.yaml") || { echo "ERROR: IDMS apply failed"; return 1; }
  echo "$out"
  echo "$out" | grep -qE 'created|configured' && changed=1

  [ $changed -eq 1 ] && wait_for_mcp
  return 0
}

# ── Step 4: clone the repo ───────────────────────────────────────────────────
printInfo "Cloning netobserv-operator"
if [ ! -d "$REPODIR/.git" ]; then
  git clone "$REPO_URL" "$REPODIR" || exit 4
fi
git -C "$REPODIR" fetch origin || exit 4
if [ -n "${NETOBSERV_OPERATOR_BRANCH:-}" ]; then
  git -C "$REPODIR" checkout "$NETOBSERV_OPERATOR_BRANCH" || exit 4
  git -C "$REPODIR" pull --ff-only origin "$NETOBSERV_OPERATOR_BRANCH" || exit 4
else
  git -C "$REPODIR" pull --ff-only || exit 4
fi

apply_mirror_config || exit 5

# ── Step 5: Go toolchain (version taken from the repo's go.mod) ──────────────
case "$(uname -m)" in
  x86_64)  GOARCH_HOST=amd64 ;;
  ppc64le) GOARCH_HOST=ppc64le ;;
  aarch64|arm64) GOARCH_HOST=arm64 ;;
  s390x)   GOARCH_HOST=s390x ;;
  *) echo "ERROR: unsupported arch $(uname -m)"; exit 6 ;;
esac

GO_REQUIRED=$(awk '/^go /{print $2; exit}' "$BACKENDDIR/go.mod")
export PATH=$PATH:/usr/local/go/bin
GO_CURRENT=""
command -v go >/dev/null 2>&1 && GO_CURRENT=$(go env GOVERSION | sed 's/^go//')

# Install Go when missing or older than what go.mod requires
if [ -z "$GO_CURRENT" ] || [ "$(printf '%s\n%s\n' "$GO_REQUIRED" "$GO_CURRENT" | sort -V | head -1)" != "$GO_REQUIRED" ]; then
  printInfo "Installing Go ${GO_REQUIRED} (${GOARCH_HOST}); current: '${GO_CURRENT:-none}'"
  GOTAR="go${GO_REQUIRED}.linux-${GOARCH_HOST}.tar.gz"
  wget -q "https://go.dev/dl/${GOTAR}" -O "/tmp/${GOTAR}" || { echo "ERROR: cannot download ${GOTAR}"; exit 7; }
  rm -rf /usr/local/go && tar -C /usr/local -xzf "/tmp/${GOTAR}" && rm -f "/tmp/${GOTAR}"
fi
go version || exit 7

export PATH=$PATH:$(go env GOPATH)/bin
export GOOS=linux
export GOARCH="$GOARCH_HOST"

# ── Step 7: build the test binary ────────────────────────────────────────────
printInfo "Building backend test binary (${GOOS}/${GOARCH})"
cd "$BACKENDDIR" || exit 8
make build-test-binary GOOS="$GOOS" GOARCH="$GOARCH" || { echo "ERROR: build of e2e-tests.test failed"; exit 8; }

# ── Step 8: run the tests ────────────────────────────────────────────────────
OUTFILE="$HOSTDIR/backend-${NOW}.txt"
export JUNIT_REPORT_FILE="${JUNIT_REPORT_FILE:-$HOSTDIR/backend-junit-${NOW}.xml}"
mkdir -p "$HOSTDIR"

GINKGO_ARGS=(run "--timeout=${GINKGO_TIMEOUT}")
[ -n "${GINKGO_FOCUS:-}" ] && GINKGO_ARGS+=("--focus=${GINKGO_FOCUS}")
GINKGO_ARGS+=(e2e-tests.test)

printInfo "Starting NetObserv backend tests: ginkgo ${GINKGO_ARGS[*]}"
ginkgo "${GINKGO_ARGS[@]}" 2>&1 | tee "$OUTFILE"
RC=${PIPESTATUS[0]}

mkdir -p "$HOSTDIR/out-backend-$NOW"
cp -f "$OUTFILE" "$JUNIT_REPORT_FILE" "$HOSTDIR/out-backend-$NOW/" 2>/dev/null || true
echo "INFO: output saved in $OUTFILE and $HOSTDIR/out-backend-$NOW"

# Always exit 0 so Jenkins marks the build GREEN (same convention as frontend.sh).
# Test results are visible in the archived artifacts and console log.
if [ $RC -eq 0 ]; then
  echo "INFO: All backend tests passed!"
else
  echo "WARNING: Some backend tests failed (ginkgo rc=$RC) -- check archived artifacts for details."
fi
exit 0
