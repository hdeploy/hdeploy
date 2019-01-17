require 'json'
require 'bcrypt'
require 'pry'

# This is a policy system very similar to AWS IAM Policy
# Because it's know and relatively simple and works

module HDeploy
  CONFPATH = "/Users/pviet/repos/hdeploy/hdeploy/api/etc/"

  class Policy
    @@policies = {}

    def self.factory(policyname)
      # Rudimentary cache - must add TTL support
      @@policies[policyname] ||= Policy.new(policyname)
    end

    def initialize(policyname)
      @name = policyname
      #FIXME: cache?
      @file = File.join(CONFPATH, 'policies', "#{policyname}.json")
      @raw = File.read(@file)
      @policy = validatepolicy(@raw)

      @@policies[policyname] = self
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
          # Convert Action and Resource to Array
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
            raise "Action #{a} does not match /^[A-Za-z0-9\*\?]+$/" unless a =~ /^[A-Za-z0-9\*\?]+$/
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
    @@cache = {}

    def initialize(name, groups = [], own_policies = [])
      @name = name
      @groups = groups.map(&:downcase)
      @own_policies = own_policies.map(&:downcase)
      @policies = []
      load_policies()
    end

    def load_policies
      if @own_policies
        @own_policies.each do |policyname|
          @policies << Policy.factory(policyname)
        end
      end

      if @groups

        # FIXME: don't load this each time
        groupdefs = JSON.parse(File.read("#{CONFPATH}/groups.json"))

        @groups.each do |group|
          # Load group from file
          raise "No such group #{group}" unless groupdefs.key? group
          groupdefs[group].each do |policyname|
            @policies << Policy.factory(policyname)
          end
        end
      end
    end

    def checkpw(pw)
      @bcrypt == pw
    end

    def self.search_local(username, password)
      # Rudimentary cache
      if @@cache.key? username
        if @@cache[username].checkpw(password)
          return @@cache[username]
        else
          raise "Wrong password"
        end
      end

      file = File.join(CONFPATH, 'users', "#{username}.json")
      if File.exists?file
        json = JSON.parse(File.read(file))
        @bcrypt = BCrypt::Password.new(json['password'])
        raise "Wrong password" unless @bcrypt == password
        return User.new(name,json['groups'] || [], json['policies'] || [])
      end
      false
    end

    def evaluate(action, resource)
      @policies.each do |policy|
        result = policy.evaluate(action,resource)
        if not result.nil?
          return result
        end
      end
      false
    end
  end
end

