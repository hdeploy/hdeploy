#!/bin/bash

sed -ie "s/^HOSTNAME=localhost.localdomain/HOSTNAME=centos7/g" /etc/sysconfig/network
hostname centos7

yum install -y libyaml gcc gcc-c++ make openssl-devel autoconf automake epel-release
yum install -y gecode-devel
wget -O /tmp/ruby23.rpm https://github.com/feedforce/ruby-rpm/releases/download/2.3.1/ruby-2.3.1-1.el7.centos.x86_64.rpm
yum install -y /tmp/ruby23.rpm

yum install -y patch rpm-build git

# otherwise it crashes. yes I know its retarded...
git config --global user.email "you@example.com"
git config --global user.name "Your Name"



gem install bundle

# Special thing: libgecode. building extensions takes forever...
cd /vagrant
env USE_SYSTEM_GECODE=1 bundle install --binstubs
