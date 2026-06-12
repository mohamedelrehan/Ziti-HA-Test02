#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== HA Test02 validation commands ==="
echo
echo "On controller01:"
echo "  ziti edge login https://localhost:1280 -u admin"
echo "  ziti edge list edge-routers"
echo "  ziti fabric list routers"
echo
echo "On each controller:"
echo "  sudo /opt/ziti-ha-test02/check-controller.sh"
echo
echo "On each router:"
echo "  sudo /opt/ziti-ha-test02/check-router.sh"
