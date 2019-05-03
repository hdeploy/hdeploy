require 'hdeploy/apiclient'
require 'json'
require 'fileutils'
require 'inifile'
require 'digest'
require 'base64'
require 'net/ssh/multi'

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
      @verbose = false
      @ignore_errors = false


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

          if @@cli_methods.key?(cmd[0].to_sym)
            #puts "command #{cmd[0]}: loaded as cli method"
          else
            puts "command #{cmd[0]}: not loaded as cli method"
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

    def mysystem(cmd, ignore_errors = false)
      puts "Debug: running #{cmd}"
      system cmd
      raise "error running #{cmd} #{$?}" unless ignore_errors or $?.success?
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
    @@cli_methods = {}

    def self.cli_method(method_name, help = '', &block)
      @@cli_methods[method_name] = help
      define_method(method_name, &block)
    end

    # -------------------------------------------------------------------------
    cli_method(:help, 'Show the help') do

      ret  = "=======================\n"
      ret += " HDEPLOY CLI TOOL HELP\n"
      ret += "=======================\n"
      ret += "\n"
      ret += "Some commands are modifiers for others, ie. app, env, verbose\n"
      ret += "and should be set BEFORE the actual command, since they are processed in order\n"
      ret += "\n"
      ret += "Unless you are running a single app in your environment, in which case you could set it\n"
      ret += "as default, you probably want to specify app:yourappname prior to nearly every command\n"
      ret += "\n"
      ret += "Commands list:\n"

      text = {}
      @@cli_methods.keys.sort.each do |cmd|
        line = "  #{cmd}"
        # param[1] is the name of the option
        line += method(cmd).parameters.map{|param| param[0] == :req ? ":#{param[1]}" : "[:#{param[1]}]" }.join
        text[cmd] = line
      end

      maxlength = text.values.map(&:length).max

      text.each do |cmd,line|
        ret += line + (' ' * (maxlength - line.length + 2)) + @@cli_methods[cmd] + "\n"
      end

      ret + "\n"
    end

    # -------------------------------------------------------------------------
    cli_method(:verbose, "Modifier for other commands") do
      @verbose = true
    end

    cli_method(:ignore_errors, "Modifier for other commands") do
      @ignore_errors = true
    end

    cli_method(:app, "Modifier for other commands - sets current app") do |appname|
      @app = appname
      puts "set app to #{appname}"
    end

    # -------------------------------------------------------------------------
    cli_method(:upload_artifact, "Upload a file to configured location(s)") do |file|

      _conf_fill_defaults # unless already filled?
      build_tag = File.basename(file,'.tar.gz') #FIXME: only supports .tar.gz at this point...

      # Currently, artifacts can be uploaded to four different places: local directory, S3, scp location, artifactory, and a local directory
      # The configuration directives are such: { "build": { "nameofapp": { "upload_locations": [ { ... upload destination data here ... } ] } }
      # Format of the upload destination data in README.md

      @conf['build'][@app]['upload_locations'].each do |upload_location|
        next if upload_location.key? 'active' and not upload_location['active']

        case upload_location['type']

        # -------------------------------------------------------------------------
        when 'directory'
        # -------------------------------------------------------------------------
          destdir = File.expand_path(sprintf(upload_location['directory'], @app))

          FileUtils.mkdir_p destdir unless File.directory? destdir

          if File.stat(file).dev == File.stat(destdir).dev
            # Same dev: hard link
            puts "Hardlink #{file} to #{destdir}"
            File.link(file, File.join(destdir,File.basename(file)))
          else
            # Different dev: copy
            puts "Copy #{file} to #{destdir}"
            FileUtils.cp(file, destdir)
          end


        # -------------------------------------------------------------------------
        when 's3'
        # -------------------------------------------------------------------------
          puts "s3: work in progress"
          require 'aws-sdk-s3'
          s3 = Aws::S3::Client.new(access_key_id: upload_location['access_key'], secret_access_key: upload_location['secret_key'])
          bucket, prefix = upload_location.values_at('bucket', 'prefix')
          prefix += '/' unless prefix.end_with? '/'
          objkey = prefix + File.basename(file)

          unless upload_location['overwrite'] == true
            puts "Check for prior existence of object"
            begin
              s3.get_object_acl(bucket: bucket, key: objkey)
              raise "Object #{bucket} / #{objkey} already exists"
            rescue Aws::S3::Errors::NoSuchKey
              # This is actually good
              puts "Doesn't exist"
            end
          end

          puts "Upload #{file} to s3://#{upload_location['bucket']}/#{prefix}#{File.basename(file)} ..."

          File.open(file, 'rb') do |io|
            s3.put_object(bucket: bucket, key: objkey, body: io)
          end

        # -------------------------------------------------------------------------
        when 'scp'
        # -------------------------------------------------------------------------
          puts "scp: work in progress"

        # -------------------------------------------------------------------------
        when 'http'
        # -------------------------------------------------------------------------
          require 'curb'
          c = Curl::Easy.new()
          c.http_auth_types = :basic
          c.username = upload_location['user']
          c.password = upload_location['password']

          dest_url = sprintf(upload_location['url'], @app)
          dest_url += '/' unless dest_url.end_with? '/'
          c.url = dest_url + File.basename(file)

          case upload_location['method'].upcase
          when 'PUT'
            c.http_put(File.read(file))
          when 'POST'
            c.http_post(File.read(file))
          else
            raise "Supported methods PUT POST"
          end

          raise "response code was #{c.response_code}" unless c.response_code == 200
        else
          raise "Supported upload types directory/sc3/scp/http (got: #{upload_location['type']})"
        end

      end
      ''
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

    # -------------------------------------------------------------------------
    cli_method(:prune, "Deletes oldest artifacts in specified environment - defaults to unused artifacts only") do |prune_env='nowhere'|
      _conf_fill_defaults
      c = @conf['build'][@app]

      if not c.nil? and c.key?'prune'
        prune_count = c['prune'].to_i #FIXME: integrity check.
        raise "no proper prune count" unless prune_count >= 3 and prune_count < 20
      else
        # Just default to 5
        prune_count = 5
      end

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
            dist_state['artifacts'].each do |art|
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

    cli_method(:state, "for current app - add verbose before to get a server list") do
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

    cli_method(:env, 'Set environment for following command ie. dev stg prd etc') do |envname|
      @env = envname
      puts "set env to #{@env}"
    end

    cli_method(:undistribute, "Revokes distribution for an artifact (usually used for cleanup)") do |artifact_id|
      @client.delete("/distribute/#{@app}/#{@env}/#{artifact_id}")
    end

    cli_method(:unregister, "Deletes an artifact from the database - fully") do |artifact_id|
      @client.delete("/artifact/#{@app}/#{artifact_id}")
    end

    cli_method(:init, "Alias for initrepo") do
      init()
    end

    cli_method(:initrepo, "Clones repository locally for build") do
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
        mysystem("/usr/local/bin/hdeploy_hipchat #{msg}", true)
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

      (ENV.key?'fab_sshkey') ? "fab -i #{ENV['fab_sshkey']}" : "fab"
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
          if v.is_a? String
            aconf[k] ||= sprintf(v.to_s,app)
          else
            aconf[k] ||= v
          end
        end
      end
    end

    cli_method(:register_multifile_artifact_urls, "Registers multifile artifacts URLs") do |name_urls_and_checksums|
      _conf_fill_defaults

      # Check that there are the same number of URLs and checksums, separated by commas. This effectively only supports a few
      ar = name_urls_and_checksums.split(',')
      build_tag = ar.shift()
      raise "You need artifact name (build tag), followed by file/url/checksum triplets, separated by commas, and this is a wrong number of items (1 + #{ar.count}" unless ar.count % 3 == 0 and ar.count>0

      source = {}

      ar.each_slice(3) do |file,url,checksum|
        #raise "File must be in a good format" unless file =~
        raise "Checksum must be in MD5 format 32 hex characters" unless checksum =~ /^[a-f0-9]{32}$/

        if url.start_with?'BASE64:'
          # This is inline content
          source[file] = {
            inline_content: Base64.decode64(url[7..-1]),
            checksum: checksum,
            decompress: false,
          }
        else
          raise "URL #{url} does not match regex" unless url =~ /(^$)|(^(http|https):\/\/[a-z0-9]+([\-\.]{1}[a-z0-9]+)*\.[a-z]{2,5}(([0-9]{1,5})?\/.*)?$)/ix

          source[file] = {
            url: url,
            checksum: checksum,
            decompress: false,
          }
        end
      end

      # push that as app name / artifact / env / urls
      @client.put("/artifact/#{@app}/#{build_tag}", JSON.pretty_generate(source))

      "OK Registered #{build_tag} with #{source.count} file(s)"
    end

    cli_method(:build, "Runs a local build and registers given tarball - defaults to master") do |branch = 'master'|
      _conf_fill_defaults
      prune_build_env

      # Starting now..
      start_time = Time.new

      # Copy GIT directory
      c = @conf['build'][@app] # FIXME: sane defaults for artifacts directory
      c['artifact_dir'] = File.expand_path(c['artifact_dir'])
      repo_dir = File.expand_path(c['repo_dir'])

      raise "Error in source dir #{repo_dir}. Please run hdeploy initrepo" unless Dir.exists? (File.join(repo_dir, '.git'))
      directory = File.expand_path(File.join(c['build_dir'], (@app + start_time.strftime('.%Y%m%d_%H_%M_%S.'))) + ENV['USER'])
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
        mysystem(cmd, true)
      end

      # Choose branch
      mysystem("git checkout #{branch}")

      if branch != 'master'
        [
          'git reset --hard HEAD',
          'git clean -xdf',
          'git pull'
        ].each do |cmd|
          mysystem(cmd, true)
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
      build_tag = @app + start_time.strftime('.%Y%m%d_%H_%M_%S.') + branch + '.' + gitrev + '.' + ENV['USER']

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

      build_script = false
      try_files.each do |f|
        if File.exists?(f) and File.executable?(f)
          build_script = f
          break
        end
      end

      raise "no executable build script file. Tried files: #{try_files.join(' ')}" unless build_script
      mysystem(build_script)

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

    cli_method(:fulldeploy, "Does distribute + symlink in a single command") do |artifact_id|
      distribute(artifact_id)
      symlink(artifact_id)
    end

    cli_method(:distribute, "Sets an artifact to be deployed (without actual activation)") do |build_tag|
      r = @client.put("/distribute/#{@app}/#{@env}",build_tag)
      if r =~ /^OK /
        h = JSON.parse(@client.get("/srv/by_app/#{@app}/#{@env}"))

        if h.count == 0
          raise "Currently, no servers in env '#{@env}' that are ready for app '#{@app}' - but if you add some they will get the code..."
        end

        # On all servers, do a standard check deploy.
        mysystem("#{_fab} -H #{h.keys.join(',')} -P #{_hostmonkeypatch()}-- sudo /usr/local/bin/hdeploy_node check_deploy", @ignore_errors)

        # And on a single server, run the single hook.
        hookparams = { app: @app, env: @env, artifact: build_tag, servers:h.keys.join(','), user: ENV['USER'] }.collect {|k,v| "#{k}:#{v}" }.join(" ")
        mysystem("#{_fab} -H #{h.keys.sample} -P #{_hostmonkeypatch()}-- 'echo #{hookparams} | sudo /usr/local/bin/hdeploy_node post_distribute_run_once'", @ignore_errors)
      end
    end

    # Does this really have to exist? Or should I just put it in the symlink method?
    cli_method(:target, "Sets a previously deployed artifact as target - you usually would prefer to run 'symlink' than this command") do |artifact_id|

      # We just check if the artifact is set to be distributed to the server
      # for the actual presence we will only check in the symlink part.

      todist = JSON.parse(@client.get("/distribute/#{@app}/#{@env}"))
      raise "artifact #{artifact_id} is not set to be distributed for #{@app}/#{@env} - please choose in this list: #{todist.keys}" unless todist.has_key? artifact_id
      return @client.put("/target/#{@app}/#{@env}", artifact_id)
    end

    cli_method(:symlink, "Sets target artifact in a given app/env and then actually runs the symlink and post deploy scripts") do |artifact_id|
      target(artifact_id)

      h = JSON.parse(@client.get("/srv/by_app/#{@app}/#{@env}"))

      raise "no server with #{@app}/#{@env}" unless h.keys.length > 0
      h.each do |host,conf|
        if !(conf['artifacts'].include? artifact_id)
          raise "artifact #{artifact_id} is not present on server #{host}. Please run hdeploy app:#{@app} env:#{@env} distribute:#{artifact_id}"
        end
      end

      # On all servers, do a standard symlink
      mysystem("#{_fab}  -H #{h.keys.join(',')} -P #{_hostmonkeypatch()}-- 'echo app:#{@app} env:#{@env} force:true | sudo /usr/local/bin/hdeploy_node symlink'", @ignore_errors)

      # And on a single server, run the single hook.
      hookparams = { app: @app, env: @env, artifact: artifact_id, servers:h.keys.join(','), user: ENV['USER'] }.collect {|k,v| "#{k}:#{v}" }.join(" ")
      mysystem("#{_fab} -H #{h.keys.sample} -P #{_hostmonkeypatch()}-- 'echo #{hookparams} | sudo /usr/local/bin/hdeploy_node post_symlink_run_once'", @ignore_errors)
    end

    cli_method(:symlink2, "test") do
      h = JSON.parse(@client.get("/srv/by_app/#{@app}/#{@env}"))

      Net::SSH::Multi.start(:concurrent_connections => 5) do |session|

        h.keys.each do |srv|
          session.use srv
        end

        session.exec 'uptime ; sleep 5'

      end

      h.keys

      require 'pry'
      binding.pry
    end

  end
end

