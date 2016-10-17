name "hdeploy-server"

default_version "0.1.0" # This is kinda useless since we're local...

source path: File.expand_path('../..', project.files_path)

dependency "ruby"
dependency "bundler"

build do
  env = with_standard_compiler_flags(with_embedded_path)
  
  sync "api", "#{install_dir}/embedded/api", env: env

  # This actually runs a shellout. That's how I found the cwd: option...
  # https://github.com/chef/mixlib-shellout/blob/master/lib/mixlib/shellout.rb
  bundle "install", env: env, cwd: "#{install_dir}/embedded/api"
end
