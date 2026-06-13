#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee -a /var/log/ziti-ha-test02-router-bootstrap.log) 2>&1

CTRL_URL="${1:?controller url missing}"
CTRL_USER="${2:-admin}"
CTRL_PWD_B64="${3:?admin password b64 missing}"
ROUTER_NAME="${4:?router name missing}"
ROUTER_FQDN="${5:?router fqdn missing}"
RUN_APT_UPGRADE="${6:-true}"
CTRL_PWD="$(printf "%s" "$CTRL_PWD_B64" | base64 -d)"
STATUS="success"

log(){ printf '\n[INFO] %s\n' "$*"; }
warn(){ printf '\n[WARN] %s\n' "$*" >&2; }
mark_warn(){ STATUS="warning"; warn "$*"; }

finish_for_azure(){
  mkdir -p /opt/ziti-ha-test02
  cat > /opt/ziti-ha-test02/router-status.txt <<EOF
status=${STATUS}
role=router
router_name=${ROUTER_NAME}
router_fqdn=${ROUTER_FQDN}
controller_url=${CTRL_URL}
finished_at=$(date -Is)
log=/var/log/ziti-ha-test02-router-bootstrap.log
health_check=/opt/ziti-ha-test02/check-router.sh
EOF
  log "Router bootstrap status: ${STATUS}"
  exit 0
}
trap finish_for_azure EXIT

write_health(){
  mkdir -p /opt/ziti-ha-test02
  cat > /opt/ziti-ha-test02/check-router.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "=== Router status ==="
cat /opt/ziti-ha-test02/router-status.txt 2>/dev/null || true
echo
echo "=== ziti version ==="
ziti version || true
echo
echo "=== ziti-router service ==="
sudo systemctl status ziti-router --no-pager -l || true
echo
echo "=== Router config ==="
sudo ls -lah /var/lib/ziti-router/ || true
sudo test -s /var/lib/ziti-router/config.yml && echo "config.yml exists" || echo "config.yml missing"
echo
echo "=== Listening ports ==="
sudo ss -tulpn | egrep '3022|10080|1280' || true
echo
echo "=== Logs ==="
sudo journalctl -u ziti-router -n 120 --no-pager || true
EOF
  chmod +x /opt/ziti-ha-test02/check-router.sh
}

install_packages(){
  log "Installing OpenZiti router packages"
  apt-get update
  if [[ "$RUN_APT_UPGRADE" == "true" ]]; then DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl gpg ca-certificates jq dnsutils iproute2
  curl -sSLf https://get.openziti.io/tun/package-repos.gpg | gpg --dearmor --yes --output /usr/share/keyrings/openziti.gpg
  chmod a+r /usr/share/keyrings/openziti.gpg
  echo "deb [signed-by=/usr/share/keyrings/openziti.gpg] https://packages.openziti.org/zitipax-openziti-deb-stable debian main" > /etc/apt/sources.list.d/openziti-release.list
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y openziti openziti-router
}

wait_controller(){
  log "Waiting for controller ${CTRL_URL}"
  for i in $(seq 1 90); do
    curl -kfsS "${CTRL_URL}/version" >/dev/null && return 0
    sleep 10
  done
  mark_warn "Controller not reachable"
  return 1
}

create_jwt(){
  mkdir -p /opt/ziti-ha-test02
  local jwt="/opt/ziti-ha-test02/${ROUTER_NAME}.jwt"
  log "Logging into controller"
  ziti edge login "$CTRL_URL" -u "$CTRL_USER" -p "$CTRL_PWD" -y
  log "Creating router JWT"
  if ziti edge create edge-router "$ROUTER_NAME" -o "$jwt" -t; then
    log "JWT created"
  elif ziti edge create edge-router "$ROUTER_NAME" --jwt-output-file "$jwt" --tunneler-enabled; then
    log "JWT created with long options"
  elif ziti edge create edge-router "$ROUTER_NAME" -o "$jwt"; then
    log "JWT created without tunneler flag"
  else
    mark_warn "Failed to create router JWT"
    return 1
  fi
  [[ -s "$jwt" ]] || { mark_warn "JWT missing"; return 1; }
  chmod 600 "$jwt"
}

native_bootstrap(){
  local jwt="/opt/ziti-ha-test02/${ROUTER_NAME}.jwt"
  local env="/opt/ziti-ha-test02/${ROUTER_NAME}-bootstrap.env"
  local host
  host="$(printf "%s" "$CTRL_URL" | sed -E 's#^https?://##; s#:.*$##')"
  cat > "$env" <<EOF
ZITI_BOOTSTRAP=true
ZITI_BOOTSTRAP_CONFIG=true
ZITI_BOOTSTRAP_ENROLLMENT=true
ZITI_ROUTER_NAME=${ROUTER_NAME}
ZITI_ROUTER_TYPE=edge
ZITI_ROUTER_MODE=host
ZITI_ROUTER_ADVERTISED_ADDRESS=${ROUTER_FQDN}
ZITI_ROUTER_PORT=3022
ZITI_CTRL_ADVERTISED_ADDRESS=${host}
ZITI_CTRL_ADVERTISED_PORT=1280
ZITI_ENROLL_TOKEN=${jwt}
EOF
  chmod 600 "$env"
  ZITI_BOOTSTRAP=true ZITI_BOOTSTRAP_CONFIG=force ZITI_BOOTSTRAP_ENROLLMENT=force VERBOSE=1 /opt/openziti/etc/router/bootstrap.bash "$env"
  systemctl daemon-reload || true
  systemctl enable ziti-router || true
  systemctl restart ziti-router || true
  sleep 8
  systemctl is-active --quiet ziti-router || { mark_warn "ziti-router is not active"; journalctl -u ziti-router -n 150 --no-pager || true; }
}

main(){
  log "Starting HA test02.1 router bootstrap"
  write_health
  install_packages
  wait_controller || return 0
  create_jwt || return 0
  native_bootstrap || { mark_warn "native bootstrap failed"; return 0; }
  /opt/ziti-ha-test02/check-router.sh || true
}
main "$@"
