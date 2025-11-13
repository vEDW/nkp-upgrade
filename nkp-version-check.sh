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

version_delta_check() {
  # Function to check if the version is greater than or equal to the specified version
  STARTVERSION="$1"
  ENDVERSION="$2"
  STARTMINOR=$(echo "$STARTVERSION" | cut -d'.' -f2)
  ENDMINOR=$(echo "$ENDVERSION" | cut -d'.' -f2)
  # Delta version check
  DELTA=$(( ENDMINOR - STARTMINOR ))
  #absolute value of delta
  DELTA=${DELTA#-}
  if [[ $DELTA -ge 2 ]]; then
    echo "  🛑  ALERT: The NKP / kubernetes version difference is greater than or equal to 2. Please check the NKP/K8S upgrade documentation."
    echo "      NKP/K8S upgrade only supports 1 version difference (N-1 -> N)."
    DELTAERROR="true"
  else
    echo "  ✅  The delta version is $DELTA, which is less than 2."
  fi

}

get_nkp_nx_images() {
    # Function to get the list of available Nutanix NX images
    #get available images from PC
    export PCIPADDRESS=$(echo "$WKCLUSTERJSON" |jq -r '.spec.topology.variables[].value.nutanix.prismCentralEndpoint.url' |sed 's\https://\\g' |sed 's\:9440\\g' )
    PCSECRET=$(echo "$WKCLUSTERJSON" |jq -r '.spec.topology.variables[].value.nutanix.prismCentralEndpoint.credentials.secretRef.name' |xargs -I {} kubectl get secret {} -n $CLUSTERNAMESPACE -o json |jq -r '.data.credentials'|base64 -d)
    export PCADMIN=$(echo "$PCSECRET" |jq -r '.[].data.prismCentral.username')
    export PCPASSWD=$(echo "$PCSECRET" |jq -r '.[].data.prismCentral.password')
    source ./functions/fct_nutanix-pc_rest_api_v4_curl.sh
    IMAGESCOUNT=$(get_images_filter "contains(name,'$SHORTCLIK8SVERSION')" |jq '.data |length' )
    if [[ "$IMAGESCOUNT" -eq 0 ]]; then
        echo 
        echo "  No Nutanix images found for k8s version $SHORTCLIK8SVERSION"
        return
    fi
    IMAGES=$(get_images_filter "contains(name,'$SHORTCLIK8SVERSION')" |jq -r '.data[].name')
    if [[ -z "$IMAGES" ]]; then
        echo 
        echo "  No Nutanix images found for k8s version $SHORTCLIK8SVERSION"
        return
    fi  
    # Loop through the images and print them
    echo "      Nutanix Images for k8s version $SHORTCLIK8SVERSION:"
    for IMAGE in $IMAGES; do
            echo "          - $IMAGE"
    done
}

get_nkp_vsphere_images() {
    # Function to get the list of available vSphere Template images
    
#TO DO  : check ClusterResourceSet for secretRef
#    CREDSECRET=$(echo "$WKCLUSTERJSON" |jq -r '.spec.topology.variables[].value.nutanix.prismCentralEndpoint.credentials.secretRef.name' |xargs -I {} kubectl get secret {} -n $CLUSTERNAMESPACE -o json |jq -r '.data.credentials'|base64 -d)

    export GOVC_URL=$(echo "$CREDSECRET")
    export GOVC_USERNAME=$(echo "$CREDSECRET" |jq -r '.[].data.vsphere.username')
    export GOVC_PASSWORD=$(echo "$CREDSECRET" |jq -r '.[].data.vsphere.password')

    IMAGES=$(govc find $GOVC_DATACENTER -type m |xargs govc vm.info -json  |jq -r '.virtualMachines[]|select (.config.template == true ) |.name' |grep $SHORTCLIK8SVERSION)

    if [[ -z "$IMAGES" ]]; then
        echo 
        echo "  No vSphere template found for k8s version $SHORTCLIK8SVERSION"
    else
        # Loop through the images and print them
        echo "vSphere Templates for k8s version $SHORTCLIK8SVERSION:"
        for IMAGE in $IMAGES; do
                echo "          - $IMAGE"
        done
    fi
}

get_cluster_k8s_version() {
    # Function to get the Kubernetes version from a specific cluster
    CLUSTER_NAME="$1"
    #Get namespace from cluster name
    WORKLOADCLUSTERSJSON=$(kubectl get clusters.cluster.x-k8s.io -A -o json)
    CLUSTERNAMESPACE=$(echo "${WORKLOADCLUSTERSJSON}" | jq --arg WKCLUSTER "$CLUSTER_NAME" -r '.items[].metadata |select (.name ==  $WKCLUSTER) |.namespace')

    if [[ -z "$CLUSTERNAMESPACE" ]]; then
        echo "Namespace not found for cluster $CLUSTER_NAME. Please check the cluster object."
        return 1
    fi
    # try cluster spec.version first
    KUBERNETESVERSION=$(kubectl get clusters.cluster.x-k8s.io $CLUSTER_NAME -n $CLUSTERNAMESPACE -o jsonpath='{.spec.topology.version}')
    if [[ -z "$KUBERNETESVERSION" ]]; then
        # if spec.version is empty, try kubeadmcontrolplane.spec.version
        KADMCPJSON=$(kubectl get kubeadmcontrolplanes -A -o json)
        KUBERNETESVERSION=$(echo "$KADMCPJSON" |jq --arg WKCLUSTER "$CLUSTER_NAME" -r '.items[] |select(.metadata.labels."cluster.x-k8s.io/cluster-name" == $WKCLUSTER) |.spec.version')
        if [[ -z "$KUBERNETESVERSION" ]]; then
            echo "Kubernetes version not found for cluster $CLUSTER_NAME. Please check the cluster object."
            return 1
        fi
    fi
}

#------------------------------------------------------------------------------
# #NKP Version array
declare -A nkp_to_k8s_version
nkp_to_k8s_version=(
  [v2.16.1]=v1.33.5
  [v2.16.0]=v1.33.2
  [v2.15.2]=v1.32.8
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
# Reset VARIABLES

DELTAERROR="false"
NUTANIXIMAGEMISSING="false"
MACHINEVERSIONSALERT="false"
#------------------------------------------------------------------------------

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
SHORTCLIK8SVERSION=$(echo $CLIK8SVERSION |sed 's/v//')

echo "  corresponding k8s version is : ${CLIK8SVERSION}"

#check if this is a NKP Management cluster
KOMANDERCRD=$(kubectl  api-resources |grep cluster.x-k8s.io)
if [[ -z "$KOMANDERCRD" ]]; then
    echo "This is not a NKP Management Cluster. Please select a valid management cluster."
    exit 1
fi
#get nkp management cluster version
NKPMGMTCLUSTER=$(kubectl get clusters.cluster.x-k8s.io -n default -o jsonpath='{.items[0].metadata.name}')
echo
echo "NKP Management Cluster name: $NKPMGMTCLUSTER"
#get provider
NKPPROVIDER=$(kubectl get clusters.cluster.x-k8s.io $NKPMGMTCLUSTER -n default -o json |jq -r '.metadata.labels."konvoy.d2iq.io/provider"')
echo "NKP Management Cluster Provider: $NKPPROVIDER"

KOMMANDERUPGRADEREQUIRED="false"
#Get the version of kommander using HelmRelease (for NKP <2.16)
KOMMANDERVERSION=$(kubectl get hr -n kommander kommander-appmanagement -o jsonpath='{.spec.chart.spec.version}')
#check if field empty
if [[ -z "$KOMMANDERVERSION" ]]; then
    echo "Kommander version not found. Please check if Kommander is installed."
    KOMMANDERVERSION="Kommander not found"
fi
#Get the version of kommander using OciRepo (for NKP >= 2.16)
#check if KOMMANDERVERSION is empty
if [[ "$KOMMANDERVERSION" == "Kommander not found" ]]; then
    KOMMANDERVERSION=$(kubectl get ocirepositories -n kommander kommander-appmanagement-chart -o jsonpath='{.spec.ref.tag}')
    if [[ -z "$KOMMANDERVERSION" ]]; then
        echo "Kommander version not found. Please check if Kommander is installed."
        KOMMANDERVERSION="Kommander not found"
    fi  
fi

#Check if Kommanderversion is still empty
if [[ "$KOMMANDERVERSION" == "Kommander not found" ]]; then
    KOMMANDERFLUXVERSION="Kommander not found"
    echo "Kommander is not installed. Skipping workspace version check."
else
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
                version_delta_check "$NKPVER" "$KOMMANDERVERSION"
            else
                echo "$KOMMANDERVERSION is higher than $v2"
                echo "upgrade NKP CLI is recommended."
            fi
        fi
fi

MGMTCLUSTERUPGRADEREQUIRED="false"
# Get the version of the kubernetes cluster
MGMTKUBERNETESVERSION=$(kubectl version | grep Server | awk '{print $3}')
echo
echo "NKP Management Cluster Kubernetes Version: $MGMTKUBERNETESVERSION"
# Check if the kubernetes version is compatible with the nkp version

if [[ "$CLIK8SVERSION"  == "$MGMTKUBERNETESVERSION" ]]; then
    echo "  NKP CLI k8s version matches Mgmt cluster k8s version."
    echo "  Skip Mgmt cluster kubernetes upgrade"
else
    #check if cli version is higher than management cluster version 
    if version_gt "$CLIK8SVERSION" "$MGMTKUBERNETESVERSION"; then
        echo "  $CLIK8SVERSION is higher than $MGMTKUBERNETESVERSION"
        echo "  upgrade mgmt cluster is recommended."
        MGMTCLUSTERUPGRADEREQUIRED="true"

    else
        echo "  $MGMTKUBERNETESVERSION is higher than $CLIK8SVERSION"
        echo "  upgrade NKP CLI is recommended."
    fi
fi

#------------------------------------------------------------------------------
# Check workspace application versions
WKSPACEUPGRADEREQUIRED=0
#skip if kommander is not installed
if [[ "$KOMMANDERVERSION" == "Kommander not found" ]]; then
    echo "Kommander is not installed. Skipping workspace version check."
else
    #check NKP edition
    LICENSECRD=$(kubectl get licenses -n kommander -o json |jq -r '.items[].status.dkpLevel')
    #check if license is empty
    if [[ -z "$LICENSECRD" ]]; then
        echo "No license found. Please check if the license is installed."
        LICENSECRD="No License found"
    else
        echo
        echo "NKP Edition: $LICENSECRD"
        echo
    fi
    # Get the list of workspaces
    WORKSPACES=$(kubectl get workspaces -o json |jq -r '["workspace","namespace","version" ], (.items[]|[.metadata.name,.spec.namespaceName,.status.version])|@tsv' |column -t)
    echo "Workspaces:"
    echo
    echo "$WORKSPACES"
    echo
    # Get the version of each workspace
    for WORKSPACE in $(echo "$WORKSPACES" | awk 'NR>1 {print $1}'); do
        WORKSPACENS=$(echo "$WORKSPACES" |grep $WORKSPACE | awk '{print $2}')
        WORKSPACEVERSION=""
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
fi

#------------------------------------------------------------------------------
# Check workload clusters
WKCLUSTERUPGRADEREQUIRED=0
WORKLOADCLUSTERSJSON=$(kubectl get clusters.cluster.x-k8s.io -A -o json)
KADMCPJSON=$(kubectl get kubeadmcontrolplanes -A -o json)


if [[ $MGMTCLUSTERUPGRADEREQUIRED = "true" ]]; then
    WORKLOADCLUSTERS=$(echo "${WORKLOADCLUSTERSJSON}" | jq -r '.items[].metadata.name')
else
    WORKLOADCLUSTERS=$(echo "${WORKLOADCLUSTERSJSON}" | jq -r '.items[].metadata|select(.namespace != "default")|.name')
fi

#check if workload clusters are found
if [[ -z "$WORKLOADCLUSTERS" ]]; then
    echo
    echo "No workload clusters found."
else
    echo
    echo "Workload Clusters:"
    echo
    # Get the version of each workload cluster
    for WKCLUSTER in $WORKLOADCLUSTERS; do
        CLUSTERNAMESPACE=$(echo "${WORKLOADCLUSTERSJSON}" | jq --arg WKCLUSTER "$WKCLUSTER" -r '.items[].metadata |select (.name ==  $WKCLUSTER) |.namespace')
        #KUBERNETESVERSION=$(echo "$KADMCPJSON" |jq --arg WKCLUSTER "$WKCLUSTER" -r '.items[] |select(.metadata.labels."cluster.x-k8s.io/cluster-name" == $WKCLUSTER) |.spec.version')
        get_cluster_k8s_version "$WKCLUSTER"
        #check if kubernetes version is empty
        if [[ -z "$KUBERNETESVERSION" ]]; then
            echo "Kubernetes version not found for workload cluster $WKCLUSTER. Please check cluster object for spec.version."
            echo "  Workload Cluster: $WKCLUSTER, namespace: $CLUSTERNAMESPACE"
        else
            echo "  Workload Cluster: $WKCLUSTER, namespace: $CLUSTERNAMESPACE, Kubernetes Version: $KUBERNETESVERSION"
        fi
        #Check machine versions match cluster version
        MACHINEJSON=$(kubectl get machine -l "cluster.x-k8s.io/cluster-name"=$WKCLUSTER -n $CLUSTERNAMESPACE -o json)
        MACHINEVERSIONS=$(echo "$MACHINEJSON" |jq -r '.items[]|.spec.version' |uniq)
        if [[ -z "$MACHINEVERSIONS" ]]; then
            echo "      No machine versions found for workload cluster $WKCLUSTER. Please check machine objects."
        else
            echo "      Machine Versions: $MACHINEVERSIONS"
            #if more than 1 machine version found, check if they match
            if [[ $(echo "$MACHINEVERSIONS" | wc -l) -gt 1 ]]; then
                echo "          ⚠️  Warning: More than 1 machine version found for workload cluster $WKCLUSTER. Please check machine objects."
            else
            #check if machine version = cluster version
                if [[ "$KUBERNETESVERSION" != "$MACHINEVERSIONS" ]]; then
                    echo "          ⚠️  Warning: Machine version $MACHINEVERSIONS does not match cluster version $KUBERNETESVERSION. Please check machine objects."
                else
                    echo "          ✅  Machine version matches cluster version."
                fi
            fi
        fi

        if [[ "$CLIK8SVERSION"  == "$KUBERNETESVERSION" ]]; then
            echo "    NKP CLI k8s version matches workload cluster k8s version."
            echo "    Skip cluster kubernetes upgrade"
            echo
        else
            #check if cli version is higher than management cluster version 
            if version_gt "$CLIK8SVERSION" "$KUBERNETESVERSION"; then
                echo "      $CLIK8SVERSION is higher than $KUBERNETESVERSION"
                echo "      upgrade cluster is recommended."
                #increase the upgrade required counter
                WKCLUSTERUPGRADEREQUIRED=$((WKCLUSTERUPGRADEREQUIRED + 1))
                #Get the provider for each workload cluster
                WKCLUSTERJSON=$(kubectl get cluster $WKCLUSTER -n $CLUSTERNAMESPACE -o json)
                WORKLOADCLUSTERPROVIDER=$(echo "${WKCLUSTERJSON}"  |jq -r '.metadata.labels."konvoy.d2iq.io/provider"')
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
                        echo
                        NKPIMAGES=$(get_nkp_nx_images)
                        if [[ -z "$NKPIMAGES" ]]; then
                            echo
                            echo "  ⚠️  No Nutanix images found for k8s version $SHORTCLIK8SVERSION"
                            echo "      Please download or create NKP OS images for k8s version $SHORTCLIK8SVERSION" 
                            NUTANIXIMAGEMISSING="true"
                        else
                            echo "$NKPIMAGES"
                        fi
                        ;;
                    "vsphere")
                        echo "      vsphere provider: $WORKLOADCLUSTERPROVIDER"
                        echo "      vSphere Machine Templates:"

                        kubectl get vspheremachinetemplates -n $CLUSTERNAMESPACE  -o json |jq --arg WKCLUSTER "$WKCLUSTER" -r '.items[]|select(.metadata.ownerReferences[].name == $WKCLUSTER)|[.metadata.name, .spec.template.spec.template]|@tsv' |column -t

                        ;;
                    *)
                        echo "      other provider: $WORKLOADCLUSTERPROVIDER"
                        ;;
                esac
                echo
            else
                echo "$KUBERNETESVERSION is higher than $CLIK8SVERSION"
                echo "upgrade NKP CLI is recommended."
            fi
        fi
    done
