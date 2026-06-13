#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee -a /var/log/ziti-ha-test02-controller-primary-v4.log) 2>&1
ADMIN_USER="${1:?admin user missing}"
ADMIN_PASS="$(printf '%s' "${2:?admin password b64 missing}" | base64 -d)"
ZITI_USER="${3:-admin}"
ZITI_PWD="$(printf '%s' "${4:?ziti password b64 missing}" | base64 -d)"
PREFIX="${5:?prefix missing}"
C01_HOST="${6:?controller01 name missing}"
C02_HOST="${7:?controller02 name missing}"
C03_HOST="${8:?controller03 name missing}"
R01_HOST="${9:?router01 name missing}"
R02_HOST="${10:?router02 name missing}"
R03_HOST="${11:?router03 name missing}"
C01_PUB_FQDN="${12:-}"
C02_PUB_FQDN="${13:-}"
C03_PUB_FQDN="${14:-}"
R01_PUB_FQDN="${15:-}"
R02_PUB_FQDN="${16:-}"
R03_PUB_FQDN="${17:-}"
RUN_APT_UPGRADE="${18:-false}"
log(){ echo "[$(date -Is)] $*"; }
fail(){ echo "[ERROR] $*"; exit 1; }
wait_for(){ local name="$1"; local cmd="$2"; local retries="${3:-60}"; local sleep_s="${4:-5}"; for i in $(seq 1 "$retries"); do if bash -lc "$cmd"; then log "$name ready"; return 0; fi; sleep "$sleep_s"; done; fail "$name not ready"; }
ssh_base(){ sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$ADMIN_USER@$1" "$2"; }
scp_to(){ sshpass -p "$ADMIN_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$1" "$ADMIN_USER@$2:$3"; }
install_packages(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  if [[ "$RUN_APT_UPGRADE" == "true" ]]; then apt-get upgrade -y; fi
  apt-get install -y curl gpg ca-certificates jq dnsutils iproute2 openssl sed sshpass netcat-openbsd
  curl -sSLf https://get.openziti.io/tun/package-repos.gpg | gpg --dearmor --yes --output /usr/share/keyrings/openziti.gpg
  chmod a+r /usr/share/keyrings/openziti.gpg
  echo "deb [signed-by=/usr/share/keyrings/openziti.gpg] https://packages.openziti.org/zitipax-openziti-deb-stable debian main" > /etc/apt/sources.list.d/openziti-release.list
  apt-get update
  apt-get install -y openziti openziti-controller openziti-console
}
create_controller_config(){
  mkdir -p /var/lib/ziti-controller/cluster /opt/ziti-ha-test02
  cd /var/lib/ziti-controller
  rm -f config.yml
  ziti create config controller --ctrlPort 6262 --routerEnrollmentDuration 3h --identityEnrollmentDuration 3h --output /var/lib/ziti-controller/config.yml
  sed -i "s/localhost/${C01_HOST}/g" config.yml
  if ! grep -qE '^cluster:' config.yml; then
    cat >> config.yml <<EOF

cluster:
  dataDir: /var/lib/ziti-controller/cluster
EOF
  fi
  chown -R ziti-controller:ziti-controller /var/lib/ziti-controller
  chmod -R u=rwX,g=rwX,o= /var/lib/ziti-controller
}
create_pki_for_controller01(){
  sudo -u ziti-controller bash -lc "
set -e
cd /var/lib/ziti-controller
mkdir -p pki
ziti pki create ca --pki-root /var/lib/ziti-controller/pki --ca-file ca --ca-name '${PREFIX} Root CA' --trust-domain '${PREFIX}'
ziti pki create intermediate --pki-root /var/lib/ziti-controller/pki --ca-name ca --intermediate-file intermediate --intermediate-name '${PREFIX} Intermediate CA'
ziti pki create key --pki-root /var/lib/ziti-controller/pki --ca-name intermediate --key-file ${C01_HOST}
ziti pki create server --pki-root /var/lib/ziti-controller/pki --ca-name intermediate --server-file ${C01_HOST}.server --server-name ${C01_HOST} --key-file ${C01_HOST} --dns ${C01_HOST} ${C01_PUB_FQDN:+--dns ${C01_PUB_FQDN}} --ip 127.0.0.1 --spiffe-id /controller/${C01_HOST} --allow-overwrite
ziti pki create client --pki-root /var/lib/ziti-controller/pki --ca-name intermediate --client-file ${C01_HOST}.client --client-name ${C01_HOST} --key-file ${C01_HOST} --spiffe-id /controller/${C01_HOST} --allow-overwrite
cp pki/intermediate/keys/${C01_HOST}.key ./${C01_HOST}.key
cp pki/intermediate/certs/${C01_HOST}.client.chain.pem ./${C01_HOST}client.chain.cert
cp pki/intermediate/certs/${C01_HOST}.server.chain.pem ./${C01_HOST}.server.chain.cert
cp pki/intermediate/certs/intermediate.chain.pem ./${C01_HOST}.ca
cp pki/intermediate/certs/intermediate.cert ./${C01_HOST}.signing.cert
cp pki/intermediate/keys/intermediate.key ./${C01_HOST}.signing.key
chmod 640 /var/lib/ziti-controller/${C01_HOST}*
"
  chown -R ziti-controller:ziti-controller /var/lib/ziti-controller
  chmod 750 /var/lib/ziti-controller
}
start_and_init(){
  systemctl daemon-reload || true
  systemctl enable ziti-controller
  systemctl restart ziti-controller
  wait_for controller01-api "curl -kfsS https://127.0.0.1:1280/version >/dev/null" 90 5
  sudo -u ziti-controller ziti agent cluster init "$ZITI_USER" "$ZITI_PWD" "$C01_HOST" --timeout 60s || true
}
ship_and_finalize_secondaries(){
  tar -czf /tmp/${PREFIX}-shared-pki.tgz -C /var/lib/ziti-controller pki
  chown "$ADMIN_USER:$ADMIN_USER" /tmp/${PREFIX}-shared-pki.tgz || true
  for host in "$C02_HOST" "$C03_HOST"; do wait_for ${host}-ssh "nc -z $host 22" 120 5; scp_to /tmp/${PREFIX}-shared-pki.tgz "$host" /tmp/${PREFIX}-shared-pki.tgz; done
  wait_for ${C02_HOST}-finalize "sshpass -p '$ADMIN_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $ADMIN_USER@$C02_HOST test -x /opt/ziti-ha-test02/finalize-secondary-controller-v4.sh" 120 5
  ssh_base "$C02_HOST" "sudo /opt/ziti-ha-test02/finalize-secondary-controller-v4.sh '$C02_HOST' '$C02_PUB_FQDN' '/tmp/${PREFIX}-shared-pki.tgz'"
  wait_for ${C03_HOST}-finalize "sshpass -p '$ADMIN_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $ADMIN_USER@$C03_HOST test -x /opt/ziti-ha-test02/finalize-secondary-controller-v4.sh" 120 5
  ssh_base "$C03_HOST" "sudo /opt/ziti-ha-test02/finalize-secondary-controller-v4.sh '$C03_HOST' '$C03_PUB_FQDN' '/tmp/${PREFIX}-shared-pki.tgz'"
}
add_controllers(){
  wait_for controller02-api "curl -kfsS https://${C02_HOST}:1280/version >/dev/null" 90 5
  wait_for controller03-api "curl -kfsS https://${C03_HOST}:1280/version >/dev/null" 90 5
  sudo -u ziti-controller ziti agent cluster add "tls:${C02_HOST}:6262" --timeout 60s --voter || true
  sudo -u ziti-controller ziti agent cluster add "tls:${C03_HOST}:6262" --timeout 60s --voter || true
  sudo -u ziti-controller ziti agent cluster list --timeout 60s || true
}
create_router_jwt_and_finalize(){
  local router="$1"
  ziti edge login https://127.0.0.1:1280 -u "$ZITI_USER" -p "$ZITI_PWD" -y || true
  rm -f /tmp/${router}.jwt
  ziti edge create edge-router "$router" -o /tmp/${router}.jwt || true
  [[ -s /tmp/${router}.jwt ]] || fail "JWT not created for $router"
  scp_to /tmp/${router}.jwt "$router" /tmp/${router}.jwt
  wait_for ${router}-finalize "sshpass -p '$ADMIN_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $ADMIN_USER@$router test -x /opt/ziti-ha-test02/finalize-router-v4.sh" 120 5
  ssh_base "$router" "sudo /opt/ziti-ha-test02/finalize-router-v4.sh '$router' '/tmp/${router}.jwt'"
}
main(){
  log "Starting HA Test02.2 primary/orchestrator"
  install_packages
  create_controller_config
  create_pki_for_controller01
  start_and_init
  ship_and_finalize_secondaries
  add_controllers
  for r in "$R01_HOST" "$R02_HOST" "$R03_HOST"; do wait_for ${r}-ssh "nc -z $r 22" 120 5; create_router_jwt_and_finalize "$r"; done
  ziti edge list edge-routers || true
  sudo -u ziti-controller ziti agent cluster list --timeout 60s || true
  cat > /opt/ziti-ha-test02/controller-status.txt <<EOS
status=completed
role=controller-primary-orchestrator
cluster_check=sudo -u ziti-controller ziti agent cluster list --timeout 30s
router_check=ziti edge list edge-routers
log=/var/log/ziti-ha-test02-controller-primary-v4.log
EOS
}
main "$@"
