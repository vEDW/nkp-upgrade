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
#Functions

get_vsphere_template_images() {
    # Function to get the images used in the workload cluster
    # This function is called by the main script to retrieve and display the images
    
    #input params : desired kubernetes version.
    K8SVER=$1
    if [[ -z "$K8SVER" ]]; then
        echo "Usage: $0 <desired-kubernetes-version>"
        exit 1
    fi
    echo "Retrieving vsphere templates for workload cluster: $WKCLUSTER"
    if ! command -v govc &> /dev/null; then
    echo "govc command not found. Please install govc to use this script."
    exit 1
    fi
    echo
    echo "Select VM template to build NKP cluster with:"
    VMSLIST=$(govc find $GOVC_DATACENTER -type m |xargs govc vm.info -json  |jq -r '.virtualMachines[]|select (.config.template == true ) |.name')
    #check if there are any templates available
    if [[ -z "$VMSLIST" ]]; then
        echo "No VM templates found in datacenter ${DATACENTER}. Exiting."
        exit 1
    fi
    select template in $VMSLIST; do
    #    template=$(echo $template | sed "s#$GOVC_DATACENTER/vm/##")
        echo "you selected template : ${template}"
        echo
        break
    done
}

#------------------------------------------------------------------------------
# script parameters:
# $1: Workload Cluster Name

WKCLUSTER=$1

CLUSTERNAMESPACE=$(kubectl get cluster -A |grep $WKCLUSTER |awk '{print $1}')
if [[ -z "$CLUSTERNAMESPACE" ]]; then
    echo "Workload cluster $WKCLUSTER not found."
    exit 1
fi
WKCLUSTERJSON=$(kubectl get cluster $WKCLUSTER -n $CLUSTERNAMESPACE -o json)
WORKLOADCLUSTERPROVIDER=$(echo "${WKCLUSTERJSON}"  |jq -r '.metadata.labels."konvoy.d2iq.io/provider"')
# need to expand for non nutanix providers
case $WORKLOADCLUSTERPROVIDER in
    "nutanix")
        #get the machine image version
        NKPCPIMAGE=$(echo "${WKCLUSTERJSON}" |jq -r '.spec.topology.variables[].value.controlPlane.nutanix.machineDetails.image.name')
        echo "      Nutanix Control Plane Image: $NKPCPIMAGE"
        #need to create loop if more than 1 machineDeployment
        WKRIMAGE=$(echo "${WKCLUSTERJSON}" |jq -r '.spec.topology.workers.machineDeployments[].variables.overrides[].value.nutanix.machineDetails.image.name')
        echo "      Nutanix Worker Image: $WKRIMAGE"
        ;;
    "vsphere")
        #get the machine image version
        MACHINETEMPLATES=$(kubectl get vspheremachinetemplate -n $CLUSTERNAMESPACE  --no-headers |grep $WKCLUSTER)
        if [[ -z "$MACHINETEMPLATES" ]]; then
            echo "No vSphere Machine Template found for workload cluster $WKCLUSTER."
            exit 1
        fi
        CPTEMPLATEJSON=$(echo "$MACHINETEMPLATES" |grep control-plane |awk '{print $1}' |xargs -I {} kubectl get vspheremachinetemplate {} -n $CLUSTERNAMESPACE -o json)
        VSPHERECPIMAGE=$(echo "${CPTEMPLATEJSON}" |jq -r '.spec.template.spec.template')
        echo "      vSphere Control Plane Image: $VSPHERECPIMAGE"
        #get the worker image version
        MDNAME=$(kubectl get machinedeployment -n $CLUSTERNAMESPACE  --no-headers |grep $WKCLUSTER |awk '{print $1}')
        if [[ -z "$MDNAME" ]]; then
            echo "No Machine Deployment found for workload cluster $WKCLUSTER."
            exit 1
        fi
        WKMACHINETEMPLATES=$(echo "$MACHINETEMPLATES" |grep $MDNAME |awk '{print $1}'|xargs -I {} kubectl get vspheremachinetemplate {} -n $CLUSTERNAMESPACE -o json)
        VSPHEREWKRIMAGE=$(echo "${WKMACHINETEMPLATES}" |jq -r '.spec.template.spec.template')
        echo "      vSphere Worker Image: $VSPHEREWKRIMAGE"

        VSPHERECREDENTIALS=$(kubectl get secret -n $CLUSTERNAMESPACE |grep cloud-provider-vsphere-credentials-$WKCLUSTER |awk '{print $1}' | xargs -I {} kubectl get secret {} -n $CLUSTERNAMESPACE -o json |jq -r '.data.data' |base64 -d |yq e .stringData)
        export GOVC_URL=$(echo "$VSPHERECREDENTIALS" |grep username |cut -d":" -f1|sed "s/.username//")
        export GOVC_USERNAME=$(echo "$VSPHERECREDENTIALS" |grep username |cut -d ":" -f2|sed "s/ //")
        export GOVC_PASSWORD=$(echo "$VSPHERECREDENTIALS" |grep password |cut -d ":" -f2|sed "s/ //")
        export GOVC_INSECURE=1
        ./vsphere-get-templates.sh 
        ;;
    *)
        echo "      other provider: $WORKLOADCLUSTERPROVIDER"
        echo "      script not ready for this use case yet."
        exit 1
        ;;
esac
