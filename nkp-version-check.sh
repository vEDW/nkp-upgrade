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

echo "Checking nkp version..."
#check which version of nkp is installed
if ! command -v nkp &> /dev/null; then
    echo "nkp command not found. Please install nkp first."
    exit 1
fi
# Get the installed version of nkp
NKPVER=$(nkp version |grep nkp |awk '{print $2}')
echo "Installed nkp version: $NKPVER"

#Select management cluster kubectl context
if ! command -v kubectl &> /dev/null; then
    echo "kubectl command not found. Please install kubectl first."
    exit 1
fi
#select NKP Management Cluster kubeconfig context
CONTEXTS=$(kubectl config get-contexts --output=name)
echo
echo "Select management cluster or CTRL-C to quit"
select CONTEXT in $CONTEXTS; do 
    echo "you selected cluster context : ${CONTEXT}"
    echo 
    CLUSTERCTX="${CONTEXT}"
    break
done

kubectl config use-context $CLUSTERCTX

#get nkp management cluster version
NKPMGMTCLUSTER=$(kubectl get cluster -n default -o jsonpath='{.items[0].metadata.name}')
echo "Nkp Management Cluster: $NKPMGMTCLUSTER"
#get provider
NKPPROVIDER=$(kubectl get cluster $NKPMGMTCLUSTER -n default -o json |jq -r '.metadata.labels."cluster.x-k8s.io/provider"')
echo "Nkp Management Cluster Provider: $NKPPROVIDER"

#Get the version of kommander
KOMMANDERVERSION=$(kubectl get hr -n kommander kommander-appmanagement -o jsonpath='{.spec.chart.spec.version}')
echo "Kommander Version: $KOMMANDERVERSION"

# Get the version of the kubernetes cluster
KUBERNETESVERSION=$(kubectl version | grep Server | awk '{print $3}')
echo "Kubernetes Version: $KUBERNETESVERSION"

#List workload clusters
WORKLOADCLUSTERS=$(kubectl get cluster -A |grep -v default)
echo "Workload Clusters:"
echo "$WORKLOADCLUSTERS"
echo

# Get the version of each workload cluster
for WKCLUSTER in $(echo "$WORKLOADCLUSTERS" | awk 'NR>1 {print $2}' | tail -n +2); do
    CLUSTERNAMESPACE=$(echo "$WORKLOADCLUSTERS" |grep $WKCLUSTER | awk '{print $1}')
    WORKLOADCLUSTERVERSION=$(kubectl get cluster $WKCLUSTER -n $CLUSTERNAMESPACE -o json | jq -r '.spec.topology.version')
    echo "Workload Cluster: $WKCLUSTER, namespace: $CLUSTERNAMESPACE, Version: $WORKLOADCLUSTERVERSION"

    #Get the provider for each workload cluster
    WKCLUSTERJSON=$(kubectl get cluster $WKCLUSTER -n $CLUSTERNAMESPACE -o json)
    WORKLOADCLUSTERPROVIDER=$(echo "${WKCLUSTERJSON}" | jq -r '.metadata.labels."cluster.x-k8s.io/provider"')
    # need to expand for non nutanix providers
    select case $WORKLOADCLUSTERPROVIDER in
        "nutanix")
            echo "  Nutanix provider: $WORKLOADCLUSTERPROVIDER"
            #get the machine image version
            NKPCPIMAGE=$(echo "${WKCLUSTERJSON}" |jq -r '.spec.topology.variables[].value.controlPlane.nutanix.machineDetails.image.name')
            echo "  Nutanix Control Plane Image: $NKPCPIMAGE"
            #get the worker image version
            #need to create loop if more than 1 machineDeployment
            WKRIMAGE=$(echo "${WKCLUSTERJSON}" |jq -r '.spec.topology.workers.machineDeployments[].variables.overrides[].value.nutanix.machineDetails.image.name')
            echo "  Nutanix Worker Image: $WKRIMAGE"
            ;;
        *)
            echo "  other provider: $WORKLOADCLUSTERPROVIDER"
            exit 1
            ;;
    esac
    echo
done

