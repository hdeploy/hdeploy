require 'json'

# This is a policy system very similar to AWS IAM Policy
# Because it's know and relatively simple and works

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

$policyfiles = [ 'policy.json', 'policy2.json' ]
$policies = {}

def load_policies(force = false)
  # We will load and process policies alphabetically
  newpolicies = {}
  numloads = 0

  begin
    $policyfiles.sort.each do |file|
      # Made on difference lines so it's easier to trace errors
      mtime = File.stat(file).mtime.to_i
      size = File.stat(file).size

      if force or (not $policies.key?(file)) or ($policies.key?(file) and ($policies[file]['mtime'] != mtime or $policies[file]['size'] != size))
        numloads += 1
        raw = File.read(file)
        policy = JSON.parse(raw)
        newpolicy[file] = validatepolicy(policy)
        newpolicy[file]['mtime'] = mtime
        newpolicy[file]['size'] = size
      else
        puts "Skipping load of #{file}: mtime/size still the same"
        newpolicies[file] = $policies[file]
      end
    end

    # Happens at the end and only if no exception happened
    puts "Finished loading - loaded #{numloads} files"
    $policies = newpolicies
  rescue Exception => e
    raise "Could error while loading policies: #{e.backtrace} - keeping old policy settings"
  end

  $policies
end

def process_acl(action,resource)

  final_result = nil

  # load_acl gives an array of policies
  load_policies().each do |file,policy|
    require 'pry'
    binding.pry
    policy['Statement'].each do |statement|
      sid,effect,p_action,p_resource = statement.values_at('Sid','Effect','Action','Resource')

      if (p_action.map{|a| File.fnmatch(a,action)}.include?(true)) and (p_resource.map{|r| File.fnmatch(r,resource)}.include?(true))
        puts "Matched on sid #{sid}"
        final_result = (effect == "Allow")
        break
      end
    end

    if not final_result.nil?
      break
    end
  end

  if final_result.nil?
    puts "No match for any policy - default is deny"
    return false
  else
    return final_result
  end
end

puts process_acl('DoStuff', 'blah:derp')
