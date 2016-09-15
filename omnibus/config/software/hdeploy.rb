name "hdeploy"

default_version "0.1.0"

build do
  env = with_standard_compiler_flags(with_embedded_path)
  gem "install hdeploy --no-rdoc --no-ri -v #{version}", env: env
end

