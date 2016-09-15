#
# Copyright 2016 YOUR NAME
#
# All Rights Reserved.
#

name "hdeploy"
maintainer "CHANGE ME"
homepage "https://CHANGE-ME.com"

# Defaults to C:/hdeploy on Windows
# and /opt/hdeploy on all other platforms
install_dir "#{default_root}/#{name}"

build_version Omnibus::BuildVersion.semver
build_iteration 1

# Creates required build directories
dependency "preparation"

# hdeploy dependencies/components
# dependency "somedep"

# Version manifest file
dependency "version-manifest"

exclude "**/.git"
exclude "**/bundler/git"
