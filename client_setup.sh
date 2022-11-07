#!/bin/bash
set -eou pipefail

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Set OS version to override system version
OS_VERSION='7.9.2021052401'
STORAGE_ACCOUNT_URL='https://ebdevcvmfs.blob.core.windows.net'
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

COMMON_REPO_NAME=common.azure

step_info () {
    printf '\e[33m>>> %s\e[0m\n' "$@"
}

step_warning () {
    printf '\e[33m!!! WARNING: %s\e[0m\n' "$@"
}

if ! command -v jq &> /dev/null; then
    step_info 'Installing jq'
    sudo yum install -y epel-release
    sudo yum install -y jq
fi

REPO_NAME=$(./scripts/sku2repo.sh)
CONTAINER_NAME=${REPO_NAME%%.*}

OS_NAME=$(curl -s -H Metadata:true --noproxy "*" "http://169.254.169.254/metadata/instance?api-version=2020-09-01" | \
          jq -r '.compute.storageProfile.imageReference.offer')

if [ -z "$OS_VERSION" ]; then
    OS_VERSION=$(curl -s -H Metadata:true --noproxy "*" "http://169.254.169.254/metadata/instance?api-version=2020-09-01" | \
                 jq -r '.compute.storageProfile.imageReference.version')
else
    step_warning "Targeting ${OS_NAME} version ${OS_VERSION} instead of system version"
fi

# Install CVMFS client component
if ! rpm -qa | grep 'cvmfs-release'; then
    step_info 'Importing CERN CVMFS repository'
    sudo yum install -y https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-latest.noarch.rpm
fi
step_info 'Installing CVMFS client components'
sudo yum install -y cvmfs

for REPO in ${REPO_NAME} ${COMMON_REPO_NAME}; do
    CVMFS_REPO_ROOT=/cvmfs/${REPO}
    STACK_ROOT=${CVMFS_REPO_ROOT}/${OS_NAME}/${OS_VERSION}
    CONTAINER_NAME=${REPO%%.*}

    step_info "Collecting configuration and public key files from Blob for repository ${REPO}"
    sudo curl ${STORAGE_ACCOUNT_URL}/${CONTAINER_NAME}/${REPO}.conf -o /etc/cvmfs/config.d/${REPO}.conf
    sudo curl ${STORAGE_ACCOUNT_URL}/${CONTAINER_NAME}/${REPO}.pub -o /etc/cvmfs/keys/${REPO}.pub
    sudo cvmfs_config setup

    step_info 'Disabling AutoFS'
    sudo systemctl disable autofs
    sudo systemctl stop autofs

    sudo mkdir -p ${CVMFS_REPO_ROOT}

    if ! grep "$CVMFS_REPO_ROOT" /etc/fstab; then
        step_info 'Configuring fstab'
        echo "${REPO} ${CVMFS_REPO_ROOT} cvmfs defaults,_netdev,nodev 0 0" | sudo tee -a /etc/fstab
    fi

    if ! findmnt ${CVMFS_REPO_ROOT}; then
        step_info 'Mounting CVMFS file system'
        sudo mount -a
    fi
done
