default['enterprise']['name'] = 'hdeploy'

default['hdeploy']['fqdn'] = node['fqdn'].downcase
default['hdeploy']['sysvinit_id'] = 'HD' # Must be HS for HDeploy Server

default['hdeploy']['install_path'] = '/opt/hdeploy' # This is very important for the enterprise cookbook

%w[client_check_deploy client_keepalive].each do |component|
  default['hdeploy'][component]['enable'] = true
  default['hdeploy'][component]['log_directory'] = "/var/log/hdeploy/#{component}"
  default['hdeploy'][component]['log_rotation']['file_maxbytes'] = 104857600
  default['hdeploy'][component]['log_rotation']['num_to_keep'] = 10
end