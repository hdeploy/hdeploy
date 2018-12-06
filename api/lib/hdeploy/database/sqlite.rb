require 'sqlite3'
require 'pry'

module HDeploy
  class Database
    class SQLite < HDeploy::Database
      def initialize
        super
        puts "DB init SQLite"
        puts "WARNING: do not use in production, you want Cassandra (distributed) or at least MySQL (concurrent queries) for production"

        @queries.merge!({
          put_keepalive: "INSERT INTO srv_keepalive (hostname,expire) VALUES(?,strftime('%s', datetime('now')) + ?)",
          put_distribute_state: "INSERT INTO distribute_state (app,env,hostname,current,artifacts,expire) VALUES(?,?,?,?,?,strftime('%s', datetime('now')) + 1800)",
        })

        # FIXME: regular run of expire?
        # select * from distribute_state where expire <  strftime('%s', datetime('now'));

        @db = SQLite3::Database.new("hdeploy.db", results_as_hash: true) #FIXME: path

        # We also want some initialization stuff
        @schemas.each do |table,sql|
          result = @db.execute("SELECT sql FROM sqlite_master WHERE name='#{table}'").to_a
          sql = "CREATE TABLE #{table} (#{sql} on conflict replace)"
          puts sql
          if result.count == 0
            @db.execute(sql)
          elsif result.count == 1
            if result.first.values.first != sql
              puts "Update table #{table}"
              puts "old: #{result.first.first}"
              puts "new: #{sql}"
              @db.execute("DROP table #{table}")
              @db.execute(sql)
            else
              puts "Table #{table} structure OK"
            end
          end
        end
      end

      def raw_query(sql)
        @db.execute(sql)
      end

      def method_missing(m, *args, &block)
        if @queries.key? m
          statement = @db.prepare(@queries[m])
          args = adapt_args_to_sql_update(m, args)
          result = statement.execute(*args)
        else
          raise "No such query/method #{m} in class HDeploy::Database::SQLite"
        end
        result.to_a # Need something better?
      end
    end
  end
end

