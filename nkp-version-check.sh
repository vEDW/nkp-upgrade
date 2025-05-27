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
version_gt() { 
  test "$(echo -e "$1\n$2" | sort -V | head -n1)" != "$1"
}
#------------------------------------------------------------------------------
#NKP Version array
declare -A nkp_to_k8s_version
nkp_to_k8s_version=(
  [v2.15.0]=v1.32.3
  [v2.14.0]=v1.31.4
  [v2.13.2]=v1.30.10
  [v2.13.1]=v1.30.5
  [v2.13.0]=v1.30.3
  [v2.12.2]=v1.29.9
  [v2.12.1]=v1.29.9
  [v2.12.0]=v1.29.6
)
#------------------------------------------------------------------------------

echo
echo "Checking nkp cli version..."
echo 
#check which version of nkp is installed
if ! command -v nkp &> /dev/null; then
    echo "nkp command not found. Please install nkp first."
    exit 1
fi
# Get the installed version of nkp
NKPVER=$(nkp version |grep nkp |awk '{print $2}')
echo "NKP cli version: $NKPVER"
CLIK8SVERSION=${nkp_to_k8s_version[$NKPVER]}
echo "  corresponding k8s version is : ${CLIK8SVERSION}"

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

#check if this is a NKP Management cluster
KOMANDERCRD=$(kubectl  api-resources |grep kommander)
if [[ -z "$KOMANDERCRD" ]]; then
    echo "This is not a NKP Management Cluster. Please select a valid management cluster."
    exit 1
fi
#get nkp management cluster version
NKPMGMTCLUSTER=$(kubectl get cluster -n default -o jsonpath='{.items[0].metadata.name}')
echo
echo "NKP Management Cluster name: $NKPMGMTCLUSTER"
#get provider
NKPPROVIDER=$(kubectl get cluster $NKPMGMTCLUSTER -n default -o json |jq -r '.metadata.labels."cluster.x-k8s.io/provider"')
echo "NKP Management Cluster Provider: $NKPPROVIDER"

KOMMANDERUPGRADEREQUIRED="false"
#Get the version of kommander
KOMMANDERVERSION=$(kubectl get hr -n kommander kommander-appmanagement -o jsonpath='{.spec.chart.spec.version}')
echo
echo "Kommander Version: $KOMMANDERVERSION"
#compare cli version with management cluster version
if [[ "$NKPVER" == "$KOMMANDERVERSION" ]]; then
    echo "  NKP CLI version matches Kommander version."
    echo "  Skip kommander upgrade"
    KOMMANDERFLUXVERSION=$(kubectl get appdeployments -n kommander kommander-flux |awk 'NR>1 {print $2}' |rev |cut -d"-" -f1|rev)
    echo "  Kommander Flux Version: $KOMMANDERFLUXVERSION"
else
    #check if cli version is higher than management cluster version 
    if version_gt "$NKPVER" "$KOMMANDERVERSION"; then
        echo "$NKPVER is higher than $KOMMANDERVERSION"
        echo "upgrade kommander is recommended."
        KOMMANDERUPGRADEREQUIRED="true"
    else
        echo "$KOMMANDERVERSION is higher than $v2"
        echo "upgrade NKP CLI is recommended."
    fi
fi
MGMTCLUSTERUPGRADEREQUIRED="false"
# Get the version of the kubernetes cluster
KUBERNETESVERSION=$(kubectl version | grep Server | awk '{print $3}')
echo
echo "NKP Management Cluster Kubernetes Version: $KUBERNETESVERSION"
# Check if the kubernetes version is compatible with the nkp version

if [[ "$CLIK8SVERSION"  == "$KUBERNETESVERSION" ]]; then
    echo "  NKP CLI k8s version matches Mgmt cluster k8s version."
    echo "  Skip Mgmt cluster kubernetes upgrade"
else
    #check if cli version is higher than management cluster version 
    if version_gt "$CLIK8SVERSION" "$KUBERNETESVERSION"; then
        echo "  $CLIK8SVERSION is higher than $KUBERNETESVERSION"
        echo "  upgrade mgmt cluster is recommended."
        MGMTCLUSTERUPGRADEREQUIRED="true"
    else
        echo "  $KUBERNETESVERSION is higher than $CLIK8SVERSION"
        echo "  upgrade NKP CLI is recommended."
    fi
fi

#------------------------------------------------------------------------------
# Check workspace application versions

#check NKP edition
LICENSECRD=$(kubectl get licenses -n kommander -o json |jq -r '.items[].status.dkpLevel')
echo
echo "NKP Edition: $LICENSECRD"
echo

WKSPACEUPGRADEREQUIRED=0
# Get the list of workspaces
WORKSPACES=$(kubectl get workspaces -o json |jq -r '["workspace","namespace","version" ], (.items[]|[.metadata.name,.spec.namespaceName,.status.version])|@tsv' |column -t)
echo "Workspaces:"
echo
echo "$WORKSPACES"
echo
# Get the version of each workspace
for WORKSPACE in $(echo "$WORKSPACES" | awk 'NR>1 {print $1}'); do
    WORKSPACENS=$(echo "$WORKSPACES" |grep $WORKSPACE | awk '{print $2}')
    WORKSPACEVERSION=$(kubectl get appdeployments -n $WORKSPACENS kommander-flux |awk 'NR>1 {print $2}' |rev |cut -d"-" -f1|rev)
    echo "  Workspace: $WORKSPACE, Version: $WORKSPACEVERSION"
    # Check if the workspace version is compatible with the nkp version
    if [[ "$KOMMANDERFLUXVERSION" == "$WORKSPACEVERSION" ]]; then
        echo "      NKP Platform app version matches Workspace version."
        echo "      Skip workspace upgrade"
    else
        #check if cli version is higher than workspace version 
        if version_gt "$KOMMANDERFLUXVERSION" "$WORKSPACEVERSION"; then
            echo "      $KOMMANDERFLUXVERSION is higher than $WORKSPACEVERSION"
            echo "      upgrade workspace is recommended."
            #increase the upgrade required counter
            WKSPACEUPGRADEREQUIRED=$((WKSPACEUPGRADEREQUIRED + 1))
        else
            echo "      $WORKSPACEVERSION is higher than $KOMMANDERFLUXVERSION"
            echo "      upgrade NKP CLI is recommended."
        fi
    fi
