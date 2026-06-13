# Ziti HA Test02.2 Reviewed Azure Portal Template

This is the corrected next version of `Ziti-HA-Test02-1.zip`. It keeps the same Azure Portal input style and parameter names from Test02.1, but fixes the bootstrap issues found during manual validation.

## What changed

- Keeps `azuredeploy.json` / `azuredeploy.parameters.json` portal style.
- Keeps the original input model: `deploymentPrefix`, separate controller/router VM sizes, VNet/subnet inputs, zones, DNS label prefix, admin source CIDR, Ziti admin credentials, and `repoRawBaseUrl`.
- Controller01 is now the orchestrator.
- Controller01 generates the shared OpenZiti PKI and its own SPIFFE `/controller/<name>` identity.
- Controller02 and controller03 install packages, wait disabled, then receive the shared PKI from controller01 and generate identities from the same CA.
- Controller01 initializes the cluster and adds controller02/controller03 as voters using `tls:<hostname>:6262`.
- Routers install packages only at first, then controller01 creates router JWTs, copies them, enrolls routers, and starts `ziti-router`.

## Required GitHub layout

Upload this folder to your repo root so raw URLs resolve like:

```text
https://raw.githubusercontent.com/mohamedelrehan/Ziti-HA-Test02/main/scripts/azure-bootstrap-ziti-ha-controller-primary-v4.sh
```

Set `repoRawBaseUrl` to:

```text
https://raw.githubusercontent.com/mohamedelrehan/Ziti-HA-Test02/main
```

## Validate after deployment

SSH to controller01 and run:

```bash
sudo -u ziti-controller ziti agent cluster list --timeout 30s
ziti edge login https://127.0.0.1:1280 -u admin -p '<zitiAdminPassword>' -y
ziti edge list edge-routers
```

Expected:

- 3 controllers connected.
- One controller leader.
- 3 routers online.

## Test02.2a fix
This package removes the ARM circular dependency reported by Azure. The intended order is:
1. All VMs are created.
2. Controller02/controller03/router extensions run as preparation only.
3. Controller01 extension runs as orchestrator after the preparation extensions exist, distributes shared PKI, creates controller cluster, creates router JWTs, and finalizes routers.
