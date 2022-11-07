#!/bin/bash
set -euo pipefail

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
SP_TENANT=72f988bf-86f1-41af-91ab-2d7cd011db47
SP_APPID=30f76dd2-a2d9-4abb-acad-c298b8ac04c4
SP_PWD='7Fp7Q~tdXCjP1QjFmLzSlKiLqlZAR5ZGOFNBJ'
RESOURCE_GROUP_NAME=dv-ebdev
STORAGE_ACCOUNT_NAME=ebdevcvmfs
KEYVAULT_NAME=ebdevkv
CVMFS_USER=hpcadmin
SIGNATURE_EXPIRATION_DAYS=365
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

step_info () {
    printf '\e[33m>>> %s\e[0m\n' "$@"
}

error () {
    printf '\e[31m!!!ERROR!!! %s\e[0m\n' "$@"
    exit 1
}

# Install jq if not already installed
if ! command -v jq &> /dev/null; then
    step_info 'Installing jq'
    sudo yum install -y epel-release
    sudo yum install -y jq
fi

OS_NAME=$(curl -s -H Metadata:true --noproxy "*" "http://169.254.169.254/metadata/instance?api-version=2020-09-01" | \
          jq -r '.compute.storageProfile.imageReference.offer')
OS_VERSION=$(curl -s -H Metadata:true --noproxy "*" "http://169.254.169.254/metadata/instance?api-version=2020-09-01" | \
             jq -r '.compute.storageProfile.imageReference.version')
REPO_NAME=$(./scripts/sku2repo.sh)

CVMFS_REPO_ROOT=/cvmfs/${REPO_NAME}
STACK_ROOT=${CVMFS_REPO_ROOT}/${OS_NAME}/${OS_VERSION}
MODULEPATH_ROOT=${STACK_ROOT}/EasyBuild/modules/all/Core
CVMFS_REPO_INIT_SCRIPT=scripts/cvmfs_repo_init.sh
COMMON_REPO_NAME=common.azure
LMOD_CUSTOMIZE_DIR=/cvmfs/${COMMON_REPO_NAME}/lmod
PROFILE_PATH=${STACK_ROOT}/lmod/lmod/init/profile
EB_SOURCES_DIR=/cvmfs/${COMMON_REPO_NAME}/sources
EB_BUILD_PATH=/tmp/EasyBuildScratch

# Define repository name based on VM SKU
if [[ ${REPO_NAME} == 'UNKNOWN' ]]; then
    error "VM SKU is not mapped to a CVMFS repository. Please update scripts/sku2repo.sh"
else
    step_info "Identified target CVMFS repository: ${REPO_NAME}"
fi

# Install CVMFS if not already installed
if ! command -v cvmfs_server &> /dev/null; then
    step_info "Installing CVMFS"
    ./scripts/cvmfs_stratum0_install.sh
fi

# Create or import common and SKU-specific CVMFS repos if not already active
for REPO in ${REPO_NAME} ${COMMON_REPO_NAME}; do
    if [[ $(cvmfs_server list) =~ ${REPO} ]]; then
        step_info "CVMFS repository ${REPO} already initialized"
    else
        CONTAINER_NAME=${REPO%%.*}

        # Edit CVMFS repo init script header
        sed -i "s/^SP_TENANT=.*/SP_TENANT=${SP_TENANT}/g" ${CVMFS_REPO_INIT_SCRIPT}
        sed -i "s/^SP_APPID=.*/SP_APPID=${SP_APPID}/g" ${CVMFS_REPO_INIT_SCRIPT}
        sed -i "s/^SP_PWD=.*/SP_PWD=${SP_PWD}/g" ${CVMFS_REPO_INIT_SCRIPT}
        sed -i "s/^RESOURCE_GROUP_NAME=.*/RESOURCE_GROUP_NAME=${RESOURCE_GROUP_NAME}/g" ${CVMFS_REPO_INIT_SCRIPT}
        sed -i "s/^STORAGE_ACCOUNT_NAME=.*/STORAGE_ACCOUNT_NAME=${STORAGE_ACCOUNT_NAME}/g" ${CVMFS_REPO_INIT_SCRIPT}
        sed -i "s/^CONTAINER_NAME=.*/CONTAINER_NAME=${CONTAINER_NAME}/g" ${CVMFS_REPO_INIT_SCRIPT}
        sed -i "s/^KEYVAULT_NAME=.*/KEYVAULT_NAME=${KEYVAULT_NAME}/g" ${CVMFS_REPO_INIT_SCRIPT}
        sed -i "s/^CVMFS_USER=.*/CVMFS_USER=${CVMFS_USER}/g" ${CVMFS_REPO_INIT_SCRIPT}
        sed -i "s/^SIGNATURE_EXPIRATION_DAYS=.*/SIGNATURE_EXPIRATION_DAYS=${SIGNATURE_EXPIRATION_DAYS}/g" ${CVMFS_REPO_INIT_SCRIPT}

        step_info "Creating/Importing CVMFS repository: ${REPO}"
        ./${CVMFS_REPO_INIT_SCRIPT}
    fi
