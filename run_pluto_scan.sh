#!/usr/bin/env bash

#------------------------------------------------------------------------------

# Copyright 2024 Nutanix, Inc
#
# Licensed under the MIT License;
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”),
# to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#------------------------------------------------------------------------------

# Maintainer:   Eric De Witte (eric.dewitte@nutanix.com)
# Contributors: 

#------------------------------------------------------------------------------
#NKP Version array
declare -A nkp_to_k8s_version
nkp_to_k8s_version=(
  [v2.16.0]=v1.33.2
  [v2.15.1]=v1.32.3
  [v2.15.0]=v1.32.3
  [v2.14.2]=v1.31.9
  [v2.14.1]=v1.31.9
  [v2.14.0]=v1.31.4
  [v2.13.3]=v1.30.10
  [v2.13.2]=v1.30.10
  [v2.13.1]=v1.30.5
  [v2.13.0]=v1.30.3
  [v2.12.2]=v1.29.9
  [v2.12.1]=v1.29.9
  [v2.12.0]=v1.29.6
)

#------------------------------------------------------------------------------
version_gt() { 
  test "$(echo -e "$1\n$2" | sort -V | head -n1)" != "$1"
}
#------------------------------------------------------------------------------

#check if pluto cli is installed
if ! command -v pluto &> /dev/null; then
    echo "Pluto CLI is not installed. Please install it first."
    exit 1
fi
#check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo "kubectl is not installed. Please install it first."
    exit 1
fi

#select Cluster kubeconfig context
CONTEXTS=$(kubectl config get-contexts --output=name)
echo
echo "Select kubernetes cluster or CTRL-C to quit"
select CONTEXT in $CONTEXTS; do 
    echo "you selected cluster context : ${CONTEXT}"
    echo 
    CLUSTERCTX="${CONTEXT}"
    break
done

kubectl config use-context $CLUSTERCTX

#get the current kubernetes version
K8S_VERSION=$(kubectl version | grep "Server Version" | awk '{print $3}')
echo "Current Kubernetes version: ${K8S_VERSION}"

#Select desired NKP version
echo "Available NKP versions:"
for NKP_VERSION in "${!nkp_to_k8s_version[@]}"; do
    echo "- ${NKP_VERSION} (K8s version: ${nkp_to_k8s_version[$NKP_VERSION]})"
done
echo
select NKP_VERSION in "${!nkp_to_k8s_version[@]}"; do
    echo "You selected NKP version: ${NKP_VERSION}"
    NEW_K8S_VERSION=${nkp_to_k8s_version[$NKP_VERSION]}
    echo "Corresponding Kubernetes version: ${NEW_K8S_VERSION}"
    if version_gt "$K8S_VERSION" "$NEW_K8S_VERSION"; then
        echo "Warning: The selected NKP version (${NKP_VERSION}) is lower than the current Kubernetes version (${K8S_VERSION})."
        exit 1
    fi
    break
done

# Run Pluto scan
echo "Running Pluto scan for NKP version ${NKP_VERSION} on Kubernetes version ${K8S_VERSION}..."
pluto detect-all-in-cluster -o wide -t k8s="$NEW_K8S_VERSION"
if [ $? -ne 0 ]; then
    echo "Pluto scan failed. Please check the output for details."
    exit 1
fi
echo "Pluto scan completed successfully."
