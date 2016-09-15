require 'hdeploy/conf'
require 'hdeploy/cli'
require 'hdeploy/client'
require 'hdeploy/apiclient'

module HDeploy
  def HDeploy.where_is(f)
    File.expand_path "../#{f}", __FILE__
  end
end

