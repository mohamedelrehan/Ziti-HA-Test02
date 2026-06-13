#!/usr/bin/env bash
set -Eeuo pipefail
echo "Controller:"
echo "sudo /opt/ziti-ha-test02/check-controller.sh"
echo "ziti edge login https://localhost:1280 -u admin"
echo "ziti edge list edge-routers"
echo "ziti fabric list routers"
echo
echo "Router:"
echo "sudo /opt/ziti-ha-test02/check-router.sh"
