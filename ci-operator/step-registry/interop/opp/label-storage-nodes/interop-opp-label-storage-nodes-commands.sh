#!/bin/bash

set -euo pipefail

echo "Labeling worker nodes for ODF StorageCluster..."
oc label nodes cluster.ocs.openshift.io/openshift-storage="" --selector=node-role.kubernetes.io/worker --overwrite
echo "Node labeling complete."
