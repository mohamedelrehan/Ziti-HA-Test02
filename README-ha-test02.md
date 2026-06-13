# Ziti HA Test02.1

This version fixes OpenZiti v2.0.0 controller config generation.

Fixed command:

```bash
ziti create config controller --ctrlPort 6262 --output /var/lib/ziti-controller/config.yml
```

Upload these files to the GitHub repo root, replacing the previous Test02 files:
- mainTemplate-ha-test02.json
- parameters.ha-test02.example.json
- azure-bootstrap-ziti-ha-controller-v3.sh
- azure-bootstrap-ziti-ha-router-v3.sh
- README-ha-test02.md
- scripts/validate-ha-test02.sh

Validate:
```bash
curl -s https://raw.githubusercontent.com/mohamedelrehan/Ziti-HA-Test02/main/azure-bootstrap-ziti-ha-controller-v3.sh | bash -n
curl -s https://raw.githubusercontent.com/mohamedelrehan/Ziti-HA-Test02/main/azure-bootstrap-ziti-ha-router-v3.sh | bash -n
```
