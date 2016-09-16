#
# Copyright 2016 Patrick Viet
#
# All Rights Reserved.
#

name "hdeploy"
maintainer "Patrick Viet"
homepage "http://github.com/hdeploy/hdeploy"

# Defaults to C:/hdeploy on Windows
# and /opt/hdeploy on all other platforms
install_dir "#{default_root}/#{name}"

build_version Omnibus::BuildVersion.semver
build_iteration 1

# Creates required build directories
dependency "preparation"

# hdeploy dependencies/components
dependency "ruby"
dependency "runit"
dependency "curl"

override :'chef-gem', version: '12.8.1'
override :ruby, version: "2.3.1"
override :git, version: "2.8.2"

dependency "hdeploy"
#dependency "omnibus-hdeploy-cookbooks"
dependency "hdeploy-ctl"

# Version manifest file
dependency "version-manifest"

exclude "**/.git"
exclude "**/bundler/git"
