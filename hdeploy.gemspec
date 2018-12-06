$:.push File.expand_path("../lib", __FILE__)
require 'hdeploy/version'

Gem::Specification.new do |s|
  s.name          = "hdeploy"
  s.version       = HDeploy::VERSION
  s.authors       = ["Patrick Viet"]
  s.email         = ["patrick.viet@gmail.com"]
  s.description   = %q{HDeploy tool}
  s.summary       = %q{no summary}
  s.homepage      = "https://github.com/hdeploy/hdeploy"

  s.files         = `git ls-files`.split($/).select{|i| not i =~ /^(vagrant|omnibus|api)/i }
  s.executables   = s.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  s.test_files    = s.files.grep(%r{^(test|spec|features)/})
  s.require_paths = ["lib"]

  s.add_runtime_dependency 'json',    '>= 1.7', '< 2.0.0'
  s.add_runtime_dependency 'curb',    '~> 0.8'
  s.add_runtime_dependency 'inifile',   '~> 2.0'
  s.add_runtime_dependency 'deep_clone', '~> 0.0' # For configuration
  s.add_runtime_dependency 'deep_merge', '~> 1.1'
  s.add_runtime_dependency 'rb-readline', '> 0'
  s.add_runtime_dependency 'pry', '> 0'
  s.add_runtime_dependency 'sinatra', '~> 2.0.3'
  s.add_runtime_dependency 'eventmachine', '~> 1.2.5'
end
