#!/bin/bash

# Set OpenResty source directory
OPENRESTY_SRC_DIR=/usr/local/openresty


mkdir  -p $OPENRESTY_SRC_DIR

apt-get install make gcc  -y

# Function to build OpenResty
build_openresty() {
 wget  https://openresty.org/download/openresty-1.25.3.1.tar.gz
 tar -xzf openresty-1.25.3.1.tar.gz
 cd openresty-1.25.3.1
  ./configure --prefix=$OPENRESTY_SRC_DIR
  make
  make install
}

# Main script
build_openresty
exit 0
