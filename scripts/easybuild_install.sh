#!/bin/bash
set -euo pipefail

STACK_ROOT=${1:-/apps}
BUILD_PATH=${2:-/tmp}
SOURCES_DIR=${3:-DEFAULT}

EB_ROOT=${STACK_ROOT}/EasyBuild
EB_CONFIGDIR=${EB_ROOT}/easybuild.d
CUSTOM_EASYCONFIGS_PATH=${EB_ROOT}/custom_easyconfigs

step_info () {
    printf '\e[33m>>> %s\e[0m\n' "$@"
}

error () {
    printf '\e[31m!!!ERROR!!! %s\e[0m\n' "$@"
    exit 1
}

# Ensure Lmod is loaded in the environment
# This is necessary for the EasyBuild bootstrap to generate Lua module instead of Tcl
if ! ml -v &> /dev/null; then
    error 'Cannot find Lmod in the environment'
fi

# Install Rich package
step_info 'Installing Python Rich library'
sudo python3 -m pip install rich

# Install EasyBuild in /tmp. This installation is then used to do the actual
# EasyBuild installation in the desired stack directory
# https://docs.easybuild.io/en/latest/Installation.html#installing-easybuild-with-easybuild
step_info 'Bootstrapping EasyBuild'
EB_TMPDIR=/tmp/EasyBuild
pip3 install --no-cache-dir --install-option "--prefix=${EB_TMPDIR}" easybuild
export PATH=${EB_TMPDIR}/bin:${PATH}
export PYTHONPATH=$(/bin/ls -rtd -1 ${EB_TMPDIR}/lib*/python*/site-packages | tail -1)
export EB_PYTHON=python3

# EasyBuild configuration
step_info 'Creating EasyBuild configuration'
if [ ! -d ${EB_CONFIGDIR} ]; then
    mkdir -pv ${EB_CONFIGDIR}
fi

cat << EOF > ${EB_CONFIGDIR}/easybuild.cfg
[config]
buildpath = ${BUILD_PATH}
prefix = ${EB_ROOT}
module-depends-on = true
module-naming-scheme = HierarchicalMNS
module-syntax = Lua
modules-tool = Lmod
[override]
allow-loaded-modules = EasyBuild
detect-loaded-modules = purge
minimal-toolchains = true
use-existing-modules = true
zip-logs = gzip
rpath = true
enforce-checksums = true
cuda-compute-capabilities = 8.0
[basic]
robot-paths = ${CUSTOM_EASYCONFIGS_PATH}:
EOF

# If a custom sources path is selected, inject it into the configuration
if [[ ${SOURCES_DIR} != DEFAULT ]]; then
    sed -i "s|\[config\]|&\nsourcepath = $SOURCES_DIR|g" ${EB_CONFIGDIR}/easybuild.cfg
fi

# If a GPU is detected, add the corresponding compute capability into the configuration
#sed -i "s/\[override\]/&\ncuda-compute-capabilities = $CUDA_CC/g" ${EB_CONFIGDIR}/easybuild.cfg

# Add appropriate flags if building for generic architecture
if [[ ${STACK_ROOT} =~ generic ]]; then
    sed -i "s|\[override\]|&\noptarch = GENERIC|g" ${EB_CONFIGDIR}/easybuild.cfg
fi

# Make sure build directory is writeable by the current user
step_info 'Creating EasyBuild build directory'
sudo mkdir -p ${BUILD_PATH}
sudo chown ${USER}: ${BUILD_PATH}

step_info 'Creating custom easyconfigs directory'
mkdir -p ${CUSTOM_EASYCONFIGS_PATH}

# Use EasyBuild configuration for bootstrap
export XDG_CONFIG_DIRS=${EB_ROOT}

# Install Easybuild in stack
step_info 'Installing EasyBuild'
eb --install-latest-eb-release

# Set the custom EasyBuild configuration file path when its module is loaded
step_info 'Customizing EasyBuild module'
echo "setenv(\"XDG_CONFIG_DIRS\", \"${EB_ROOT}\")" >> ${EB_ROOT}/modules/all/Core/EasyBuild/*.lua

# Remove temporary EasyBuild installation
rm -rf ${EB_TMPDIR}
