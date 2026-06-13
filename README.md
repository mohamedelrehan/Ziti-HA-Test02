# Ziti HA Test02.2b - Azure Portal Template

This package is aligned for a GitHub repository where all files are in the repository root, not in a `scripts/` folder.

## Important parameter

Set `repoRawBaseUrl` to:

```text
https://raw.githubusercontent.com/mohamedelrehan/Ziti-HA-Test02/main
```

The template downloads these root-level files:

```text
/azure-bootstrap-ziti-ha-controller-primary-v4.sh
/azure-bootstrap-ziti-ha-controller-secondary-v4.sh
/azure-bootstrap-ziti-ha-router-v4.sh
```

## Files to upload to repo root

Upload these files directly to the root of `Ziti-HA-Test02`:

- `azuredeploy.json`
- `azuredeploy.parameters.json`
- `azure-bootstrap-ziti-ha-controller-primary-v4.sh`
- `azure-bootstrap-ziti-ha-controller-secondary-v4.sh`
- `azure-bootstrap-ziti-ha-router-v4.sh`
- `README.md`

## Deploy

Use `azuredeploy.json` in Azure Portal > Deploy a custom template.

Use a clean resource group for the next test to avoid stale CustomScript extension state.
