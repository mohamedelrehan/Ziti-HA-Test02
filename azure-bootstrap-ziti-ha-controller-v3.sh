#!/usr/bin/env bash
set -Eeuo pipefail

# Ziti HA Test02 controller bootstrap
# Full 3-controller cluster first implementation attempt.
#
# Args:
# 1 node_index: 1,2,3
# 2 node_name
# 3 controller_fqdn
# 4 controller01_private_ip
# 5 controller02_private_ip
# 6 controller03_private_ip
# 7 ziti_admin_user
# 8 ziti_admin_password_base64
# 9 run_apt_upgrade true|false

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

ZITI_PWD="$(printf "%s" "${ZITI_PWD_B64}" | base64 -d)"

STATUS="success"
log(){ printf '\n[INFO] %s\n' "$*"; }
warn(){ printf '\n[WARN] %s\n' "$*" >&2; }
mark_warn(){ STATUS="warning"; warn "$*"; }

finish_for_azure() {
  mkdir -p /opt/ziti-ha-test02
  cat > /opt/ziti-ha-test02/controller-status.txt <<EOF_STATUS
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
EOF_STATUS
  log "Controller bootstrap status: ${STATUS}"
  log "Returning success to Azure Custom Script Extension."
  exit 0
}
trap finish_for_azure EXIT

private_ip_for_index() {
  case "${NODE_INDEX}" in
    1) echo "${CTRL01_IP}" ;;
    2) echo "${CTRL02_IP}" ;;
    3) echo "${CTRL03_IP}" ;;
    *) echo "${CTRL01_IP}" ;;
  esac
}

install_packages() {
  log "Installing OpenZiti packages"
  apt-get update
  if [[ "${RUN_APT_UPGRADE}" == "true" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl gpg ca-certificates jq dnsutils iproute2 openssl

  curl -sSLf https://get.openziti.io/tun/package-repos.gpg | \
    gpg --dearmor --yes --output /usr/share/keyrings/openziti.gpg
  chmod a+r /usr/share/keyrings/openziti.gpg

  echo "deb [signed-by=/usr/share/keyrings/openziti.gpg] https://packages.openziti.org/zitipax-openziti-deb-stable debian main" \
    > /etc/apt/sources.list.d/openziti-release.list

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y openziti openziti-controller openziti-console
}

write_health_check() {
  mkdir -p /opt/ziti-ha-test02
  cat > /opt/ziti-ha-test02/check-controller.sh <<'EOF_CHECK'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "=== Controller status ==="
cat /opt/ziti-ha-test02/controller-status.txt 2>/dev/null || true
echo
echo "=== ziti version ==="
ziti version || true
echo
echo "=== systemd ==="
sudo systemctl status ziti-controller --no-pager -l || true
echo
echo "=== Listening ports ==="
sudo ss -tulpn | egrep '1280|6262|443|80' || true
echo
echo "=== Local version endpoint ==="
curl -k https://127.0.0.1:1280/version || true
echo
echo "=== Controller logs ==="
sudo journalctl -u ziti-controller -n 100 --no-pager || true
EOF_CHECK
  chmod +x /opt/ziti-ha-test02/check-controller.sh
}

create_first_controller_config() {
  local ip
  ip="$(private_ip_for_index)"
  log "Creating initial controller config for node ${NODE_INDEX}, ip ${ip}"

  mkdir -p /var/lib/ziti-controller /opt/ziti-ha-test02/pki
  cd /var/lib/ziti-controller

  # Use quickstart-like config generation where possible.
  # This first HA test intentionally starts with generated single-node configs,
  # then adds cluster stanza placeholders. We validate exact OpenZiti HA behavior in test iterations.
  if [[ ! -s /var/lib/ziti-controller/config.yml ]]; then
    ziti create config controller \
      --ctrlAddress "${NODE_FQDN}" \
      --ctrlPort 1280 \
      --output /var/lib/ziti-controller/config.yml || true
  fi

  if [[ ! -s /var/lib/ziti-controller/config.yml ]]; then
    mark_warn "ziti create config controller did not create config.yml. Package syntax may have changed."
    return 1
  fi

  mkdir -p /var/lib/ziti-controller/cluster

  # Append cluster block if missing. This is the part to validate in HA test02.
  if ! grep -qE '^cluster:' /var/lib/ziti-controller/config.yml; then
    cat >> /var/lib/ziti-controller/config.yml <<EOF_CLUSTER

cluster:
  dataDir: /var/lib/ziti-controller/cluster
  advertiseAddress: ${ip}
  advertisePort: 6262
EOF_CLUSTER
  fi

  chown -R ziti-controller:ziti-controller /var/lib/ziti-controller || true
}

configure_service() {
  log "Configuring ziti-controller service"
  systemctl daemon-reload || true
  systemctl enable ziti-controller || true
  systemctl restart ziti-controller || true

  sleep 8
  if systemctl is-active --quiet ziti-controller; then
    log "ziti-controller is active."
  else
    mark_warn "ziti-controller is not active."
    journalctl -u ziti-controller -n 150 --no-pager || true
  fi
}

wait_for_controller01() {
  log "Waiting for controller01 at https://${CTRL01_IP}:1280"
  for i in $(seq 1 60); do
    if curl -kfsS "https://${CTRL01_IP}:1280/version" >/dev/null; then
      log "controller01 reachable"
      return 0
    fi
    sleep 10
  done
  mark_warn "controller01 not reachable"
  return 1
}

init_or_join_cluster() {
  log "HA cluster init/join placeholder for node ${NODE_INDEX}"

  # This is intentionally conservative: do not run destructive cluster commands without validation.
  # We record the intended cluster operation. After first test output, we will wire exact ziti agent cluster commands.
  mkdir -p /opt/ziti-ha-test02
  cat > /opt/ziti-ha-test02/cluster-plan.txt <<EOF_CLUSTER_PLAN
node_index=${NODE_INDEX}
node_name=${NODE_NAME}
intended_model=full-3-controller-cluster
controller01=${CTRL01_IP}:6262
controller02=${CTRL02_IP}:6262
controller03=${CTRL03_IP}:6262

Next validation step:
- confirm generated config.yml syntax
- confirm ziti-controller starts on all nodes
- then wire ziti agent cluster init/add commands exactly for OpenZiti v2.0.0
EOF_CLUSTER_PLAN
}

main() {
  log "Starting HA test02 controller bootstrap"
  log "Node index: ${NODE_INDEX}"
  log "Node name: ${NODE_NAME}"
  log "Node FQDN: ${NODE_FQDN}"

  write_health_check
  install_packages
  create_first_controller_config || return 0
  configure_service
  if [[ "${NODE_INDEX}" != "1" ]]; then
    wait_for_controller01 || true
  fi
  init_or_join_cluster
  /opt/ziti-ha-test02/check-controller.sh || true
}

main "$@"