done


#------------------------------------------------------------------------------
# Check workload clusters
WORKLOADCLUSTERS=$(kubectl get cluster -A |grep -v default)
echo
echo "Workload Clusters:"
echo
echo "$WORKLOADCLUSTERS"
echo
WKCLUSTERUPGRADEREQUIRED=0

# Get the version of each workload cluster
for WKCLUSTER in $(echo "$WORKLOADCLUSTERS" | awk 'NR>1 {print $2}'); do
    CLUSTERNAMESPACE=$(echo "$WORKLOADCLUSTERS" |grep $WKCLUSTER | awk '{print $1}')
    KUBERNETESVERSION=$(kubectl get cluster $WKCLUSTER -n $CLUSTERNAMESPACE -o json | jq -r '.spec.topology.version')
    echo "  Workload Cluster: $WKCLUSTER, namespace: $CLUSTERNAMESPACE, Version: $WORKLOADCLUSTERVERSION"
    echo "      Kubernetes Version: $KUBERNETESVERSION"
    # Check if the kubernetes version is compatible with the nkp version

    if [[ "$CLIK8SVERSION"  == "$KUBERNETESVERSION" ]]; then
        echo "  NKP CLI k8s version matches Mgmt cluster k8s version."
        echo "  Skip cluster kubernetes upgrade"
    else
        #check if cli version is higher than management cluster version 
        if version_gt "$CLIK8SVERSION" "$KUBERNETESVERSION"; then
            echo "      $CLIK8SVERSION is higher than $KUBERNETESVERSION"
            echo "      upgrade cluster is recommended."
            #increase the upgrade required counter
            WKCLUSTERUPGRADEREQUIRED=$((WKCLUSTERUPGRADEREQUIRED + 1))
            #Get the provider for each workload cluster
            WKCLUSTERJSON=$(kubectl get cluster $WKCLUSTER -n $CLUSTERNAMESPACE -o json)
            WORKLOADCLUSTERPROVIDER=$(echo "${WKCLUSTERJSON}" | jq -r '.metadata.labels."cluster.x-k8s.io/provider"')
            # need to expand for non nutanix providers
            case $WORKLOADCLUSTERPROVIDER in
                "nutanix")
                    echo "      Nutanix provider: $WORKLOADCLUSTERPROVIDER"
                    #get the machine image version
                    NKPCPIMAGE=$(echo "${WKCLUSTERJSON}" |jq -r '.spec.topology.variables[].value.controlPlane.nutanix.machineDetails.image.name')
                    echo "      Nutanix Control Plane Image: $NKPCPIMAGE"
                    #get the worker image version
                    #need to create loop if more than 1 machineDeployment
                    WKRIMAGE=$(echo "${WKCLUSTERJSON}" |jq -r '.spec.topology.workers.machineDeployments[].variables.overrides[].value.nutanix.machineDetails.image.name')
                    echo "      Nutanix Worker Image: $WKRIMAGE"
                    ;;
                *)
                    echo "      other provider: $WORKLOADCLUSTERPROVIDER"
                    exit 1
                    ;;
            esac
            echo
        else
            echo "$KUBERNETESVERSION is higher than $CLIK8SVERSION"
            echo "upgrade NKP CLI is recommended."
        fi
    fi
done

# print summary
echo
echo "Summary:"
echo "  NKP CLI Version: $NKPVER"
echo "  NKP Management Cluster: $NKPMGMTCLUSTER"
echo "  NKP Edition: $LICENSECRD"
echo "  NKP Management Cluster Provider: $NKPPROVIDER"
echo "  NKP Management Cluster Kubernetes Version: $KUBERNETESVERSION"
echo "  ========================================================="
if [[ "$KOMMANDERUPGRADEREQUIRED" == "true" ]]; then
    echo "  Upgrade Kommander is required."
#else
#    echo "  No Kommander upgrade required."
fi
if [[ "$MGMTCLUSTERUPGRADEREQUIRED" == "true" ]]; then
    echo "  Upgrade Management Cluster is required."
#else
#    echo "  No Management Cluster upgrade required."
fi
if [[ "$WKSPACEUPGRADEREQUIRED" -gt 0 ]]; then
    echo "  $WKSPACEUPGRADEREQUIRED Workspaces Upgrade required."
#else
#    echo "  No Workspace upgrade required."
fi
if [[ "$WKCLUSTERUPGRADEREQUIRED" -gt 0 ]]; then
    echo "  $WKCLUSTERUPGRADEREQUIRED Workload Clusters Upgrade required."
#else
#    echo "  No Workload Cluster upgrade required."
fi
echo "  ========================================================="
echo

