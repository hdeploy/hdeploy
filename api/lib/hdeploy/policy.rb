require 'json'
require 'bcrypt'
require 'pry'

# This is a policy system very similar to AWS IAM Policy
# Because it's know and relatively simple and works

module HDeploy

  class Cache
    @@cache = {}

    def self.raw_get(k)
      @@cache[k][:obj]
    end

    def self.get_or_execute_block(id, file,ttl = 86400)
      obj = nil

      if @@cache.key? id
        c = @@cache[id]
        #obj, obj_file, obj_file_mtime,obj_expire = @@cache[id].values_at(:obj, :file, :file_mtime, :expire)
        #if obj_file == file and obj_file_mtime == File.stat(obj_file).mtime and Time.new.to_i < obj_expire
        if c[:expire] > Time.new.to_i and c[:file_mtime] == File.stat(file).mtime.to_i
          puts "Loaded #{id} from cache"
          return @@cache[id][:obj]
        else
          puts "Cache for #{id} expired"
          puts "Reloading the actual object without replacing"
          obj = @@cache[id][:obj]
          obj.reload(file)
        end
      end

      obj = yield if obj.nil?

      @@cache[id] = {
        obj: obj,
        file: file,
        file_mtime: File.stat(file).mtime.to_i,
        expire: Time.new.to_i + ttl,
      } unless obj.nil? # Special condition for nil object ; for users
      obj
    end

    def self.delete(key)
      @@cache.delete key
    end

    def self.delete_pattern(pattern)
      @@cache.keys.select{|k| File.fnmatch(pattern,k)}.each do |k|
        @@cache.delete k
      end
    end
  end

  class Groupdefs
    def initialize(file)
      reload(file)
    end

    def reload(file)
      puts "New group defs - cleanup all user cache"
      Cache.delete_pattern('user:*')
      @data = JSON.parse(File.read(file))
    end

    def [](k)
      @data[k]
    end
  end

  class Policy
    def self.factory(policyname)
      # Rudimentary cache - must add TTL support
      HDeploy::Cache.get_or_execute_block("policy:#{policyname}", File.join(HDeploy::Conf.conf_path, 'policies', "#{policyname}.json")) do
        puts "Load policy #{policyname}"
        Policy.new(policyname)
      end
    end

    def initialize(policyname)
      @name = policyname
      reload(File.join(HDeploy::Conf.conf_path, 'policies', "#{policyname}.json"))
    end

    def reload(file)
      @raw = File.read(file)
      @policy = validatepolicy(@raw)
    end

    def evaluate(action,resource)

      final_result = nil

      @policy['Statement'].each do |statement|
        sid,effect,p_action,p_resource = statement.values_at('Sid','Effect','Action','Resource')

        if (p_action.map{|a| File.fnmatch(a,action)}.include?(true)) and (p_resource.map{|r| File.fnmatch(r,resource)}.include?(true))
          puts "Matched on sid #{sid}"
          final_result = (effect == "Allow")
          break
        end
      end

      if final_result.nil?
        puts "No match in #{@name} for #{action} on #{resource}"
        return nil
      else
        return final_result
      end
    end

    def validatepolicy(policy)
      policy = JSON.parse(policy) if policy.is_a? String
      raise "Policy must contain Version and Statement" unless policy.keys.sort == %w[Version Statement].sort
      supported_versions = { '2018-12-18' => :validatepolicy20181218 }
      raise "Policy versions supported: #{supported_versions.keys.sort}" unless supported_versions.key? policy['Version']
      raise "Statement much be an Array" unless policy['Statement'].is_a? Array
      send(supported_versions[policy['Version']], policy['Statement'])
      policy
    end

    def validatepolicy20181218(policy)
      warn "Warning: empty policy" if policy.count == 0
      policy.each_with_index do |statement,index|

        begin
          # Convert action and Resource to Array
          %w[Action Resource].each do |k|
            statement[k] = [statement[k]] if statement[k].class == String
          end

          # We need sid, effect, action, resource
          {
            'Sid'      => String,
            'Effect'   => String,
            'Action'   => Array,
            'Resource' => Array,
          }.each do |k,v|
            raise "Missing param #{k} in statement" unless statement.key? k
            raise "Param #{k} must be a #{v}" unless v == statement[k].class
            if statement[k].is_a? Array
              raise "Sub-params of #{k} as a list must all be strings and at least one" unless statement[k].count>0
              raise "Sub-params of #{k} must all be strings" unless statement[k].select{|s| s.class != String}.count == 0
            end
          end

          raise "Effect can be Allow and Deny" unless %w[Allow Deny].include? statement['Effect']
          raise "Sid must match /^[A-Za-z0-9\-\-_\s\:\*\?]+$/" unless statement['Sid'] =~ /^[A-Za-z0-9\-\-_\s\:\*\?]+$/

          statement['Action'].each do |a|
            raise "action #{a} does not match /^[A-Za-z0-9\*\?]+$/" unless a =~ /^[A-Za-z0-9\*\?]+$/
          end

          statement['Resource'].each do |r|
            raise "Resource is in format app:env where both app and env can contain some wildcard at the end" unless
              r =~ /^[A-Za-z0-9\_\?\*]+\:[A-Za-z0-9\_\?\*]+$/
          end
        rescue Exception => e
          raise "#{e} - while evaluating policy statement #{statement} / ##{index}"
        end
      end
      policy
    end
  end

  class User
    def initialize(name:, bcrypt:, groups:, policies:)
      @name = name
      @bcrypt = bcrypt
      @groups = groups.nil? ? [] : groups.map(&:downcase)
      @own_policies = policies.nil? ? [] : policies.map(&:downcase)
      groupdefs = Cache.raw_get('groupdefs') # This was set just before so I'm good
      @policies = (@own_policies + @groups.map{|g| groupdefs[g] }.flatten).select{|g| not g.nil? }.uniq
    end

    def checkpw(pw)
      @bcrypt == pw
    end

    def self.search_local(name, password)
      # Rudimentary cache

      group_file = "#{HDeploy::Conf.conf_path}/groups.json"
      Cache.get_or_execute_block('groupdefs', group_file) do
        # If we reload this, we will invalidate ALL USERS cache
        # It's kinda brutal but it's not gonna happen all the time either ... - see reload() method
        puts "First time groupdefs load"
        Groupdefs.new(group_file)
      end

      file = File.join(HDeploy::Conf.conf_path, 'users', "#{name}.json")
      user = HDeploy::Cache.get_or_execute_block("user:#{name}", file) do
        if File.exists?file
          # FIXME: add syntax check
          json = JSON.parse(File.read(file))
          user = User.new(
            name:     name,
            bcrypt:   BCrypt::Password.new(json['bcrypt']),
            groups:   json['groups'],
            policies: json['policies'],
          )
        else
          puts "User #{username} doesn't exist in local JSON"
          nil
        end
      end

      if user and not user.checkpw(password)
        raise "Wrong password"
      end

      user

      #FIXME: add ldap
    end

    def evaluate(action, resource)
      @policies.each do |policyname|
        result = Policy.factory(policyname).evaluate(action,resource) # This calls the cache - lazy load
        if not result.nil?
          return result
        end
      end
      false
    end
  end
end

