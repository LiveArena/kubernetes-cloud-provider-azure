#!/usr/bin/env bash

# Copyright 2022 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o pipefail

REPO_ROOT=$(dirname "${BASH_SOURCE[0]}")/..
WORKLOAD_CLUSTER_TEMPLATE_DIR="${REPO_ROOT}/tests/k8s-azure/manifest/cluster-api"
MANAGEMENT_CLUSTER_NAME="${MANAGEMENT_CLUSTER_NAME:-capi}"
WORKLOAD_CLUSTER_TEMPLATE="${WORKLOAD_CLUSTER_TEMPLATE:-${WORKLOAD_CLUSTER_TEMPLATE_DIR}/vmss-multi-nodepool.yaml}"

: "${AZURE_SUBSCRIPTION_ID:?empty or not defined.}"
: "${AZURE_TENANT_ID:?empty or not defined.}"
: "${AZURE_CLIENT_ID:?empty or not defined.}"
: "${AZURE_CLIENT_SECRET:?empty or not defined.}"
: "${CLUSTER_NAME:?empty or not defined.}"
: "${AZURE_RESOURCE_GROUP:?empty or not defined}"

export AZURE_CLUSTER_IDENTITY_SECRET_NAME="${AZURE_CLUSTER_IDENTITY_SECRET_NAME:-cluster-identity-secret}"
export CLUSTER_IDENTITY_NAME="${CLUSTER_IDENTITY_NAME:-cluster-identity}"
export AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE="${AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE:-default}"
export CONTROL_PLANE_MACHINE_COUNT="${CONTROL_PLANE_MACHINE_COUNT:-1}"
export WORKER_MACHINE_COUNT="${WORKER_MACHINE_COUNT:-2}"
export AZURE_CONTROL_PLANE_MACHINE_TYPE="${AZURE_CONTROL_PLANE_MACHINE_TYPE:-Standard_D4s_v3}"
export AZURE_NODE_MACHINE_TYPE="${AZURE_NODE_MACHINE_TYPE:-Standard_D2s_v3}"
export AZURE_LOCATION="${AZURE_LOCATION:-westus2}"
export AZURE_CLOUD_CONTROLLER_MANAGER_IMG="${AZURE_CLOUD_CONTROLLER_MANAGER_IMG:-mcr.microsoft.com/oss/kubernetes/azure-cloud-controller-manager:v1.23.1}"
export AZURE_CLOUD_NODE_MANAGER_IMG="${AZURE_CLOUD_NODE_MANAGER_IMG:-mcr.microsoft.com/oss/kubernetes/azure-cloud-node-manager:v1.23.1}"
export KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.23.0}"
export EXP_MACHINE_POOL=true
export EXP_CLUSTER_RESOURCE_SET=true

export AZURE_LOADBALANCER_SKU="${AZURE_LOADBALANCER_SKU:-Standard}"
export ENABLE_MULTI_SLB="${ENABLE_MULTI_SLB:-false}"
export LB_BACKEND_POOL_CONFIG_TYPE="${LB_BACKEND_POOL_CONFIG_TYPE:-nodeIPConfiguration}"
export PUT_VMSS_VM_BATCH_SIZE="${PUT_VMSS_VM_BATCH_SIZE:-0}"

if [ "${AZURE_SSH_PUBLIC_KEY}" ]; then
  AZURE_SSH_PUBLIC_KEY_B64="$(echo -n "${AZURE_SSH_PUBLIC_KEY}" | base64 | tr -d '\n')"
  export AZURE_SSH_PUBLIC_KEY_B64
fi

source "${REPO_ROOT}/hack/ensure-kind.sh"
source "${REPO_ROOT}/hack/ensure-clusterctl.sh"

function init_and_wait_capz() {
  echo "Initializing CAPZ"
  kubectl create secret generic "${AZURE_CLUSTER_IDENTITY_SECRET_NAME}" --from-literal=clientSecret="${AZURE_CLIENT_SECRET}"
  "${CLUSTERCTL}" init --infrastructure azure
  echo "Waiting for the CAPZ components to be Ready"
  kubectl wait --for=condition=Available --timeout=5m -n capz-system deployment -l cluster.x-k8s.io/provider=infrastructure-azure
  sleep 10
  echo "CAPZ initialized"
}

