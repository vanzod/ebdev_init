#!/bin/bash
set -eou pipefail

# If the hostname is "generic", then build for generic architecture
if [ $HOSTNAME == generic ]; then
    REPO_NAME='generic.azure'
else
    if ! command -v jq &> /dev/null; then
        sudo yum install -y epel-release
        sudo yum install -y jq
    fi

    # Get lowercase VM SKU without "Standard_"
    VMSKU=$(curl -s --noproxy "*" -H Metadata:true "http://169.254.169.254/metadata/instance/compute?api-version=2019-08-15" | \
            jq -r '.vmSize' | tr '[:upper:]' '[:lower:]' | sed -e 's/[^_]*_//')

    case $VMSKU in
        d*_v4|d*_v5)
            REPO_NAME='dv4.azure'
        ;;
        hb*_v2)
            REPO_NAME='hbv2.azure'
        ;;
        nd96asr_v4|nc96ads_a100_v4)
            REPO_NAME='ndv4.azure'
        ;;
        *)
            REPO_NAME='UNKNOWN'
        ;;
    esac
fi

#echo ${VMSKU}
echo ${REPO_NAME}
