#!/bin/bash
set -euo pipefail

sudo yum install -y bzip2 libuuid-devel gcc gcc-c++ valgrind-devel cmake \
                    fuse fuse-devel fuse3 fuse3-libs fuse3-devel libattr-devel \
                    openssl-devel patch pkgconfig unzip python-devel libcap-devel \
                    unzip git

pushd /tmp > /dev/null
wget https://github.com/cvmfs/cvmfs/archive/refs/tags/cvmfs-2.9.0.tar.gz
tar xzf cvmfs-2.9.0.tar.gz
pushd cvmfs-cvmfs-2.9.0 > /dev/null
mkdir build
pushd build > /dev/null
cmake ..
make -j4
sudo make install
sudo cvmfs_server fix-permissions
popd > /dev/null
popd > /dev/null
rm -rf cvmfs-cvmfs-2.9.0 cvmfs-2.9.0.tar.gz