done

# Check if we need to start a transaction to install Lmod or EasyBuild
if [ ! -s ${PROFILE_PATH} ] || [ ! -d ${MODULEPATH_ROOT}/EasyBuild ]; then
    for REPO in ${REPO_NAME} common.azure; do
        step_info "Starting CVMFS transaction for repository: ${REPO}"
        cvmfs_server transaction ${REPO}
        rm -f /cvmfs/${REPO}/new_repository  # Just housekeeping
    done

    # Create stack root directories
    if [ ! -d ${STACK_ROOT} ]; then
        step_info "Creating OS specific directory tree"
        mkdir -pv ${STACK_ROOT}
    fi

    # Install Lua and Lmod if not already installed
    if [ ! -s ${PROFILE_PATH} ]; then
        ./scripts/lmod_install_src.sh ${STACK_ROOT} ${MODULEPATH_ROOT}

        # Install Lmod custom scripts
        step_info "Beautify Lmod"
        mkdir -pv ${LMOD_CUSTOMIZE_DIR}
        cp -v templates/hide_modules.lst templates/SitePackage.lua ${LMOD_CUSTOMIZE_DIR}
        grep -qF 'LMOD_PACKAGE_PATH' ${PROFILE_PATH} || echo "export LMOD_PACKAGE_PATH=${LMOD_CUSTOMIZE_DIR}" >> ${PROFILE_PATH}
        grep -qF 'LMOD_MODULERCFILE' ${PROFILE_PATH} || echo "export LMOD_MODULERCFILE=${LMOD_CUSTOMIZE_DIR}/rc.lua" >> ${PROFILE_PATH}
        grep -qF 'LMOD_AVAIL_STYLE' ${PROFILE_PATH} || echo 'export LMOD_AVAIL_STYLE=azurehpc' >> ${PROFILE_PATH}
        grep -qF 'LMOD_HIDEMODSFILE' ${PROFILE_PATH} || echo "export LMOD_HIDEMODSFILE=${LMOD_CUSTOMIZE_DIR}/hide_modules.lst" >> ${PROFILE_PATH}
    fi

    # Install EasyBuild
    if [ ! -d ${MODULEPATH_ROOT}/EasyBuild ]; then
        # Initialize Lmod first
        source ${PROFILE_PATH}
        ./scripts/easybuild_install.sh ${STACK_ROOT} ${EB_BUILD_PATH} ${EB_SOURCES_DIR}
    fi

    # Publish transaction
    for REPO in ${REPO_NAME} common.azure; do
        step_info "Publishing CVMFS transaction for repository: ${REPO}"
        cvmfs_server publish ${REPO}
    done
else
    # Ensure build directory presence and correct permissions
    # This is necessary when EB is already in the imported repo and installer not run
    step_info 'Creating EasyBuild build directory'
    sudo mkdir -p ${EB_BUILD_PATH}
    sudo chown ${USER}: ${EB_BUILD_PATH}

    # Install Rich package in case EB is already installed
    step_info 'Installing Python Rich library'
    sudo python3 -m pip install rich
fi

# Automatically mount CVMFS repos at login
for REPO in ${REPO_NAME} common.azure; do
    MOUNT_STR="sudo cvmfs_server mount ${REPO}"
    grep -qF "${MOUNT_STR}" ~/.bashrc || echo ${MOUNT_STR} >> ~/.bashrc
done

# Lmod init at login
PROFILE_PATH=${STACK_ROOT}/lmod/lmod/init/profile
grep -qF "${PROFILE_PATH}" ~/.bashrc || echo "source ${PROFILE_PATH}" >> ~/.bashrc

# Add custom aliases
ALIAS='alias modlist="ml -t spider |& egrep -v '.*/[0-9]' | sed 's|/||g''"
grep -qF "modlist" ~/.bashrc || echo 'alias modlist="ml -t spider |& egrep -v '.*/[0-9]' | sed 's|/||g'"'
ml -t spider |& egrep -v '.*/[0-9]' | sed 's|/||g'
