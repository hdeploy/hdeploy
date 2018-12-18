require 'hdeploy/apiclient'
require 'json'
require 'fileutils'
require 'inifile'
require 'digest'

module HDeploy
  class CLI

    def initialize
      @conf = HDeploy::Conf.instance
      @client = HDeploy::APIClient.instance

      @conf['cli'] ||= {}

      cli_defaults = {
        'default_env' => 'dev',
        'default_app' => 'demoapp',
        'domain_name' => nil,
      }

      if File.file? '/etc/resolv.conf'
        domain_name = File.readlines('/etc/resolv.conf').select{|line| line =~ /^domain /}
        if domain_name.count == 1
          if domain_name.first =~ /^domain_name[\s\t]+([a-z0-9\.\-]+)/
            cli_defaults['domain_name'] = $1
          end
        end
      end

      cli_defaults.each do |k,v|
        @conf['cli'][k] ||= v
      end

      @domain_name = @conf['cli']['domain_name']
      @app = @conf['cli']['default_app']
      @env = @conf['cli']['default_env']
      @force = false
      @fakebuild = false
      @verbose = false


      @conf.each do |k|
        next unless k[0..3] == 'app:'
        @conf[k].each do |k2,v|
          @conf[k][k2] = File.expand_path(v) if k2 =~ /\_path$/
        end
      end

    end

    def run!
      #begin
        cmds = []
        ARGV.each do |arg|
          cmd = arg.split(':',2)
          if cmd[0][0] == '_'
            raise "you cant use cmd starting with a _"
          end

          unless respond_to?(cmd[0])
            raise "no such command '#{cmd[0]}' in #{self.class} (#{__FILE__})"
          end
          cmds << cmd
        end

        cmds.each do |cmd|
          m = method(cmd[0]).parameters

          # only zero or one param
          raise "method #{cmd[0]} takes several parameters. This is a programming mistake. Ask Patrick to edit #{__FILE__}" if m.length > 1

          if m.length == 1
            if cmd.length > 1
              # in this case it always works
              puts send(cmd[0],cmd[1])
            elsif m[0][0] == :opt
              puts send(cmd[0])
            else
              # This means you didn't give parameter to command that wants an option
              raise "method #{cmd[0]} requires an option. please specify with #{cmd[0]}:parameter"
            end
          else
            if cmd.length > 1
              raise "method #{cmd[0]} does not take parameters and you gave parameter #{cmd[1]}"
            else
              puts send(cmd[0])
            end
          end
        end
      #rescue Exception => e
      #  puts "ERROR: #{e}"
      #  exit 1
      #end
    end

    def mysystem(cmd)
      system cmd
      raise "error running #{cmd} #{$?}" unless $?.success?
    end

    def fab # looking for python 'fabric'
      return @conf['cli']['fab'] if @conf['cli']['fab']

      try_files = %w[
        /usr/local/bin/fab
        /usr/bin/fab
        /opt/hdeploy/embedded/bin/fab
        /opt/hdeploy/bin/fab
      ]

      try_files.each do |f|
        return f if File.executable?(f)
      end

      raise "could not find fabric. tried #{try_files.join(' ')}"
    end

    # -------------------------------------------------------------------------
    def app(newapp)
      @app = newapp
      puts "set app to #{newapp}"
    end

    def list_servers(recipe = 'common')
      return @client.get("/srv_by_recipe/#{recipe}")
    end

    def prune_artifacts
      c = @conf['build'][@app]
      keepnum = c['prune'] || 5
      keepnum = keepnum.to_i

      artdir = c['artifact_dir']

      artlist = []
      Dir.entries(artdir).sort.each do |f|
        if f =~ /(#{@app}\..*)\.tar\.gz$/
          artlist << $1
        end
      end

      distributed_by_env = JSON.parse(@client.get("/distribute/#{@app}"))
      distributed = {}
      distributed_by_env.each do |env,list|
        list.each do |artname|
          distributed[artname] = true
        end
      end

      artlist = artlist.delete_if {|a| distributed.has_key? a }

      while artlist.length > keepnum
        art = artlist.shift
        artfile = art + ".tar.gz"
        puts "File.unlink #{File.join(artdir,artfile)}"
        File.unlink File.join(artdir,artfile)
      end
    end

    def prune_build_env
      c = @conf['build'][@app] #FIXME: error if the app doesn't exist
      keepnum = c['prune_build_env'] || 2
      keepnum = keepnum.to_i

      raise "incorrect dir config" unless c['build_dir']
      builddir = File.expand_path(c['build_dir'])
      return unless Dir.exists?(builddir)
      dirs = Dir.entries(builddir).delete_if{|d| d == '.' or d == '..' }.sort
      puts "build env pruning: keeping maximum #{keepnum} builds"

      while dirs.length > keepnum
        dirtodel = dirs.shift
        puts "FileUtils.rm_rf #{File.join(builddir,dirtodel)}"
        FileUtils.rm_rf File.join(builddir,dirtodel)
      end
    end

    def prune(prune_env='nowhere')
      _conf_fill_defaults
      c = @conf['build'][@app]
      prune_count = c['prune'].to_i #FIXME: integrity check.
      raise "no proper prune count" unless prune_count >= 3 and prune_count < 20

      dist = JSON.parse(@client.get("/distribute/#{@app}"))
      if dist.has_key? prune_env

        # Now we want to be careful to not eliminate any current artifact (ie. symlinked)
        # or any target either. Usually they would both be the same obviously.

        artifacts_to_keep = {}

        dist_states = JSON.parse(@client.get("/distribute_state/#{@app}"))
        dist_states.each do |dist_state|
          if prune_env == 'nowhere'
            # We take EVERYTHING into account
            artifacts_to_keep[dist_state['current']] = true
            dist_state['artifact_dir'].each do |art|
              artifacts_to_keep[art] = true
            end

          elsif dist_state['env'] == prune_env
            # Otherwise, we only take into account the current env
            artifacts_to_keep[dist_state['current']] = true
          end
        end

        # If the prune_env is not 'nowhere', we also want to keep the target
        # fixme: check integrity of reply
        artifacts_to_keep[@client.get("/target/#{@app}/#{prune_env}")] = true

        if dist[prune_env].length <= prune_count
          return "nothing to prune in env. #{prune_env}"
        end

        delete_max_count = dist[prune_env].length - prune_count
        delete_count = 0

        dist[prune_env].sort.each do |artifact|

          next if artifacts_to_keep.has_key? artifact

          delete_count += 1
          if prune_env == 'nowhere'
            # we must also delete file
            puts @client.delete("/artifact/#{@app}/#{artifact}")
          else
            puts @client.delete("/distribute/#{@app}/#{prune_env}/#{artifact}")
          end
          break if delete_count >= delete_max_count
        end

        return ""
      else
        return "Nothing to prune"
      end

      prune_artifacts
    end

    def state
      dist = JSON.parse(@client.get("/distribute/#{@app}"))
      dist_state = JSON.parse(@client.get("/distribute_state/#{@app}"))
      targets = JSON.parse(@client.get("/target/#{@app}"))

      # What I'm trying to do here is, for each artifact from 'dist', figure where it actually is.
      # For this, I need to know how many servers are active per env, then I can cross-reference the artifacts
      todisplay = {}
      dist.each do |env,artlist|
        next if env == 'nowhere'
        todisplay[env] = {}
        artlist.each do |art|
          todisplay[env][art] = []
        end
      end

      servers_by_env = {}
      current_links = {}

      dist_state.each do |stdata|
        env,hostname,artifacts,current = stdata.values_at('env','hostname','artifacts','current')

        servers_by_env[env] = {} unless servers_by_env.has_key? env
        servers_by_env[env][hostname] = true

        current_links[env] = {} unless current_links.has_key? env
        current_links[env][hostname] = current

        artifacts.each do |art|
          if todisplay.has_key? env
            if todisplay[env].has_key? art
              todisplay[env][art] << hostname
            end
          end
        end
      end

      # now that we have a servers by env, we can tell for each artifact what is distributed for it, and where it's missing.

      dist['nowhere'] ||= []

      ret = "---------------------------------------------------\n" +
            "Artifact distribution state for app #{@app}\n" +
            "---------------------------------------------------\n\n"

      ret += "Inactive: "
      if dist['nowhere'].length == 0
        ret += "none\n\n"
      else
        ret += "\n" + dist['nowhere'].collect{|art| "- #{art}"}.sort.join("\n") + "\n\n"
      end

      todisplay.each do |env,artifacts|
        servers_by_env[env] ||= {}
        srvnum = servers_by_env[env].length
        txt = "ENV \"#{env}\" (#{srvnum} servers)\n"
        ret += ("-" * txt.length) + "\n" + txt + ("-" * txt.length) + "\n"
        ret += "TARGET: " + targets[env].to_s

        # Consistent targets?
        current_by_art = {}
        non_target = []
        current_links[env] ||= {}
        current_links[env].each do |srv,link|
          non_target << srv if link != targets[env]
          current_by_art[link] = [] unless current_by_art.has_key? link
          current_by_art[link] << srv
        end
        if non_target.length > 0
          ret += " (#{non_target.length}/#{servers_by_env[env].length} servers not set to symlink target: #{non_target.join(', ')})\n\n"
        else
          ret += " (All OK)\n\n"
        end

        # distributed artifacts. Sort by key.
        artifacts.keys.sort.each do |art|
          hosts = artifacts[art]
          ret += "- #{art}"
          ret += " (target)" if art == targets[env]
          ret += " (current #{current_by_art[art].length}/#{servers_by_env[env].length})" if current_by_art.has_key? art

          # and if it's not distributed somewhere
          if hosts.length < servers_by_env[env].length
            ret += " (missing on: #{(servers_by_env[env].keys - hosts).join(', ')})"
          end

          ret += "\n"
        end
        ret += "\n"
      end

      if @verbose
        ret += "Server list\n"
        ret += JSON.pretty_generate(servers_by_env.map{|k,v| [k, v.keys] }.to_h) + "\n"
      end

      ret
    end

    def verbose
      @verbose = true
    end

    def force
      @force=true
    end

    def env(newenv)
      @env = newenv
      puts "set env to #{@env}"
    end

    def undistribute(build_tag)
      @client.delete("/distribute/#{@app}/#{@env}/#{build_tag}")
    end

    def help
      puts "Possible commands:"
      puts "  build (or build:branch)"
      puts "  distribute:nameofartifact"
      puts "  undistribute:nameofartifact"
      puts "  symlink:nameofartifact"
      puts "  fulldeploy:nameofartifact (combines distribute and symlink)"
      puts "  state"
      puts
      puts "option commands:"
      puts "  env:someenv"
      puts "  app:appname"
      puts
      puts "Example: hdeploy env:production build"
    end

    def fakebuild
      @fakebuild = true
    end

    def initrepo
      init()
    end

    def init
      _conf_fill_defaults
      c = @conf['build'][@app]
      repo_dir = File.expand_path(c['repo_dir'])

      if !(Dir.exists?(File.join(repo_dir,'.git')))
        FileUtils.rm_rf repo_dir
        FileUtils.mkdir_p File.join(repo_dir,'..')
        mysystem("git clone #{c['git']} #{repo_dir}")
      end
    end

    def notify(msg)
      puts "Notification: #{msg}"
      if File.executable?('/usr/local/bin/hdeploy_hipchat')
        mysystem("/usr/local/bin/hdeploy_hipchat #{msg}")
      end
    end

    def _hostmonkeypatch
      if @domain_name
        "host_monkeypatch:#{@domain_name} "
      else
        ''
      end
    end

    def _fab
      #FIXME: fabfile ie fab -f $(hdeploy_fabfile)"
      #FIXME: ensure this is Fabric 1.x
      #COmmand: pip install 'fabric<2.0'
      "fab" #FIXME: seach for binary?
    end

    def _conf_fill_defaults
      c = @conf['build']

      c['_default'] ||= {}
      {
        'build_dir' => '~/hdeploy_build/build/%s',
        'repo_dir' => '~/hdeploy_build/repos/%s',
        'artifact_dir' => '~/hdeploy_build/artifacts/%s',
        'artifact_url' => @conf['api']['endpoint'] + '/demo_only_repo/%s',
        'prune' => 5,
      }.each do |k,v|
        c['_default'][k] ||= v
      end

      c.each do |app,aconf|
        next if app == '_default'
        c['_default'].each do |k,v|
          aconf[k] ||= sprintf(v.to_s,app)
        end
      end
    end

    def build(branch = 'master')
      _conf_fill_defaults
      prune_build_env

      # Starting now..
      start_time = Time.new

      # Copy GIT directory
      c = @conf['build'][@app] # FIXME: sane defaults for artifacts directory
      c['artifact_dir'] = File.expand_path(c['artifact_dir'])
      repo_dir = File.expand_path(c['repo_dir'])

      raise "Error in source dir #{repo_dir}. Please run hdeploy initrepo" unless Dir.exists? (File.join(repo_dir, '.git'))
      directory = File.expand_path(File.join(c['build_dir'], (@app + start_time.strftime('.%Y%m%d_%H_%M_%S.'))) + ENV['USER'] + (@fakebuild? '.fakebuild' : ''))
      FileUtils.mkdir_p directory

      # Update GIT directory
      Dir.chdir(repo_dir)

      subgit  = `find . -mindepth 2 -name .git -type d`
      if subgit.length > 0
        subgit.split("\n").each do |d|
          if Dir.exists? d
            FileUtils.rm_rf d
          end
        end
      end

      [
        'git clean -xdf',
        'git reset --hard HEAD',
        'git clean -xdf',
        'git checkout master',
        'git pull',
        'git remote show origin',
        'git remote prune origin',
      ].each do |cmd|
        mysystem(cmd)
      end

      # Choose branch
      mysystem("git checkout #{branch}")

      if branch != 'master'
        [
          'git reset --hard HEAD',
          'git clean -xdf',
          'git pull'
        ].each do |cmd|
          mysystem(cmd)
        end
      end


      # Copy GIT
      if c.key?'subdir' # FIXME: error msg, existence, doc, etc.
        mysystem "rsync -av --exclude=.git #{c['repo_dir']}/ #{directory}/"
      else
        mysystem "rsync -av --exclude=.git #{c['repo_dir']}/#{c['subdir']}/ #{directory}/"
      end

      # Get a tag
      gitrev = (`git log -1 --pretty=oneline`)[0..11] # not 39.
      build_tag = @app + start_time.strftime('.%Y%m%d_%H_%M_%S.') + branch + '.' + gitrev + '.' + ENV['USER'] + (@fakebuild? '.fakebuild' : '')

      notify "build start - #{ENV['USER']} - #{build_tag}"

      Dir.chdir(directory)

      # Write the tag in the dest directory
      File.write 'REVISION', (gitrev + "\n")

      # Run the build process # FIXME: add sanity check
      try_files = %w[./build.sh build/build.sh hdeploy/build.sh]
      if File.exists? 'hdeploy.ini'
        repoconf = JSON.parse(File.read('hdeploy.json'))['global']
        try_files.unshift(repoconf['build_script']) if repoconf['build_script']
      end

      unless @fakebuild
        build_script = false
        try_files.each do |f|
          if File.exists?(f) and File.executable?(f)
            build_script = f
            break
          end
        end

        raise "no executable build script file. Tried files: #{try_files.join(' ')}" unless build_script
        mysystem(build_script)
      end

      # Make tarball
      FileUtils.mkdir_p c['artifact_dir'] #FIXME: check for existence of artifacts
      mysystem("tar czf #{File.join(c['artifact_dir'],build_tag)}.tar.gz .")

      # FIXME: upload to S3
      register_tarball(build_tag)

      notify "build success - #{ENV['USER']} - #{build_tag}"

      prune_build_env
    end

    def register_tarball(build_tag)
      # Register tarball
      filename = build_tag + '.tar.gz'
      checksum = Digest::MD5.file(File.join(@conf['build'][@app]['artifact_dir'], filename))

      @client.put("/artifact/#{@app}/#{build_tag}", JSON.pretty_generate({
        source: @conf['build'][@app]['artifact_url'] + "/#{filename}",
        altsource: "",
        checksum: checksum,
      }))
    end

    def fulldeploy(build_tag)
      distribute(build_tag)
      symlink(build_tag)
    end

    def distribute(build_tag)
      r = @client.put("/distribute/#{@app}/#{@env}",build_tag)
      if r =~ /^OK /
        h = JSON.parse(@client.get("/srv/by_app/#{@app}/#{@env}"))

        if h.count == 0
          raise "Currently, no servers in env '#{@env}' that are ready for app '#{@app}' - but if you add some they will get the code..."
        end

        # On all servers, do a standard check deploy.
        system("#{_fab} -H #{h.keys.join(',')} -P #{_hostmonkeypatch()}-- sudo hdeploy_node check_deploy")

        # And on a single server, run the single hook.
        hookparams = { app: @app, env: @env, artifact: build_tag, servers:h.keys.join(','), user: ENV['USER'] }.collect {|k,v| "#{k}:#{v}" }.join(" ")
        system("#{_fab} -H #{h.keys.sample} -P #{_hostmonkeypatch()}-- 'echo #{hookparams} | sudo hdeploy_node post_distribute_run_once'")
      end
    end

    # Does this really have to exist? Or should I just put it in the symlink method?
    def target(artid = 'someid')

      # We just check if the artifact is set to be distributed to the server
      # for the actual presence we will only check in the symlink part.

      todist = JSON.parse(@client.get("/distribute/#{@app}/#{@env}"))
      raise "artifact #{artid} is not set to be distributed for #{@app}/#{@env} - please choose in this list: #{todist.keys}" unless todist.has_key? artid
      return @client.put("/target/#{@app}/#{@env}", artid)
    end

    def symlink(target)
      target(target)

      h = JSON.parse(@client.get("/srv/by_app/#{@app}/#{@env}"))

      raise "no server with #{@app}/#{@env}" unless h.keys.length > 0
      h.each do |host,conf|
        if !(conf['artifacts'].include? target)
          raise "artifact #{target} is not present on server #{host}. Please run hdeploy env:#{@env} distribute:#{target}"
        end
      end

      # On all servers, do a standard symlink
      system("#{_fab}  -H #{h.keys.join(',')} -P #{_hostmonkeypatch()}-- 'echo app:#{@app} env:#{@env} force:true | sudo hdeploy_node symlink'")

      # And on a single server, run the single hook.
      hookparams = { app: @app, env: @env, artifact: target, servers:h.keys.join(','), user: ENV['USER'] }.collect {|k,v| "#{k}:#{v}" }.join(" ")
      system("#{_fab} -H #{h.keys.sample} -P #{_hostmonkeypatch()}-- 'echo #{hookparams} | sudo hdeploy_node post_symlink_run_once'")
    end
  end
end

