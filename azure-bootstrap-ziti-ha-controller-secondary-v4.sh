#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee -a /var/log/ziti-ha-test02-controller-secondary-v4.log) 2>&1
NODE_NAME="${1:?node name missing}"
NODE_FQDN="${2:-}"
RUN_APT_UPGRADE="${3:-false}"
log(){ echo "[$(date -Is)] $*"; }
install_packages(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  if [[ "$RUN_APT_UPGRADE" == "true" ]]; then apt-get upgrade -y; fi
  apt-get install -y curl gpg ca-certificates jq dnsutils iproute2 openssl sed netcat-openbsd
  curl -sSLf https://get.openziti.io/tun/package-repos.gpg | gpg --dearmor --yes --output /usr/share/keyrings/openziti.gpg
  chmod a+r /usr/share/keyrings/openziti.gpg
  echo "deb [signed-by=/usr/share/keyrings/openziti.gpg] https://packages.openziti.org/zitipax-openziti-deb-stable debian main" > /etc/apt/sources.list.d/openziti-release.list
  apt-get update
  apt-get install -y openziti openziti-controller openziti-console
}
create_placeholder_config(){
  mkdir -p /var/lib/ziti-controller/cluster /opt/ziti-ha-test02
  cd /var/lib/ziti-controller
  rm -f config.yml
  ziti create config controller --ctrlPort 6262 --routerEnrollmentDuration 3h --identityEnrollmentDuration 3h --output /var/lib/ziti-controller/config.yml
  sed -i "s/localhost/${NODE_NAME}/g" config.yml
  if ! grep -qE '^cluster:' config.yml; then
    cat >> config.yml <<EOF

cluster:
  dataDir: /var/lib/ziti-controller/cluster
EOF
  fi
  chown -R ziti-controller:ziti-controller /var/lib/ziti-controller
  chmod -R u=rwX,g=rwX,o= /var/lib/ziti-controller
  systemctl disable --now ziti-controller || true
}
write_finalize(){
  cat > /opt/ziti-ha-test02/finalize-secondary-controller-v4.sh <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
NODE_NAME="${1:?node name missing}"
NODE_FQDN="${2:-}"
PKI_TGZ="${3:?pki tarball missing}"
exec > >(tee -a /var/log/ziti-ha-test02-finalize-secondary-controller-v4.log) 2>&1
systemctl stop ziti-controller || true
mkdir -p /var/lib/ziti-controller
if [[ -d /var/lib/ziti-controller/pki ]]; then mv /var/lib/ziti-controller/pki /var/lib/ziti-controller/pki.local.$(date +%Y%m%d-%H%M%S); fi
tar -xzf "$PKI_TGZ" -C /var/lib/ziti-controller
chown -R ziti-controller:ziti-controller /var/lib/ziti-controller/pki
sudo -u ziti-controller bash -lc "
set -e
cd /var/lib/ziti-controller
ziti pki create key --pki-root /var/lib/ziti-controller/pki --ca-name intermediate --key-file ${NODE_NAME}
ziti pki create server --pki-root /var/lib/ziti-controller/pki --ca-name intermediate --server-file ${NODE_NAME}.server --server-name ${NODE_NAME} --key-file ${NODE_NAME} --dns ${NODE_NAME} ${NODE_FQDN:+--dns ${NODE_FQDN}} --ip 127.0.0.1 --spiffe-id /controller/${NODE_NAME} --allow-overwrite
ziti pki create client --pki-root /var/lib/ziti-controller/pki --ca-name intermediate --client-file ${NODE_NAME}.client --client-name ${NODE_NAME} --key-file ${NODE_NAME} --spiffe-id /controller/${NODE_NAME} --allow-overwrite
cp pki/intermediate/keys/${NODE_NAME}.key ./${NODE_NAME}.key
cp pki/intermediate/certs/${NODE_NAME}.client.chain.pem ./${NODE_NAME}client.chain.cert
cp pki/intermediate/certs/${NODE_NAME}.server.chain.pem ./${NODE_NAME}.server.chain.cert
cp pki/intermediate/certs/intermediate.chain.pem ./${NODE_NAME}.ca
cp pki/intermediate/certs/intermediate.cert ./${NODE_NAME}.signing.cert
cp pki/intermediate/keys/intermediate.key ./${NODE_NAME}.signing.key
chmod 640 /var/lib/ziti-controller/${NODE_NAME}*
"
chown -R ziti-controller:ziti-controller /var/lib/ziti-controller
chmod 750 /var/lib/ziti-controller
systemctl enable ziti-controller
systemctl restart ziti-controller
for i in $(seq 1 60); do curl -kfsS https://127.0.0.1:1280/version >/dev/null && break; sleep 5; done
systemctl status ziti-controller --no-pager || true
EOS
  chmod +x /opt/ziti-ha-test02/finalize-secondary-controller-v4.sh
}
main(){
  log "Starting HA Test02.2 secondary bootstrap for $NODE_NAME"
  install_packages
  create_placeholder_config
  write_finalize
  cat > /opt/ziti-ha-test02/controller-status.txt <<EOS
status=waiting_for_primary
role=controller-secondary
node_name=${NODE_NAME}
finalize=/opt/ziti-ha-test02/finalize-secondary-controller-v4.sh
log=/var/log/ziti-ha-test02-controller-secondary-v4.log
EOS
}
main "$@"
