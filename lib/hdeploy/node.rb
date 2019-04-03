require 'curb'
require 'json'
require 'fileutils'
require 'pathname'
require 'inifile'

module HDeploy
  class Node

    def initialize
      @conf = HDeploy::Conf.instance #FIXME search for the configuration at the right place
      @conf.add_defaults({
        'node' => {
          'keepalive_delay' => 60,
          'check_deploy_delay' => 60,
          'max_run_duration' => 3600,
          'hostname' => `/bin/hostname`.chomp,
        }
      })

      # eliminate training slash
      if @conf['api']['endpoint'].end_with? '/'
        @conf['api']['endpoint'].chop!
      end

      # Check for needed configuration parameters
      # API
      api_params = %w[http_user http_password endpoint]
      raise "#{@conf.file}: you need 'api' section for hdeploy node (#{api_params.join(', ')})" unless @conf['api']
      api_params.each do |p|
        raise "#{@conf.file}: you need param for hdeploy node: api/#{p}" unless @conf['api'][p]
      end

      # Deploy
      raise "#{@conf.file}: you need 'deploy' section for hdeploy node" unless @conf['deploy']
      @conf['deploy'].keys.each do |k|
        raise "#{@conf.file}: deploy key must be in the format app:env - found #{k}" unless k =~ /^[a-z0-9\-\_]+:[a-z0-9\-\_]+$/
      end

      default_user = Process.uid == 0 ? 'www-data' : Process.uid
      default_group = Process.gid == 0 ? 'www-data' : Process.gid

      @conf['deploy'].each do |k,c|
        raise "#{@conf.file}: deploy section '#{k}': missing symlink param" unless c['symlink']
        c['symlink'] = File.expand_path(c['symlink'])

        # FIXME: throw exception if user/group are root and/or don't exist
        {
          'relpath' => File.expand_path('../releases', c['symlink']),
          'tgzpath' => File.expand_path('../tarballs', c['symlink']),
          'user' => default_user,
          'group' => default_group,
          'quorum_force_deploy' => true,
        }.each do |k2,v|
          c[k2] ||= v
        end

        # It's not a mistake to check for uid in the gid section: only root can change gid.
        # FIXME: syntax errors, check for user, blah blah
        uid = (c['user'].is_a? Integer)  ? c['user']  : Etc.getpwnam(c['user']).uid
        gid = (c['group'].is_a? Integer) ? c['group'] : Etc.getgrnam(c['group']).gid

        raise "You must run hdeploy node as uid root if you want a different user for deploy #{k}" if Process.uid != 0 and uid != Process.uid
        raise "You must run hdeploy node as gid root if you want a different group for deploy #{k}" if Process.uid != 0 and gid != Process.gid
      end
    end

    # -------------------------------------------------------------------------
    def run
      # Performance: require here so that launching other stuff doesn't load the library
      require 'eventmachine'

      # FIXME: add defaults

      EM.run do
        repeat_action('/usr/local/bin/hdeploy_node keepalive',   @conf['node']['keepalive_delay'].to_i,0)
        repeat_action('/usr/local/bin/hdeploy_node check_deploy',@conf['node']['check_deploy_delay'].to_i,100)
        EM.add_timer(@conf['node']['max_run_duration'].to_i) do
          puts "has run long enough"
          EM.stop
        end
      end
    end

    def repeat_action(cmd,delay,splay=0)
      EM.system(cmd,proc do |output,status|
        puts "CMD END: #{cmd} #{status} #{output.strip}"
        EM.add_timer(((status.success?) ? delay+rand(splay+1) : 5),proc{repeat_action(cmd,delay,splay)})
      end
      )
    end

    # -------------------------------------------------------------------------
    def keepalive
      hostname = @conf['node']['hostname']
      c = Curl::Easy.new(@conf['api']['endpoint'] + '/srv/keepalive/' + hostname)
      c.http_auth_types = :basic
      c.username = @conf['api']['http_user']
      c.password = @conf['api']['http_password']
      c.put((@conf['node']['keepalive_delay'].to_i * 2).to_s)
    end

    def put_state
      hostname = @conf['node']['hostname']

      c = Curl::Easy.new(@conf['api']['endpoint'] + '/distribute_state/' + hostname)
      c.http_auth_types = :basic
      c.username = @conf['api']['http_user']
      c.password = @conf['api']['http_password']

      r = []

      # Will look at directories and figure out current state
      @conf['deploy'].each do |section,conf|
        app,env = section.split(':')

        relpath,tgzpath,symlink = conf.values_at('relpath','tgzpath','symlink')

        # could be done with ternary operator but I find it more readable like that.
        current = "unknown"
        if File.symlink? symlink and Dir.exists? symlink
          current = File.basename(File.readlink(symlink))
        end

        # For artifacts, what we want is a directory, that contains the file "READY"
        artifacts = Dir.glob(File.join(relpath, '*', 'READY')).map{|x| File.basename(File.expand_path(File.join(x,'..'))) }

        r << {
          app: app,
          env: env,
          current: current,
          artifacts: artifacts.sort,
        }

      end

      puts JSON.pretty_generate(r) if ENV.has_key?'DEBUG'
      c.put(JSON.generate(r))
    end

    def find_executable(name) #FIXME should be in some other path
      %w[
        /opt/hdeploy/embedded/bin
        /opt/hdeploy/bin
        /usr/local/bin
        /usr/bin
        /sbin
        /bin
      ].each do |p|
        e = File.join p,name
        next unless File.exists? e
        st = File.stat(e)
        next unless st.uid == 0
        next unless st.gid == 0
        if sprintf("%o", st.mode) == '100755'
          return e
        else
          warn "file #{file} does not have permissions 100755"
        end
      end
      return nil
    end

    def checksum_file(file, checksum = nil)
      if checksum.nil?
        puts "Skipping checksum for #{file} as it was not specified"
        return true
      else
        calcdigest = Digest::MD5.file(file)
        return true if calcdigest == checksum
        puts "incorrect checksum for #{file} (got #{calcdigest} expected #{checksum})"
      end
      false
    end

    def fetch_file(url, destfile, checksum = nil, retries = 5)
      destpath = File.dirname(destfile)

      count = 0
      while count < retries and !(File.exists?(destfile) and checksum_file(destfile,checksum))
        count += 1
        File.unlink(destfile) if File.exists?(destfile)

        if f = find_executable('aria2c')
          puts("#{f} -x 5 -d #{destpath} -o #{destfile} #{url}")
          system("#{f} -x 5 -d #{destpath} -o #{destfile} #{url}")

        elsif f = find_executable('wget')
          puts("#{f} -O #{destfile} #{url}")
          system("#{f} -O #{destfile} #{url}")

        elsif f = find_executable('curl')
          puts("#{f} -o #{destfile} #{url}")
          system("#{f} -o #{destfile} #{url}")

        else
          raise "no aria2c, wget or curl available. please install one of them."
        end
      end

      raise "unable to download file #{destfile} from #{url}" unless File.exists? destfile
      raise "checksum" unless checksum_file(destfile, checksum)
    end

    def check_deploy
      put_state

      c = Curl::Easy.new()
      c.http_auth_types = :basic
      c.username = @conf['api']['http_user']
      c.password = @conf['api']['http_password']

      # Now this is the big stuff
      @conf['deploy'].each do |section,conf|
        app,env = section.split(':') #it's already checked for syntax higher in the code

        # Here we get the info.
        # FIXME: double check that config is ok
        relpath,tgzpath,symlink,user,group,quorum_force_deploy = conf.values_at('relpath','tgzpath','symlink','user','group','quorum_force_deploy')

        # Now the release info from the server
        c.url = @conf['api']['endpoint'] + '/distribute/' + app + '/' + env
        c.perform

        # prepare directories
        FileUtils.mkdir_p(relpath)
        FileUtils.mkdir_p(tgzpath)

        artifacts = JSON.parse(c.body_str)
        puts "found #{artifacts.keys.length} artifacts for #{app} / #{env}"

        dir_to_keep = []
        tgz_to_keep = []

        artifacts.each do |artifact,artdata|
          source = JSON.parse(artdata['source'])
          puts "checking artifact #{artifact}"
          destdir   = File.join relpath,artifact
          tgzfile   = File.join tgzpath,(artifact+'.tar.gz')
          readyfile = File.join destdir,'READY'

          if !(File.exists?readyfile)
            # we have to release. let's cleanup.
            FileUtils.rm_rf(destdir) if File.exists?(destdir)
            FileUtils.mkdir_p destdir
            FileUtils.chown user, group, destdir
            Dir.chdir destdir

            # Quick sanity check: only one decompress file
            # Might do it later on but for now it's not urgent
            raise "More than one decompress file we can't handle this" if source.values.select{|v| v['decompress'] }.count > 1

            # Now we go through sources
            source.sort.each do |file,sourcedata|
              if sourcedata['decompress']
                # First download to tgz dir and then decompress
                # FIXME add support for altsource/url
                fetch_file(sourcedata['url'], tgzfile, sourcedata['checksum'])
                tar = find_executable('tar')

                chpst = ''
                if Process.uid == 0
                  chpst = find_executable('chpst') or raise "unable to find chpst binary"
                  chpst += " -u #{user}:#{group} "
                end
                system("#{chpst}#{tar} xzf #{tgzfile}") or raise "unable to extract #{tgzfile} as #{user}:#{group}"
              else
                # This is just a file that we are putting as-is in the directory
                # FIXME this should contain some security check like does this have a .. or a / in it or something
                # FIXME add support for altsource/url
                fetch_file(sourcedata['url'], file, sourcedata['checksum'])
              end
            end

            File.chmod 0755, destdir

            # Post distribute hook
            run_hook('post_distribute', {'app' => app, 'env' => env, 'artifact' => artifact})
            FileUtils.touch(readyfile) #FIXME: root?
          end

          # we only get here if previous step worked.
          tgz_to_keep << File.expand_path(tgzfile)
          dir_to_keep << File.expand_path(destdir)
        end

        # Should we symlink? Passing the artifacts as 'probe'
        symlink({'app' => app,'env' => env, 'force' => false, 'quorum_force_deploy' => quorum_force_deploy, 'probe' => artifacts})

        # cleanup
        if Dir.exists? conf['symlink']
          dir_to_keep << File.expand_path(File.join(File.join(conf['symlink'],'..'),File.readlink(conf['symlink'])))
        end

        (Dir.glob(File.join conf['relpath'], '*') - dir_to_keep).each do |d|
          puts "cleanup dir #{d}"
          FileUtils.rm_rf d
        end

        (Dir.glob(File.join conf['tgzpath'],'*') - tgz_to_keep).each do |f|
          puts "cleanup file #{f}"
          File.unlink f
        end

      end
      put_state
    end

    def run_hook(hook,params)
      # This is a generic function to run the hooks defined in hdeploy.json.
      # Standard hooks are

      app,env,artifact = params.values_at('app','env','artifact')

      oldpwd = Dir.pwd

      raise "no such app/env #{app} / #{env}" unless @conf['deploy'].has_key? "#{app}:#{env}"

      relpath,user,group = @conf['deploy']["#{app}:#{env}"].values_at('relpath','user','group')
      destdir = File.join relpath,artifact

      hookfile = File.join destdir, 'hdeploy', "#{hook}.sh"

      if File.exists? hookfile
        raise "non-executable file #{hookfile} for hook #{hook}" unless File.executable?(hookfile)
      else
        puts "No hook file for #{hook} (look for #{hookfile} - doing nothing"
        return
      end

      # OK let's run the hook
      Dir.chdir destdir

      chpst = ''
      if Process.uid == 0
        chpst = find_executable('chpst') or raise "unable to find chpst binary"
        chpst += " -u #{user}:#{group} "
      end

      system("#{chpst}#{hookfile} '#{JSON.generate(params)}'")
      if $?.success?
        puts "Successfully run #{hook} hook / #{hookfile}"
        Dir.chdir oldpwd
      else
        Dir.chdir oldpwd
        raise "Error while running file #{hookfile} hook #{hook} : #{$?} - (DEBUG: (pwd: #{destdir}): #{chpst}#{hookfile} '#{JSON.generate(params)}'"
      end
    end

    def symlink(params)
      # NOTE: the probe data is the value of a /distribute/app/env query
      # Not just true/false
      app,env,force,quorum_force_deploy,probe = params.values_at('app','env','force','quorum_force_deploy','probe')
      force = false if force.nil?
      quorum_force_deploy = false if quorum_force_deploy.nil?

      raise "no such app/env #{app} / #{env}" unless @conf['deploy'].has_key? "#{app}:#{env}"

      conf = @conf['deploy']["#{app}:#{env}"]
      link,relpath = conf.values_at('symlink','relpath')

      target = false
      current_link_is_correct = false

      if quorum_force_deploy
        # Probe contains the target so no need to do an extra query
        target = probe.select{|k,v| v['target']}
        if target.count == 1
          target = target.keys.first
        else
          # No target
          puts "No target for #{app}/#{env} currently set - doing nothing"
          return
        end
      else
        if force or !(File.exists?link)
          # We're not probing but we still wanna check things
          c = Curl::Easy.new(@conf['api']['endpoint'] + '/target/' + app + '/' + env)
          c.http_auth_types = :basic
          c.username = @conf['api']['http_user']
          c.password = @conf['api']['http_password']
          c.perform
          target = c.body_str

          if target == "unknown"
            puts "No target for #{app}/#{env} current set - doing nothing"
            return
          end
        else
          puts "No force and there's already a file on #{link} - doing nothing"
          return
        end
      end

      # We got here in the code - it means that we do have a target
      target_relative_path = Pathname.new(File.join relpath,target).relative_path_from(Pathname.new(File.join(link,'..'))).to_s
      if File.symlink?(link) and (File.readlink(link) == target_relative_path)
        puts "Symlink for app #{app} is already OK (#{target_relative_path}"
        return
      else
        # This is where we decide to maybe do something
        if quorum_force_deploy and !force # force always decides to do something
          c = Curl::Easy.new(@conf['api']['endpoint'] + '/target_state/' + app + '/' + env)
          c.http_auth_types = :basic
          c.username = @conf['api']['http_user']
          c.password = @conf['api']['http_password']
          c.perform
          target_state = JSON.parse(c.body_str)

          if target_state.count == 0
            puts "No current state for #{app}/#{env} - nothing to check against"
          else
            # Let's continue
          # Now we count which has what
            current_state_counts = {}
            target_state.each do |data|
              current_state_counts[data['current']] ||= 0
              current_state_counts[data['current']] += 1
            end

            # Sort by number then alphabetical - and get the artifact name
            quorum_state_target,quorum_state_count = current_state_counts.sort_by{|c| [ c.last, c.first ]}.last
            if quorum_state_count >= (target_state.count.to_f / 2).ceil.to_i and quorum_state_target == target
              puts "quorum_force_deploy: The majority of other servers have the current target for #{app}/#{env} - setting - setting distribute force for myself"
              force = true
            else
              puts "quorum_force_deploy: The target is different from current state but most servers haven't upgraded to it (yet?) - assuming force symlink hasn't been run"
            end
          end
        end
      end

      if force or !(File.exists?link)
        FileUtils.rm_rf(link) unless File.symlink?link

        # atomic symlink override
        puts "setting symlink for app #{app} to #{target_relative_path}"
        File.symlink(target_relative_path,link + '.tmp') #FIXME: should this belong to root?
        File.rename(link + '.tmp', link)
        put_state

        run_hook('post_symlink', {'app' => app, 'env' => env, 'artifact' => target})
      else
        puts "not changing symlink for app #{app}"
      end
    end

  end
end