fi

echo
echo "Summary:"
echo
echo "  ========================================================="
echo "  NKP CLI Version: $NKPVER"
echo "  NKP Kommander Version: $KOMMANDERVERSION"
echo "  NKP Management Cluster: $NKPMGMTCLUSTER"
echo "  NKP Edition: $LICENSECRD"
echo "  NKP Management Cluster Provider: $NKPPROVIDER"
echo "  NKP Management Cluster Kubernetes Version: $MGMTKUBERNETESVERSION"
echo "  ========================================================="
UPGRADEREQ="false"

if [[ "$DELTAERROR" == "true" ]]; then
    echo "  🛑  ALERT: The NKP / kubernetes version difference is greater than or equal to 2. Please check the NKP/K8S upgrade documentation."
    echo "  ========================================================="
    exit 1
fi
if [[ "$KOMMANDERVERSION" == "Kommander not found" ]]; then
    echo "  Kommander is not installed. Skipping Kommander upgrade."
else
    if [[ "$KOMMANDERUPGRADEREQUIRED" == "true" ]]; then
        echo "  ⚠️  Upgrade Kommander is required."
        UPGRADEREQ="true"
    fi
fi
if [[ "$MGMTCLUSTERUPGRADEREQUIRED" == "true" ]]; then
    echo "  ⚠️  Upgrade Management Cluster is required."
        UPGRADEREQ="true"
fi
if [[ "$KOMMANDERVERSION" != "Kommander not found" ]]; then
    if [[ "$WKSPACEUPGRADEREQUIRED" -gt 0 ]]; then
        echo "  ⚠️  $WKSPACEUPGRADEREQUIRED Workspaces Upgrade required."
        UPGRADEREQ="true"
    fi
fi
if [[ "$WKCLUSTERUPGRADEREQUIRED" -gt 0 ]]; then
    echo "  ⚠️  $WKCLUSTERUPGRADEREQUIRED Workload Clusters Upgrade required."
    UPGRADEREQ="true"
fi

if [[ "$NUTANIXIMAGEMISSING" == "true" ]]; then
    echo "  🛑  ALERT:  Nutanix images for k8s version $SHORTCLIK8SVERSION are missing."
    echo "      Please download or create NKP OS images for k8s version $SHORTCLIK8SVERSION"
    UPGRADEREQ="true"
fi

if [[ "$UPGRADEREQ" != "true" ]]; then
    echo "✅  No upgrades required."
fi
echo "  ========================================================="
echo

