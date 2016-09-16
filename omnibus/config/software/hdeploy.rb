name "hdeploy"

default_version "0.1.0" # This is kinda useless since we're local...

source path: File.expand_path("../..", project.files_path),
       options: { exclude: [ "omnibus/vendor" ] }

dependency "ruby"

build do
  env = with_standard_compiler_flags(with_embedded_path)
  
  # FIXME : please don't puke. this intermediary file thing is really really dirty.
  gem "build hdeploy.gemspec", env: env
  gem "install hdeploy-*.gem --no-rdoc --no-ri", env: env
end
