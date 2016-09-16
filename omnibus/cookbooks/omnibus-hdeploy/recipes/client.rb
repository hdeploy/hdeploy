# This recipe runs

# This reconfigures runit
include_recipe 'enterprise::runit'

%w[client_check_deploy client_keepalive].each do |component|

  directory node['hdeploy'][component]['log_directory'] do
    owner 'root'
    group 'root'
    mode '0700'
    recursive true
  end

  component_runit_service component do
    package 'hdeploy'
    action :disable unless node['hdeploy'][component]['enable']
  end

end