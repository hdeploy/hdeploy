#!/bin/bash

echo ubuntu14 > /etc/hostname
# This is needed by git ...
echo 127.0.0.1 ubuntu14.localdomain ubuntu14 >> /etc/hosts
hostname ubuntu14

# No multiarch or deb-src -- faster
sed -ie "s/^deb-src/#deb-src/g" /etc/apt/sources.list

for arch in $(dpkg --print-foreign-architectures) ; do
  dpkg --remove-architecture ${arch}
done

# Install omnibus requirements
apt-get update
apt-get -y install software-properties-common
apt-add-repository -y ppa:brightbox/ruby-ng
apt-get update
apt-get -y install ruby2.3 ruby2.3-dev git build-essential libgecode-dev

# We need bundle for the initial build
gem install bundle

# Special thing: libgecode. building extensions takes forever...
cd /vagrant/omnibus
env USE_SYSTEM_GECODE=1 bundle install --binstubs
