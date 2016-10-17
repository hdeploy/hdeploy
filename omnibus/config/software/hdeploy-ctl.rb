name 'hdeploy-ctl'

dependency 'chef-gem'
dependency 'runit'
dependency 'hdeploy-cookbook'

default_version '0.0.1'

#source path: File.expand_path(project.files_path)

build do
  env = with_standard_compiler_flags(with_embedded_path)

  #bundle "install", env: env

  gem "install pry --no-rdoc --no-ri", env: env # Fixme: version

  block do

    command "mkdir -p #{install_dir}/bin" unless File.exists? "#{install_dir}/bin"
    command "mkdir -p #{install_dir}/embedded/bin" unless File.exists? "#{install_dir}/embedded/bin"

    # This is just a wrapper that cleans up environment
    erb source: "hdeploy-ctl.erb",
        dest: "#{install_dir}/bin/#{project.name}-ctl",
        mode: 0755,
        vars: { embedded_bin: "#{install_dir}/embedded/bin", project_name: project.name }

    # This is the real thing
    erb source: "hdeploy-ctl.rb.erb",
        dest: "#{install_dir}/embedded/bin/#{project.name}-ctl.rb",
        mode: 0755,
        vars: { install_dir: install_dir, project_name: project.name }

    # Align?
  end

end