# Create CAPZ management cluster by kind
function create_management_cluster() {
  unset KUBECONFIG
  if ! kubectl cluster-info --context=kind-"${MANAGEMENT_CLUSTER_NAME}"; then
    echo "Creating kind cluster"
    kind create cluster --name="${MANAGEMENT_CLUSTER_NAME}"
    echo "Waiting for the node to be Ready"
    kubectl wait node "${MANAGEMENT_CLUSTER_NAME}-control-plane" --for=condition=ready --timeout=90s --context=kind-"${MANAGEMENT_CLUSTER_NAME}"
    kubectl cluster-info --context=kind-"${MANAGEMENT_CLUSTER_NAME}"
    init_and_wait_capz
  else
    echo "Found management cluster, assuming the CAPZ has been initialized"
  fi
}

function create_workload_cluster() {
  if [ "${CUSTOMIZED_CLOUD_CONFIG_TEMPLATE}" ] && ! kubectl get secret "${CLUSTER_NAME}-control-plane-azure-json"; then
    echo "Creating customized cloud config file from ${CUSTOMIZED_CLOUD_CONFIG_TEMPLATE}"
    envsubst < "${CUSTOMIZED_CLOUD_CONFIG_TEMPLATE}" > tmp_azure_json
    kubectl create secret generic "${CLUSTER_NAME}-control-plane-azure-json" \
      --from-file=azure.json=tmp_azure_json \
      --from-file=control-plane-azure.json=tmp_azure_json \
      --from-file=worker-node-azure.json=tmp_azure_json \
      --context=kind-"${MANAGEMENT_CLUSTER_NAME}"
    rm tmp_azure_json
    kubectl --context=kind-"${MANAGEMENT_CLUSTER_NAME}" label secret "${CLUSTER_NAME}-control-plane-azure-json" "${CLUSTER_NAME}"=foo --overwrite
  else
    echo "Using default cloud config generated by CAPZ"
  fi

  echo "Creating workload cluster from ${WORKLOAD_CLUSTER_TEMPLATE}"
  echo "Using cloud-controller-manager image: ${AZURE_CLOUD_CONTROLLER_MANAGER_IMG}"
  echo "Using cloud-node-manager image: ${AZURE_CLOUD_NODE_MANAGER_IMG}"
  envsubst < "${WORKLOAD_CLUSTER_TEMPLATE}" | kubectl apply -f -

  echo "Waiting for the kubeconfig to become available"
  timeout --foreground 300 bash -c "while ! kubectl get secrets | grep ${CLUSTER_NAME}-kubeconfig; do sleep 1; done"
  if [ "$?" == 124 ]; then
    echo "Timeout waiting for the kubeconfig to become available, please check the logs of the capz controller to get the detailed error"
    return 124
  fi
  echo "Get kubeconfig and store it locally."
  kubectl --context=kind-"${MANAGEMENT_CLUSTER_NAME}" get secrets "${CLUSTER_NAME}"-kubeconfig -o json | jq -r .data.value | base64 --decode > ./"${CLUSTER_NAME}"-kubeconfig
  echo "Waiting for the control plane nodes to show up"
  timeout --foreground 600 bash -c "while ! kubectl --kubeconfig=./${CLUSTER_NAME}-kubeconfig get nodes | grep master; do sleep 1; done"
  if [ "$?" == 124 ]; then
    echo "Timeout waiting for the control plane nodes"
    return 124
  fi
  echo "Run \"kubectl --kubeconfig=./${CLUSTER_NAME}-kubeconfig ...\" to work with the new target cluster, It may cost up to several minutes until all agent nodes show up. After that, do not forget to install a network plugin to make all nodes Ready."
}

create_management_cluster
create_workload_cluster
