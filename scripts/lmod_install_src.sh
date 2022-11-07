#!/bin/bash
set -euo pipefail

INSTALL_ROOT_PATH=${1:-/apps/Lua}
MODULE_PATH=${2:-/apps/EasyBuild/modules/all/Core}
LMOD_VER=${3:-8.6.14}

LUA_INSTALL_PATH=${INSTALL_ROOT_PATH}/Lua/5.1.4.9
SPIDER_CACHE_DIR=${INSTALL_ROOT_PATH}/lmod/spidercache
LMOD_INIT_DIR=${INSTALL_ROOT_PATH}/lmod/lmod/init

step_info () {
    printf '\e[33m>>> %s\e[0m\n' "$@"
}

# Install Lua
step_info 'Installing Lua'
mkdir -p ${LUA_INSTALL_PATH}
pushd /tmp
wget --no-check-certificate https://sourceforge.net/projects/lmod/files/lua-5.1.4.9.tar.bz2
tar xjf lua-5.1.4.9.tar.bz2
pushd lua-5.1.4.9
./configure --prefix=${LUA_INSTALL_PATH}
make -j4
make install
popd
rm -rf lua-5.1.4.9*
popd
pushd ${INSTALL_ROOT_PATH}/Lua/5.1.4.9/..
ln -s 5.1.4.9 current
export PATH=${INSTALL_ROOT_PATH}/Lua/current/bin:$PATH
popd

# Install Lmod
# Not using with-module-root-path since that injects unneccessary paths in MODULEPATH
step_info 'Installing Lmod'
pushd /tmp
wget https://github.com/TACC/Lmod/archive/refs/tags/${LMOD_VER}.tar.gz
tar xzf ${LMOD_VER}.tar.gz
pushd Lmod-${LMOD_VER}
./configure --with-spiderCacheDir=${SPIDER_CACHE_DIR} \
            --with-pinVersions=yes \
            --with-tcl=no \
            --with-fastTCLInterp=no \
            --prefix=${INSTALL_ROOT_PATH}
make install
mkdir -p ${SPIDER_CACHE_DIR}
popd
rm -rf Lmod-${LMOD_VER} ${LMOD_VER}.tar.gz
popd

# Lmod configuration
step_info 'Customizing Lmod'
# Add EasyBuild module path in .modulespath file
echo ${MODULE_PATH} > ${LMOD_INIT_DIR}/.modulespath
# Remove all paths in MODULEPATHS set by other
grep -qF 'unset MODULEPATH' ${LMOD_INIT_DIR}/profile || \
    sed -i 's/MODULEPATH_INIT.*then/&\n       unset MODULEPATH/g' ${LMOD_INIT_DIR}/profile
# Disable user spider cache creation
grep -qF 'LMOD_SHORT_TIME' ${LMOD_INIT_DIR}/profile || \
    echo 'export LMOD_SHORT_TIME=86400' >> ${LMOD_INIT_DIR}/profile
# Use custom built Lua
grep -qF "${INSTALL_ROOT_PATH}/Lua/current/bin" ${LMOD_INIT_DIR}/profile || \
    echo "export PATH=${INSTALL_ROOT_PATH}/Lua/current/bin:\$PATH" >> ${LMOD_INIT_DIR}/profile
