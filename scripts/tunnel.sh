#!/usr/bin/env bash
# tunnel.sh — OCI Bastion port forwards into the private subnet: localhost:6443 to
# the Kubernetes API behind the internal load balancer (the kubeconfig output
# points at 127.0.0.1), or a node's SSH for break-glass access.
#
#   scripts/tunnel.sh up            # Kubernetes API on localhost:6443
#   scripts/tunnel.sh ssh server-0  # an SSH shell on a node (needs ssh_public_key)
#   scripts/tunnel.sh down          # stop the forwards and delete the sessions
#   scripts/tunnel.sh status
#
# Env: TF_DIR (default: ../example), SSH_KEY (default: ~/.ssh/id_ed25519; its .pub
# is sent to the Bastion), SESSION_TTL (seconds, default 10800, the max).
# Requires: oci CLI, ssh, tofu (outputs bastion_id, internal_lb_ip, node_private_ips).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${TF_DIR:-$SCRIPT_DIR/../example}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SESSION_TTL="${SESSION_TTL:-10800}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/k3s-oci"
SSH_LOCAL_PORT=2222
export GODEBUG="${GODEBUG:-http2client=0}"

log() { echo "[tunnel] $*" >&2; }
die() { echo "[tunnel] ERROR: $*" >&2; exit 1; }

out() { tofu -chdir="$TF_DIR" output -raw "$1"; }

region() {
  if [[ -n "${OCI_REGION:-}" ]]; then echo "$OCI_REGION"; else sed -n 's/^region *= *//p' ~/.oci/config | head -n 1; fi
}

# OCI Bastion offers only AES-CTR ciphers, which hardened ssh configs often leave
# out (the + adds them to OpenSSH's defaults), and IdentitiesOnly keeps an agent's
# other keys from using up the server's attempts.
SSH_OPTS=(-o Ciphers=+aes256-ctr -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new)

# listening <port>: something accepts connections on 127.0.0.1:<port>.
listening() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# forward <local port> <target ip> <target port>: a Bastion port-forwarding
# session and the ssh that carries it, in the background.
forward() {
  local local_port=$1 target=$2 target_port=$3 bastion session
  [[ -r "$SSH_KEY" && -r "$SSH_KEY.pub" ]] || die "SSH key pair $SSH_KEY(.pub) not found (set SSH_KEY)"
  if listening "$local_port"; then
    log "localhost:$local_port already forwarded"
    return 0
  fi
  bastion=$(out bastion_id) || die "no bastion_id output (enable_bastion = true?)"
  mkdir -p "$STATE_DIR"
  session=$(oci bastion session create-port-forwarding --bastion-id "$bastion" \
    --target-private-ip "$target" --target-port "$target_port" --session-ttl "$SESSION_TTL" \
    --display-name "k3s-oci-$local_port-$(date +%s)" --ssh-public-key-file "$SSH_KEY.pub" \
    --wait-for-state SUCCEEDED --query 'data.resources[0].identifier' --raw-output)
  [[ -n "$session" ]] || die "could not create a Bastion session for $target:$target_port"
  echo "$session" > "$STATE_DIR/$local_port.session"
  for _ in $(seq 1 30); do
    [[ "$(oci bastion session get --session-id "$session" --query 'data."lifecycle-state"' --raw-output)" == "ACTIVE" ]] && break
    sleep 5
  done
  # An ACTIVE session can still refuse the key for a few seconds: retry.
  for _ in $(seq 1 6); do
    ssh -i "$SSH_KEY" -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 "${SSH_OPTS[@]}" \
      -o UserKnownHostsFile="$STATE_DIR/known_hosts" \
      -L "127.0.0.1:$local_port:$target:$target_port" -p 22 "$session@host.bastion.$(region).oci.oraclecloud.com" &
    echo $! > "$STATE_DIR/$local_port.pid"
    for _ in $(seq 1 10); do
      listening "$local_port" && break 2
      kill -0 "$(cat "$STATE_DIR/$local_port.pid")" 2>/dev/null || break
      sleep 2
    done
    sleep 5
  done
  listening "$local_port" || die "the port forward to $target:$target_port did not come up"
  log "localhost:$local_port → $target:$target_port (session ${session: -8})"
}

stop() {
  local port=$1
  if [[ -f "$STATE_DIR/$port.pid" ]]; then
    kill "$(cat "$STATE_DIR/$port.pid")" 2>/dev/null || true
    rm -f "$STATE_DIR/$port.pid"
  fi
  if [[ -f "$STATE_DIR/$port.session" ]]; then
    oci bastion session delete --session-id "$(cat "$STATE_DIR/$port.session")" --force >/dev/null 2>&1 || true
    rm -f "$STATE_DIR/$port.session"
  fi
}

node_ssh() {
  local node=${1:?usage: tunnel.sh ssh <node>} ip user
  ip=$(tofu -chdir="$TF_DIR" output -json node_private_ips | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$node")
  [[ -n "$ip" ]] || die "no node $node (tofu output node_private_ips)"
  user=$( [[ "$(out os_family)" == opensuse ]] && echo sles || echo core )
  stop "$SSH_LOCAL_PORT"
  forward "$SSH_LOCAL_PORT" "$ip" 22
  ssh -i "$SSH_KEY" -p "$SSH_LOCAL_PORT" "${SSH_OPTS[@]}" \
    -o UserKnownHostsFile="$STATE_DIR/known_hosts.$node" "$user@127.0.0.1"
  stop "$SSH_LOCAL_PORT"
}

case "${1:-}" in
  up) forward 6443 "$(out internal_lb_ip)" 6443 ;;
  ssh) node_ssh "${2:-}" ;;
  down) stop 6443; stop "$SSH_LOCAL_PORT"; log "forwards stopped, sessions deleted" ;;
  status) if listening 6443; then echo "localhost:6443 up"; else echo "localhost:6443 down"; fi ;;
  *) sed -n '2,13p' "$0" >&2; exit 2 ;;
esac
