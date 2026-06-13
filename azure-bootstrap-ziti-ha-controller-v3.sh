#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee -a /var/log/ziti-ha-test02-controller-bootstrap.log) 2>&1

NODE_INDEX="${1:?node index missing}"
NODE_NAME="${2:?node name missing}"
NODE_FQDN="${3:?controller fqdn missing}"
CTRL01_IP="${4:?controller01 private ip missing}"
CTRL02_IP="${5:?controller02 private ip missing}"
CTRL03_IP="${6:?controller03 private ip missing}"
ZITI_USER="${7:-admin}"
ZITI_PWD_B64="${8:?ziti password b64 missing}"
RUN_APT_UPGRADE="${9:-true}"
ZITI_PWD="$(printf "%s" "$ZITI_PWD_B64" | base64 -d)"
STATUS="success"

log(){ printf '\n[INFO] %s\n' "$*"; }
warn(){ printf '\n[WARN] %s\n' "$*" >&2; }
mark_warn(){ STATUS="warning"; warn "$*"; }

finish_for_azure(){
  mkdir -p /opt/ziti-ha-test02
  cat > /opt/ziti-ha-test02/controller-status.txt <<EOF
status=${STATUS}
role=controller
node_index=${NODE_INDEX}
node_name=${NODE_NAME}
node_fqdn=${NODE_FQDN}
controller01_private_ip=${CTRL01_IP}
controller02_private_ip=${CTRL02_IP}
controller03_private_ip=${CTRL03_IP}
finished_at=$(date -Is)
log=/var/log/ziti-ha-test02-controller-bootstrap.log
health_check=/opt/ziti-ha-test02/check-controller.sh
config=/var/lib/ziti-controller/config.yml
EOF
  log "Controller bootstrap status: ${STATUS}"
  exit 0
}
trap finish_for_azure EXIT

this_ip(){
  case "$NODE_INDEX" in
    1) echo "$CTRL01_IP" ;;
    2) echo "$CTRL02_IP" ;;
    3) echo "$CTRL03_IP" ;;
    *) echo "$CTRL01_IP" ;;
  esac
}

write_health(){
  mkdir -p /opt/ziti-ha-test02
  cat > /opt/ziti-ha-test02/check-controller.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "=== Controller status ==="
cat /opt/ziti-ha-test02/controller-status.txt 2>/dev/null || true
echo
echo "=== ziti version ==="
ziti version || true
echo
echo "=== Config ==="
sudo ls -lah /var/lib/ziti-controller/ || true
sudo test -s /var/lib/ziti-controller/config.yml && echo "config.yml exists" || echo "config.yml missing"
echo
echo "=== systemd ==="
sudo systemctl status ziti-controller --no-pager -l || true
echo
echo "=== Listening ports ==="
sudo ss -tulpn | egrep '1280|6262|10001|443|80' || true
echo
echo "=== Local API ==="
curl -k https://127.0.0.1:1280/version || true
echo
echo "=== Agent list ==="
ziti agent list || true
echo
echo "=== Cluster list ==="
ziti agent cluster list --timeout 10s || true
echo
echo "=== Controller logs ==="
sudo journalctl -u ziti-controller -n 120 --no-pager || true
EOF
  chmod +x /opt/ziti-ha-test02/check-controller.sh
}

install_packages(){
  log "Installing OpenZiti controller packages"
  apt-get update
  if [[ "$RUN_APT_UPGRADE" == "true" ]]; then DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl gpg ca-certificates jq dnsutils iproute2 openssl sed
  curl -sSLf https://get.openziti.io/tun/package-repos.gpg | gpg --dearmor --yes --output /usr/share/keyrings/openziti.gpg
  chmod a+r /usr/share/keyrings/openziti.gpg
  echo "deb [signed-by=/usr/share/keyrings/openziti.gpg] https://packages.openziti.org/zitipax-openziti-deb-stable debian main" > /etc/apt/sources.list.d/openziti-release.list
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y openziti openziti-controller openziti-console
}

create_config(){
  local ip; ip="$(this_ip)"
  log "Creating OpenZiti v2.0.0 controller config"
  mkdir -p /var/lib/ziti-controller/cluster
  cd /var/lib/ziti-controller
  if [[ ! -s config.yml ]]; then
    ziti create config controller --ctrlPort 6262 --routerEnrollmentDuration 3h --identityEnrollmentDuration 3h --output /var/lib/ziti-controller/config.yml
  fi
  [[ -s config.yml ]] || { mark_warn "config.yml was not created"; return 1; }

  cp config.yml config.yml.original || true
  sed -i "s/localhost/${NODE_FQDN}/g" config.yml || true

  if ! grep -qE '^cluster:' config.yml; then
    cat >> config.yml <<EOF

cluster:
  dataDir: /var/lib/ziti-controller/cluster
  advertiseAddress: ${ip}
  advertisePort: 6262
EOF
  fi
  chown -R ziti-controller:ziti-controller /var/lib/ziti-controller || true
  chmod -R u=rwX,g=rwX,o= /var/lib/ziti-controller || true
}

start_controller(){
  log "Starting ziti-controller"
  systemctl daemon-reload || true
  systemctl enable ziti-controller || true
  systemctl restart ziti-controller || true

  for i in $(seq 1 30); do
    systemctl is-active --quiet ziti-controller && break
    sleep 4
  done

  if ! systemctl is-active --quiet ziti-controller; then
    mark_warn "ziti-controller is not active"
    journalctl -u ziti-controller -n 200 --no-pager || true
    return 1
  fi

  for i in $(seq 1 30); do
    curl -kfsS https://127.0.0.1:1280/version >/dev/null && return 0
    sleep 4
  done
  mark_warn "controller API did not become reachable on 127.0.0.1:1280"
  return 1
}

cluster_logic(){
  if [[ "$NODE_INDEX" == "1" ]]; then
    log "Initializing cluster on controller01"
    sleep 10
    ziti agent list || true
    ziti agent cluster init "$ZITI_USER" "$ZITI_PWD" "$NODE_NAME" --timeout 30s || mark_warn "cluster init failed or already initialized"
    sleep 60
    ziti agent cluster add "${CTRL02_IP}:6262" --timeout 30s --voter || mark_warn "cluster add controller02 failed"
    ziti agent cluster add "${CTRL03_IP}:6262" --timeout 30s --voter || mark_warn "cluster add controller03 failed"
    ziti agent cluster list --timeout 30s || mark_warn "cluster list failed"
  else
    log "Non-primary controller started. Controller01 will add this node."
  fi
}

main(){
  log "Starting HA test02.1 controller bootstrap"
  log "Node index: ${NODE_INDEX}; FQDN: ${NODE_FQDN}; IP: $(this_ip)"
  write_health
  install_packages
  create_config || return 0
  start_controller || return 0
  cluster_logic || true
  /opt/ziti-ha-test02/check-controller.sh || true
}
main "$@"
