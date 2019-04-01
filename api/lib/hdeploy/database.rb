require 'hdeploy/database/sqlite'
require 'hdeploy/database/mysql' #FIXME: drivers? Optional load?

require 'pry'

module HDeploy
  class Database
    def self.factory
      conf =  HDeploy::Conf.instance
      raise "no api section in config" unless conf.key? 'api'
      engine = nil
      engine = conf['api']['database_engine'].downcase if conf['api'].key? 'database_engine'
      case engine
      when nil, 'sqlite'
        return HDeploy::Database::SQLite.new
      when 'mysql'
        return HDeploy::Database::MySQL.new
      else
        raise "no such type #{type} for database"
      end
    end

    def initialize
      puts 'DB Init'
      @queries = {
        put_distribute_state: 'REPLACE INTO distribute_state (app,env,hostname,current,artifacts) VALUES(?,?,?,?,?)', # NEEDS TTL
        put_keepalive:        'REPLACE INTO srv_keepalive (hostname) VALUES(?)', # NEEDS TTL
        get_keepalive:        'SELECT * FROM srv_keepalive WHERE hostname = ?',

        put_artifact:    'REPLACE INTO artifacts (artifact,app,source,altsource,checksum,multifile) VALUES(?,?,?,?,?,?)',
        delete_artifact: 'DELETE FROM artifacts WHERE app = ? AND artifact = ?',

        put_target:     'REPLACE INTO target (app,env,artifact) VALUES(?,?,?)',
        get_target_env: 'SELECT artifact FROM target WHERE app = ? AND env = ?',
        get_target:     'SELECT env,artifact FROM target WHERE app = ?',

        put_distribute:     'REPLACE INTO distribute (artifact,app,env) VALUES(?,?,?)',
        delete_distribute:  'DELETE FROM distribute WHERE app = ? AND env = ? AND artifact = ?',

        # The SQL word 'USING' for joins is not in SQLite so using this syntax so it's compatible with both SQLite and MySQL
        # This is a join because we obviously only want distributed artifacts
        # Integrity check: are there non-existent distribute artifacts????
        # For Cassandra we use this intermediate table active_env but this is the raw SQL.

        # Multifile is a true/false

        get_distribute_env: 'SELECT distribute.artifact,source,altsource,checksum,multifile FROM artifacts INNER JOIN distribute ON distribute.artifact = artifacts.artifact WHERE artifacts.app = ? AND env = ?',
        get_distribute:     'SELECT env,artifacts.artifact FROM artifacts LEFT JOIN distribute ON distribute.artifact = artifacts.artifact WHERE artifacts.app = ?',

        get_distribute_state: 'SELECT env,hostname,artifacts,current FROM distribute_state WHERE app = ?',
        get_target_state:     'SELECT hostname,current FROM distribute_state WHERE app = ? AND env = ?',
        get_artifact_list:    'SELECT artifact,source,altsource,checksum,multifile FROM artifacts WHERE app = ?',
        get_artifact:         'SELECT artifact,source,altsource,checksum,multifile FROM artifacts WHERE app = ? AND artifact = ?',

        get_srv_by_app_env: 'SELECT hostname,current,artifacts FROM distribute_state WHERE app = ? AND env = ?',
        get_srv_by_app:     'SELECT hostname,current,artifacts FROM distribute_state WHERE app = ?',
      }

      @schemas = {
        srv_keepalive:    'hostname text, expire integer, primary key (hostname)',
        distribute_state: 'app text, env text, hostname text, current text, artifacts text, expire integer, primary key (app,env,hostname)',
        distribute:       'artifact text, app text, env text, primary key(artifact,app,env)',
        artifacts:        'artifact text, app text, source text, altsource text, checksum text, multifile integer, primary key (artifact,app)',
        target:           'app text, env text, artifact text, primary key (app,env)',
        #active_env: 'app text, env text, primary key (app,env)', # That's a Cassandra Specific for joins
      }
    end

    def adapt_args_to_sql_update(query_id, args)
      # FIXME: add comments on how this works

      @query_counters ||= @queries.map {|k,sql| [k, sql.scan('?').count]}.to_h

      arg_number_needed = @query_counters[query_id]
      minimum_args_for_completion = ((arg_number_needed + 1) / 2).floor

      if args.count == arg_number_needed
        # Do nothing
      elsif args.count > arg_number_needed
        raise "Too many args for SQL for query #{query_id} (got #{args.count} needed #{arg_number_needed})"
      elsif args.count < minimum_args_for_completion
        # that's bad too
        raise "Not enough args for SQL for query #{query_id} (got #{args.count} needed #{minimum_args_for_completion} just for auto-fill)"
      else
        # This is the case where we autofill.
        # So we will take the args and add the last ones
        args += args[(args.count - arg_number_needed)..-1]
      end

      args
    end
  end
end
