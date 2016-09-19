#!/bin/bash

sed -ie "s/^HOSTNAME=localhost.localdomain/HOSTNAME=centos6.localdomain/g" /etc/sysconfig/network
hostname centos6.localdomain
echo 127.0.0.1 centos6.localdomain centos6 >> /etc/hosts

yum install -y libyaml git gcc gcc-c++ make openssl-devel autoconf automake epel-release patch
yum install -y gecode-devel
wget -O /tmp/ruby23.rpm https://github.com/feedforce/ruby-rpm/releases/download/2.3.1/ruby-2.3.1-1.el6.x86_64.rpm
yum install -y /tmp/ruby23.rpm

yum install -y http://opensource.wandisco.com/centos/6/git/x86_64/wandisco-git-release-6-1.noarch.rpm
yum install -y patch rpm-build git

gem install bundle --no-rdoc --no-ri

# Special thing: libgecode. building extensions takes forever...
cd /vagrant/omnibus
env USE_SYSTEM_GECODE=1 bundle install --binstubs
