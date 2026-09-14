#!/usr/bin/env bash
# Open an SSH tunnel to a site's k3s API server and print the KUBECONFIG line
# to use with it. The API server is not exposed to the internet by design
# (ufw denies 6443), so this is the intended access path.
#
# Usage:  ./scripts/kubectl-tunnel.sh <site> [local-port]
#         ./scripts/kubectl-tunnel.sh chicago
#
# Stop the tunnel with:  pkill -f "^ssh -f -N .*-L <port>:127.0.0.1:6443"
set -euo pipefail

cd "$(dirname "$0")/.."

SITE="${1:-}"
PORT="${2:-6443}"

if [[ -z "$SITE" ]]; then
  echo "usage: $0 <site> [local-port]" >&2
  echo "sites: $(ls kubeconfigs/*.yaml 2>/dev/null | xargs -n1 basename | sed 's/\.yaml//' | tr '\n' ' ')" >&2
  exit 1
fi

KUBECONFIG_SRC="kubeconfigs/${SITE}.yaml"
[[ -f "$KUBECONFIG_SRC" ]] || { echo "error: no kubeconfig for '$SITE'" >&2; exit 1; }

WORKING="kubeconfigs/.${SITE}-tunnel.yaml"

# Check the port first - it is cheap and needs no inventory lookup. Otherwise a
# second run exits under set -e with a bare ssh bind error, after the working
# kubeconfig was already rewritten.
if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
  echo "Local port ${PORT} is already in use - a tunnel is probably already up." >&2
  if [[ -f "$WORKING" ]]; then
    echo "If it is the ${SITE} tunnel:  export KUBECONFIG=$(pwd)/${WORKING}" >&2
  fi
  echo "Otherwise pick another port:  $0 ${SITE} <local-port>" >&2
  exit 1
fi

# One inventory lookup for both values. ansible-inventory refuses to run when
# it inherits a non-blocking stderr (common when this script's output is piped
# or captured), so give it a plain file and surface the text only on failure.
INV_ERR=$(mktemp)
trap 'rm -f "$INV_ERR"' EXIT
if ! HOSTVARS=$(ansible-inventory --host "$SITE" 2>"$INV_ERR" </dev/null); then
  echo "error: inventory lookup for '$SITE' failed:" >&2
  cat "$INV_ERR" >&2
  exit 1
fi
read -r IP ADMIN < <(python3 -c '
import json, sys
v = json.loads(sys.argv[1])
print(v["ansible_host"], v.get("admin_user", "ipni"))
' "$HOSTVARS")

# Point a working copy of the kubeconfig at the local end of the tunnel.
sed "s|127.0.0.1:6443|127.0.0.1:${PORT}|" "$KUBECONFIG_SRC" > "$WORKING"
chmod 600 "$WORKING"

echo "Opening tunnel to ${SITE} (${IP}) on local port ${PORT}..."
ssh -f -N -o ExitOnForwardFailure=yes -L "${PORT}:127.0.0.1:6443" "${ADMIN}@${IP}"

cat <<EOF

Tunnel is up. Use it with:

    export KUBECONFIG=$(pwd)/${WORKING}
    kubectl get nodes

Close it with:

    pkill -f "^ssh -f -N .*-L ${PORT}:127.0.0.1:6443"

(The pattern is anchored on ^ssh so it cannot match the shell running pkill.)
EOF
