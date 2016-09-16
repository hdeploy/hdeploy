name 'hdeploy-ctl'
#license :project_license

dependency "chef-gem"
dependency "runit"
dependency "omnibus-hdeploy-cookbooks"

default_version '0.0.1' # WTF

source path: "cookbooks/omnibus-hdeploy"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  #bundle "install", env: env

  block do

    command "mkdir -p #{install_dir}/bin" unless File.exists? "#{install_dir}/bin"
    command "mkdir -p #{install_dir}/embedded/bin" unless File.exists? "#{install_dir}/embedded/bin"

    # This is just a wrapper that cleans up environment
    erb source: "hdeploy-ctl.erb",
        dest: "#{install_dir}/bin/hdeploy-ctl",
        mode: 0755,
        vars: { embedded_bin: "#{install_dir}/embedded/bin" }

    # This is the real thing
    erb source: "hdeploy-ctl.rb.erb",
        dest: "#{install_dir}/embedded/bin/hdeploy-ctl.rb",
        mode: 0755,
        vars: { install_dir: install_dir }

    # Align?
  end

end