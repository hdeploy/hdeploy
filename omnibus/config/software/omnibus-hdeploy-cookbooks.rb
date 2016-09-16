#
# Copyright 2014 Chef Software, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Patrick's note: totally stole this from Chef's supermarket.
# https://github.com/chef/supermarket/blob/c3aa5369f7c88c2ff206809dd814325c3428e609/omnibus/config/software/supermarket-cookbooks.rb

name 'hdeploy-cookbooks'

dependency "berkshelf"

default_version '0.0.1'

source path: "cookbooks/omnibus-hdeploy"

build do
  cookbooks_path = "#{install_dir}/embedded/cookbooks"
  env = with_standard_compiler_flags(with_embedded_path)

  command "berks vendor #{cookbooks_path}", env: env

  block do
    open("#{cookbooks_path}/dna.json", "w") do |file|
      file.write JSON.fast_generate(run_list: ['recipe[omnibus-hdeploy::default]'])
    end

    open("#{cookbooks_path}/solo.rb", "w") do |file|
      file.write <<-EOH.gsub(/^ {8}/, '')
        cookbook_path   "#{cookbooks_path}"
        file_cache_path "#{cookbooks_path}/cache"
        verbose_logging true
        ssl_verify_mode :verify_peer
      EOH
    end
  end
end
