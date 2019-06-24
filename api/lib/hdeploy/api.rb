require 'sinatra/base'
require 'json'
require 'hdeploy/conf'
require 'hdeploy/database'
require 'hdeploy/policy'
require 'pry'

#require 'hdeploy/policy'

module HDeploy
  class API < Sinatra::Base

    def initialize
      super

      @conf = HDeploy::Conf.instance
      @db = HDeploy::Database.factory

      # Decorator load - this is a bit of a hack but it's really nice to have this syntax
      # We just write @something before a action and the system will parse it


    end

    @@api_help = {}

    def self.api_endpoint(method, uri, policy_action_name, description, &block)
      # Magic: we are reading app/env from block args
      # Why am I doing this here rather than inside a single send? Because that way
      # it's evaluated only at startup, vs evaluated at each call
      @@api_help["#{method.upcase} #{uri}"] = {
        policy_action_name: policy_action_name,
        description: description,
      }

      if policy_action_name.nil?
        # This is a no authorization thing - just send as-is
        send(method, uri, &block)
      else
        if block.parameters.map{|p| p.last}.include? :app
          send(method, uri) do |*args|
            authorized?(policy_action_name, params[:app], params[:env])
            instance_exec(*args, &block)
          end
        elsif block.parameters.map{|p| p.last}.include? :env
          send(method, uri) do |*args|
            authorized?(policy_action_name, args.first, params[:env])
            # The instance exec passes the env such as request params etc
            instance_exec(*args, &block)
          end
        else
          # No specifics - env defaults to nil
          send(method, uri) do |*args|
            authorized?(policy_action_name, args.first)
            instance_exec(*args, &block)
          end
        end
      end
    end

    # -----------------------------------------------------------------------------
    # Some Auth stuff
    # This processes Authentication and authorization
    def authorized?(action, app, env=nil)
      raise "app must match /^[A-Za-z0-9\\-\\_\\.]+$/" unless app =~ /^[A-Za-z0-9\-\_\.]+$/
      raise "env must match /^[A-Za-z0-9\\-\\_]+$/" unless env =~ /^[A-Za-z0-9\-\_]+$/ or env.nil?

      puts "Process AAA #{action} app:#{app} env:#{env}"

      # We do first authentication and then once we know who we are, we do authorization
      auth = Rack::Auth::Basic::Request.new(request.env)
      if auth.provided? and auth.basic?
        user,pass = auth.credentials
        # First search in local authorizations
        begin
          user = HDeploy::User.search_local(user,pass) # This will raise an exception if the user exists but it's a wrong pw
        rescue Exception => e
          puts "#{e} - #{e.backtrace}"
          denyacl("Authentication failed 1")
        end

        # If not, search in LDAP
        # TODO
        if user.nil? or user == false
          denyacl("No user")
        end

        # OK so in the variable user we have the current user with the loaded policies etc
        if user.evaluate(action, "#{app}:#{env}")
          # User was authorized
        else
          denyacl("Authorization failed", 403)
        end

      else
        denyacl("No authentication provided")
      end
    end

    def denyacl(msg,code=401)
      puts "Denied ACL: #{msg}"
      headers['WWW-Authenticate'] = 'Basic realm="Restricted Area"'
      halt(code, "Not authorized #{msg}\n")
    end

    api_endpoint(:get, '/health', nil, "Basic health check") do
      #FIXME: query db?
      "OK"
    end

    api_endpoint(:get, '/ping', nil, "Basic ping (for load balancer)") do
      "OK"
    end

    api_endpoint(:get, '/help', nil, "Help for the API") do
      @@api_help.sort.map do |uri, data|
        "#{uri} - #{data[:policy_action_name].nil? ? 'no perms/open' : 'requires: ' + data[:policy_action_name] } - #{data[:description]}\n"
      end.join()
    end

    # -----------------------------------------------------------------------------
    api_endpoint(:put, '/distribute_state/:hostname', 'PutDistributeState', "Server self reporting endpoint") do |hostname|
      #FIXME: these are SRV actions not user actions, not sure how to ACL them - might need a special treatment
      #FIXME: how can you only allow the servers to update their own IP or name or something??

      data = JSON.parse(request.body.read)
      #FIXME: very syntax of API call

      # each line contains an artifact or a target.
      # I expect a hash containing app, which in turn contain envs, contains current and a list of artifacts
      data.each do |row|
        puts "Current for #{hostname}: #{row['current']}"
        @db.put_distribute_state(row['app'], row['env'], hostname, row['current'], row['artifacts'].sort.join(','))
      end
      #FIxmE: add check if ok
      "OK - Updated server #{hostname}"
    end

    # -----------------------------------------------------------------------------

    api_endpoint(:put, '/srv/keepalive/:hostname', 'PutSrvKeepalive', "Server self reporting endpoint") do |hostname|
      ##protected! if @env['REMOTE_ADDR'] != '127.0.0.1'
      ttl = request.body.read.force_encoding('US-ASCII') || '20'
      @db.put_keepalive(hostname,ttl)
      "OK - Updated server #{hostname}"
    end


    # -----------------------------------------------------------------------------
    api_endpoint(:put, '/artifact/:app/:artifact', 'PutArtifact', "Registers artifact for given app") do |app,artifact|
      authorized?('PutArtifact', app)
      ##protected! if @env['REMOTE_ADDR'] != '127.0.0.1'

      raw_source = request.body.read
      source = JSON.parse(raw_source)

      # FIXME: check for source and format of source. It's a JSON that contains:
      # - filename
      # - decompress (or not) flag
      # - source URL
      # - alternative source URL
      #
      # OR inline_content instead of URL
      #
      # - checksum

      # If OK just register with a reformat.
      @db.put_artifact(artifact, app, JSON.generate(source))
      "OK - registered artifact #{artifact} for app #{app}"
    end

    api_endpoint(:delete, '/artifact/:app/:artifact', 'DeleteArtifact', "Delete an artifact (unregister)") do |app,artifact|
      # FIXME: don't allow to delete a target artifact.
      # FIXME: add a doesn't exist warning?
      @db.delete_artifact(app,artifact)
      "OK - delete artifact #{artifact} for app #{app}"
    end


    # -----------------------------------------------------------------------------
    api_endpoint(:put, '/target/:app/:env', 'PutTarget', 'Sets current target artifact in a given app/environment') do |app,env|

      #FIXME check that the target exists
      artifact = request.body.read.force_encoding('US-ASCII')
      @db.put_target(app,env,artifact)
      "OK set target for app #{app} in environment #{env} to be #{artifact}"
    end

    api_endpoint(:get, '/target/:app/:env','GetTarget', 'Current target artifact for this app/env') do |app,env|
      artifact = "unknown"
      @db.get_target_env(app,env).each do |row|
        artifact = row['artifact']
      end

      artifact
    end

    api_endpoint(:get, '/target/:app', 'GetTarget', 'Current target artifacts for this app') do |app|
      JSON.pretty_generate(@db.get_target(app).map(&:values).to_h)
    end

    # -----------------------------------------------------------------------------
    api_endpoint(:get, '/distribute/:app/:env', 'GetDistribute', 'Currently distributed artifacts for this app/env') do |app,env|
      # NOTE: cassandra implementation uses active_env since it doesn't know how to do joins
      r = {}
      target = @db.get_target_env(app,env)

      @db.get_distribute_env(app,env).each do |row|
        artifact = row.delete 'artifact'
        row['target'] = target.first ? (target.first.values.first == artifact) : false
        r[artifact] = row
      end

      JSON.pretty_generate(r)
    end

    # -----------------------------------------------------------------------------
    api_endpoint(:get, '/distribute/:app', 'GetDistribute', 'All distributed artifacts for this app') do |app|
      r = {}

      @db.get_distribute(app).each do |row|
        env = row['env'] || 'nowhere'
        r[env] ||= []
        r[env] << row['artifact']
      end
      JSON.pretty_generate(r)
    end

    # -----------------------------------------------------------------------------
    # This call is just a big dump. The client can handle the sorting / formatting.
    api_endpoint(:get, '/target_state/:app/:env', 'GetTargetState', "Target state for app/env") do |app,env|
      JSON.pretty_generate(@db.get_target_state(app,env))
    end

    # -----------------------------------------------------------------------------
    # This call is just a big dump. The client can handle the sorting / formatting.
    api_endpoint(:get, '/distribute_state/:app','GetDistributeState', "Big dump of distribute state") do |app|
      authorized?('GetDistributeState',app)

      r = []
      @db.get_distribute_state(app).each do |row|
        row['artifacts'] = row['artifacts'].split(',')
        r << row
      end

      JSON.pretty_generate(r)
    end

    # -----------------------------------------------------------------------------
    api_endpoint(:get, '/artifact/:app', 'GetArtifact', 'List of artifacts') do |app|
      r = {}
      @db.get_artifact_list(app).each do |row| # The reason it's like that is that we can get
        artifact = row.delete 'artifact'
        r[artifact] = row
      end

      JSON.pretty_generate(r)
    end

    # -----------------------------------------------------------------------------
    api_endpoint(:put, '/distribute/:app/:env', 'PutDistribute', "Distribute an artifact (in body) to app/env") do |app,env|
      artifact = request.body.read.force_encoding('US-ASCII')

      if @db.get_artifact(app,artifact).count == 1
        @db.put_distribute(artifact,app,env)
        "OK set artifact #{artifact} for app #{app} to be distributed in environment #{env}"
      else
        "No such artifact #{artifact} for app #{app}"
      end
    end

    delete '/distribute/:app/:env/:artifact' do |app,env,artifact|
      authorized?('DeleteDistribute',app,env)
      @db.delete_distribute(app,env,artifact)
      "OK will not distribute artifact #{artifact} for app #{app} in environment #{env}"
    end

    # -----------------------------------------------------------------------------
    api_endpoint(:get, '/distribute_lock/:app/:env', 'GetDistributeLock', "Read a lock for auto-consistency checks") do |app,env|
      r = @db.get_distribute_lock(app,env)
      r.count == 1 ? r.first["comment"] : "UNLOCKED"
    end

    api_endpoint(:put, '/distribute_lock/:app/:env', 'PutDistributeLock', "Set a lock for auto-consistency checks") do |app,env|
      comment = request.body.read
      comment = "From #{env['REMOTE_ADDR']}" if comment.length == 0 or comment == "UNLOCKED"

      @db.put_distribute_lock(app,env,comment)
      "OK - locked app/env #{app}/#{env}"
    end

    api_endpoint(:delete, '/distribute_lock/:app/:env', 'DeleteDistributeLock', "Delete a lock for auto-consistency checks") do |app,env|
      @db.delete_distribute_lock(app,env)
      "OK - deleted lock from app/env"
    end

    # -----------------------------------------------------------------------------
    api_endpoint(:get, '/srv/by_app/:app/:env', 'GetSrvByApp', "For fabric ssh") do |app,env|
      # this gets the list that SHOULD have things distributed to them...
      r = {}
      @db.get_srv_by_app_env(app,env).each do |row|
        r[row['hostname']] = {
          'current' => row['current'],
          'artifacts' => row['artifacts'].split(','),
        }
      end

      JSON.pretty_generate(r)
    end

    # -----------------------------------------------------------------------------
    api_endpoint(:get, '/dump/:type', 'GetDump', 'Dumping tools') do |type|

      binding.pry
      q = case type
      when 'distributed_app'
        @db.get_distributed_apps()
      when 'configured_app'
        @db.get_configured_apps()
      when 'distribute_state'
        @db.get_full_distribute_state()
      when 'target'
        @db.get_full_target()
      when 'artifacts'
        @db.get_full_artifacts()
      else
        halt 500, "try among distribute_app, configured_app, distribute_state, target, artifacts"
      end

      r = []
      q.each do |row|
        r << row
      end

      JSON.pretty_generate(r)
    end

    # -----------------------------------------------------------------------------
    api_endpoint(:get, '/demo_only_repo/:app/:file', nil, "Don't use this in production") do |app,file|
      # No auth here
      halt 500,"wrong file name" if file =~ /[^A-Za-z0-9\.\-\_]/ or file.length < 1
      fullfile = File.expand_path "~/hdeploy_build/artifacts/#{app}/#{file}"
      if File.file? fullfile
        send_file(fullfile, disposition: 'attachment', filename: file)
      else
        puts "Debug: non existent file #{fullfile}"
        halt 404, "non existent file #{file}"
      end
    end
  end
end
