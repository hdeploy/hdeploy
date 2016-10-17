$LOAD_PATH.unshift File.expand_path(File.join(__FILE__,'../lib'))

require 'sinatra'
require 'hdeploy/api'

run HDeploy::API

