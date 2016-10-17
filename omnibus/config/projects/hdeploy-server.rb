#
# Copyright 2016 Patrick Viet
#
# All Rights Reserved.
#

name "hdeploy-server"
maintainer "Patrick Viet"
homepage "https://github.com/hdeploy/hdeploy-server"

# Defaults to C:/hdeploy-server on Windows
# and /opt/hdeploy-server on all other platforms
install_dir "#{default_root}/#{name}"

build_version Omnibus::BuildVersion.semver
build_iteration 1

# Creates required build directories
dependency "preparation"

# hdeploy-server dependencies/components
# dependency "somedep"

dependency "hdeploy-server"
dependency "hdeploy-ctl"
dependency "nginx-passenger"
dependency "hdeploy-cookbook"

override :'chef-gem', version: '12.14.60' # Because otherwise with Ruby 2.3 it will throw big warnings
override :ruby, version: "2.3.1"
override :git, version: "2.8.2"

# Version manifest file
dependency "version-manifest"

exclude "**/.git"
exclude "**/bundler/git"
