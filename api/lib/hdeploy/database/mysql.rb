require 'mysql2'
require 'pry'
require 'json'

module HDeploy
  class Database
    class MySQL < HDeploy::Database
      def initialize
        super
        puts "DB init MySQL"

        @queries.merge!({
          # These are special just because they expire
          put_keepalive: "REPLACE INTO srv_keepalive (hostname,expire) VALUES(?,UNIX_TIMESTAMP(NOW()) + ?)",
          put_distribute_state: "REPLACE INTO distribute_state (app,env,hostname,current,artifacts,expire) VALUES(?,?,?,?,?,UNIX_TIMESTAMP(NOW()) + 1800)",

          # FIXME ADD some ? and on duplicate key update

          # Special stuff for SQL expiration
          expire_distribute_state: "DELETE FROM distribute_state WHERE expire < UNIX_TIMESTAMP(NOW())",
          expire_keepalive: "DELETE FROM srv_keepalive WHERE expire < UNIX_TIMESTAMP(NOW())",
        })

        @schemas = {
          srv_keepalive:    'hostname varchar(255), expire bigint, primary key (hostname), index (expire)',
          distribute_state: 'app varchar(255), env varchar(63), hostname varchar(255), current varchar(255), artifacts longtext, expire bigint, primary key (app,env,hostname), index (expire)',
          distribute:       'artifact varchar(255), app varchar(255), env varchar(63), primary key(artifact,app,env)',
          artifacts:        'artifact varchar(255), app varchar(255), source longtext, altsource longtext, checksum longtext, primary key (artifact,app)',
          target:           'app varchar(255), env varchar(63), artifact varchar(255), primary key (app,env)',
        }

        # FIXME: regular run of expire?
        # select * from distribute_state where expire <  UNIX_TIMESTAMP(NOW());
        @db = MySQLWrapper.new('default', File.join(HDeploy::Conf.conf_path, 'mysql.json'))

        # We also want some initialization stuff
        @schemas.each do |table,sql|
          begin
            result = @db.query("DESC `#{table}`")
          rescue Mysql2::Error => e
            if e.to_s =~ /Table.*#{table}.*doesn't exist/
              @db.query("CREATE TABLE #{table} (#{sql})")
            else
              puts "Got MySQL error - raising it"
              raise e
            end
          end
        end

        @cleanup_due = 0
      end

      def raw_query(sql)
        @db.query(sql)
      end

      def method_missing(m, *args, &block)
        if @queries.key? m
          statement = @db.prepare(@queries[m])
          args = adapt_args_to_sql_update(m, args)
          result = statement.execute(*args)

          if @cleanup_due < Time.new.to_i
            @cleanup_due = Time.new.to_i + 5 # Do it again in a minute
            puts "DB Expire cleanup"
            expire_distribute_state
            puts "Distribute state: #{@db.affected_rows} changes"
            expire_keepalive
            puts "Keepalive: #{@db.affected_rows} changes"
          end
        else
          raise "No such query/method #{m} in class HDeploy::Database::SQLite"
        end
        result.to_a # Need something better?
      end
    end

    # -------------------------------------------------------------------------
    # This wrapper exists for auto-reconnect mostly
    # It's a proxy object that acts like the real thing except for a retry
    # And also a JSON config file
    class MySQLWrapper
      def initialize(name,jsonfile)
        @name = name
        @jsonfile = jsonfile
        _mysql_connect()
      end

      def close
        @subject.close unless @subject.nil?
        @subject = nil
      end

      private

      def _mysql_connect()
        # we re-read the config each time.
        @conf = JSON.parse(File.read(@jsonfile))
        die "no such section #{@name} in file #{@jsonfile}" unless @conf.has_key? @name
        c = @conf[@name]

        %w[pass host].each do |param|
          die "param missing #{param} in section #{@name} of file #{@jsonfile}" unless c.has_key? param
        end

        c.keys.each do |param|
          raise "invalid param #{param} in section #{@name} of file #{@jsonfile}" unless %w[user pass host base port].include? param
        end

        @subject = Mysql2::Client.new(
          host:     c['host'],
          username: c['user'] || 'hdeploy',
          password: c['pass'],
          database: c['base'] || 'hdeploy',
          port:     c['port'] || 3306,
          reconnect: true,
        )
      end

      def method_missing(method, *args, &block)
        # if the object was destroyed, we can re-create it automagically...!! :)
        _mysql_connect() if @subject.nil?

        if ['query', 'execute', 'prepare'].include? method.to_s
          begin
            @subject.send(method, *args, &block)
          rescue Mysql2::Error => e
            if e.to_s =~ /MySQL server has gone away/
              _mysql_connect()
              @subject.send(method, *args, &block)
            else
              puts "raising error #{e}"
              raise e
            end
          end

        elsif @subject.respond_to? method
            @subject.send(method, *args, &block)
        else
          raise "no such method #{method} for #{@subject}"
        end
      end
    end
  end
end

