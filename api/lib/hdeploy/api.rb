require 'sinatra/base'
require 'json'
require 'hdeploy/conf'
require 'hdeploy/database'

module HDeploy
  class API < Sinatra::Base

    def initialize
      super

      @db = HDeploy::Database.factory()
      @conf = HDeploy::Conf.instance
    end

    # -----------------------------------------------------------------------------
    # Some Auth stuff
    def protected!
      return if authorized?
      headers['WWW-Authenticate'] = 'Basic realm="Restricted Area"'
      halt 401, "Not authorized\n"
    end

    def authorized?
      @auth ||=  Rack::Auth::Basic::Request.new(request.env)
      @auth.provided? and @auth.basic? and @auth.credentials and @auth.credentials == @conf['api'].values_at('http_user','http_password')
    end

    get '/health' do
      #FIXME: query db?
      "OK"
    end

    get '/ping' do
      "OK"
    end

    # -----------------------------------------------------------------------------
    put '/distribute_state/:hostname' do |hostname|
      if @env['REMOTE_ADDR'] != '127.0.0.1'
        protected!
      end

      data = JSON.parse(request.body.read)
      #FIXME: very syntax of API call

      # each line contains an artifact or a target.
      # I expect a hash containing app, which in turn contain envs, contains current and a list of artifacts
      data.each do |row|
        @db.put_distribute_state(row['app'], row['env'], hostname, row['current'], row['artifacts'].sort.join(','))
      end
      #FIxmE: add check if ok
      "OK - Updated server #{hostname}"
    end

    # -----------------------------------------------------------------------------

    put '/srv/keepalive/:hostname' do |hostname|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'
      ttl = request.body.read.force_encoding('US-ASCII') || '20'
      @db.put_keepalive(hostname,ttl)
      "OK - Updated server #{hostname}"
    end


    # -----------------------------------------------------------------------------
    put '/artifact/:app/:artifact' do |app,artifact|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'

      data = request.body.read
      data = JSON.parse(data)
      data['altsource'] ||= ''

      @db.put_artifact(artifact, app, data['source'], data['altsource'], data['checksum'])
      "OK - registered artifact #{artifact} for app #{app}"
    end

    delete '/artifact/:app/:artifact' do |app,artifact|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'

      # FIXME: don't allow to delete a target artifact.
      # FIXME: add a doesn't exist warning?
      @db.delete_artifact(app,artifact)
      "OK - delete artifact #{artifact} for app #{app}"
    end


    # -----------------------------------------------------------------------------
    put '/target/:app/:myenv' do |app,myenv|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'

      #FIXME check that the target exists
      artifact = request.body.read.force_encoding('US-ASCII')
      @db.put_target(app,myenv,artifact)
      "OK set target for app #{app} in environment #{myenv} to be #{artifact}"
    end

    get '/target/:app/:myenv' do |app,myenv|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'
      artifact = "unknown"
      @db.get_target_env(app,myenv).each do |row|
        artifact = row['artifact']
      end

      artifact
    end

    get '/target/:app' do |app|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'
      JSON.pretty_generate(@db.get_target(app).map(&:values).to_h)
    end

    # -----------------------------------------------------------------------------
    get '/distribute/:app/:env' do |app,myenv|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'

      # NOTE: cassandra implementation uses active_env since it doesn't know how to do joins
      r = {}
      target = @db.get_target_env(app,myenv)

      @db.get_distribute_env(app,myenv).each do |row|
        artifact = row.delete 'artifact'
        row['target'] = (target.first.values.first == artifact)
        r[artifact] = row
      end

      JSON.pretty_generate(r)
    end


    # -----------------------------------------------------------------------------
    get '/distribute/:app' do |app|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'

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
    get '/target_state/:app/:env' do |app,env|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'

      r = []
      JSON.pretty_generate(@db.get_target_state(app,env))
    end

    # -----------------------------------------------------------------------------
    # This call is just a big dump. The client can handle the sorting / formatting.
    get '/distribute_state/:app' do |app|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'

      r = []
      @db.get_distribute_state(app).each do |row|
        row['artifacts'] = row['artifacts'].split(',')
        r << row
      end

      JSON.pretty_generate(r)
    end

    # -----------------------------------------------------------------------------
    get '/artifact/:app' do |app|
      protected! if @env['REMOTE_ADDR'] != '127.0.0.1'
      r = {}
      @db.get_artifact_list(app).each do |row| # The reason it's like that is that we can get
        artifact = row.delete 'artifact'
        r[artifact] = row
      end

      JSON.pretty_generate(r)
    end

    # -----------------------------------------------------------------------------
    put '/distribute/:app/:env' do |app,env|
      artifact = request.body.read.force_encoding('US-ASCII')

      if @db.get_artifact(app,artifact).count == 1
        @db.put_distribute(artifact,app,env)
        "OK set artifact #{artifact} for app #{app} to be distributed in environment #{env}"
      else
        "No such artifact #{artifact} for app #{app}"
      end
    end

    delete '/distribute/:app/:env/:artifact' do |app,env,artifact|
      @db.delete_distribute(app,env,artifact)
      "OK will not distribute artifact #{artifact} for app #{app} in environment #{env}"
    end

    # -----------------------------------------------------------------------------
    get '/srv/by_app/:app/:env' do |app,env|
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
    get '/demo_only_repo/:app/:file' do |app,file|
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
