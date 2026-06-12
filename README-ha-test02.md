# Ziti HA Test02 - Full 3-Controller Cluster Attempt

This package replaces the placeholder files.

## Important

This is the first implementation attempt for OpenZiti HA. It provisions:
- 3 controller VMs
- 3 router VMs
- OpenZiti packages
- Initial controller configs with HA cluster stanza
- Native router bootstrap/enrollment against controller01

## Required repo files

Upload these files to the repo root:
- mainTemplate-ha-test02.json
- parameters.ha-test02.example.json
- azure-bootstrap-ziti-ha-controller-v3.sh
- azure-bootstrap-ziti-ha-router-v3.sh
- README-ha-test02.md
- scripts/validate-ha-test02.sh

## Validate raw URLs

```bash
curl -I https://raw.githubusercontent.com/mohamedelrehan/Ziti-HA-Test02/main/azure-bootstrap-ziti-ha-controller-v3.sh
curl -I https://raw.githubusercontent.com/mohamedelrehan/Ziti-HA-Test02/main/azure-bootstrap-ziti-ha-router-v3.sh
curl -s https://raw.githubusercontent.com/mohamedelrehan/Ziti-HA-Test02/main/azure-bootstrap-ziti-ha-controller-v3.sh | bash -n
curl -s https://raw.githubusercontent.com/mohamedelrehan/Ziti-HA-Test02/main/azure-bootstrap-ziti-ha-router-v3.sh | bash -n
```

## Deploy

Use `mainTemplate-ha-test02.json`.

## Validate

On controller01:

```bash
sudo /opt/ziti-ha-test02/check-controller.sh
ziti edge login https://localhost:1280 -u admin
ziti edge list edge-routers
ziti fabric list routers
```

On routers:

```bash
sudo /opt/ziti-ha-test02/check-router.sh
```

## Note

This version is intentionally conservative around the controller cluster join commands. We must validate OpenZiti v2.0.0 controller config/service behavior first, then wire exact `ziti agent cluster init/add` commands in the next iteration if needed.
