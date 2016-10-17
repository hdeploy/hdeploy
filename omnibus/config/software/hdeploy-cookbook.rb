name 'hdeploy-cookbook'

dependency 'chef-gem'
dependency 'runit'

source git: 'https://github.com/hdeploy/hdeploy-chef-cookbook'

build do
  cookbooks_path = "#{install_dir}/embedded/cookbooks"
  env = with_standard_compiler_flags(with_embedded_path)

  command "#{install_dir}/embedded/bin/gem install --no-rdoc --no-ri berkshelf -v 5.1.0", env: env # FIXME: gemfile
  command "#{install_dir}/embedded/bin/berks vendor #{cookbooks_path}", env: env

  block do

    # There is an annoying behavior of berkshelf: it processes the metadata.rb ... and I don't want it to because I got some code in there
    # So I'll copy it manually if it exists. This is kind of hacky - I don't like it ...
    if File.exists? "#{project_dir}/metadata.rb"
      copy "metadata.rb", "#{cookbooks_path}/hdeploy/metadata.rb"
      delete "#{cookbooks_path}/hdeploy/metadata.json"
    end

    open("#{cookbooks_path}/embedded_chef.rb", "w") do |file|
      file.write <<-EOH.gsub(/^ {8}/, '')
        cookbook_path   "#{cookbooks_path}"
        file_cache_path "#{cookbooks_path}/cache"
        verbose_logging true
        ssl_verify_mode :verify_peer
        lockfile "#{cookbooks_path}/embedded_chef_lock" #Because this way I can run chef from an external chef
      EOH
    end

    open("#{cookbooks_path}/zero_chef.rb", "w") do |file|
      file.write <<-EOH.gsub(/^ {8}/, '')
        cookbook_path   "#{cookbooks_path}"
        file_cache_path "#{cookbooks_path}/cache"
        verbose_logging true
        ssl_verify_mode :verify_peer
      EOH
    end
  end
end
