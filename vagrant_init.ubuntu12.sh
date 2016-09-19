#!/bin/bash

echo ubuntu12 > /etc/hostname
# This is needed by git ...
echo 127.0.0.1 ubuntu12.localdomain ubuntu14 >> /etc/hosts
hostname ubuntu12

# No multiarch or deb-src -- faster
sed -ie "s/^deb-src/#deb-src/g" /etc/apt/sources.list

rm -f /etc/dpkg/dpkg.cfg.d/multiarch

# Install omnibus requirements
apt-get update
apt-get -y install python-software-properties
apt-add-repository -y ppa:brightbox/ruby-ng
apt-get update
apt-get -y install ruby2.3 ruby2.3-dev git build-essential libgecode-dev

# We need bundle for the initial build
gem install bundle --no-rdoc --no-ri

# Special thing: libgecode. building extensions takes forever...
cd /vagrant/omnibus
env USE_SYSTEM_GECODE=1 bundle install --binstubs
