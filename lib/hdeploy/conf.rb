require 'json'
require 'deep_merge'
require 'deep_clone'

module HDeploy
  class Conf

    @@instance = nil
    @@default_values = []
    @@conf_path = nil

    def initialize(conf_path)

      # Added omnibus paths. Not very elegant but works
      if conf_path.nil?
        try_path = %w[
          .
          etc
          /etc/hdeploy
          /opt/hdeploy/etc
          /opt/hdeploy-api
          /home/app/hdeploy/api
          /home/app/hdeploy/api/etc
        ]

        try_path.each do |p|
          if File.exists?(File.join(p, 'hdeploy.json'))
            conf_path = File.expand_path(p)
            break
          end
        end

        raise "unable to find conf file hdeploy.json in search path #{try_path}" if conf_path.nil?
      end

      @@conf_path = conf_path
      reload
    end

    # FIXME: find a good way to set default path
    def self.instance(path = nil)
      @@instance ||= new(path)
    end

    # -------------------------------------------------------------------------
    def reload
      @conf = get_json_file(File.join(@@conf_path, 'hdeploy.json'))
    end

    def get_json_file(file)
      raise "unable to find file #{file}" unless File.file? file

      st = File.stat(file)
      raise "config file #{file} must have uid 0" unless st.uid == 0 or Process.uid != 0
      raise "config file #{file} must not allow group/others to write" unless sprintf("%o", st.mode) =~ /^100[46][04][04]/

      JSON.parse(File.read(file))
    end

    def file
      File.join(@@conf_path, 'hdeploy.json')
    end

    def self.conf_path
      @@conf_path
    end

    # -------------------------------------------------------------------------
    def [](k)
      @conf[k] || {} # FIXME: autovivification?
    end

    def each(&block)
      @conf.each(&block)
    end

    def key?(k)
      @conf.key?k
    end

    def keys
      @conf.keys
    end

    # -------------------------------------------------------------------------
    def add_defaults(h)
      # This is pretty crappy code in that it loads stuff twice etc. But that way no re-implementing a variation of deep_merge for default stuff...
      @@default_values << h.__deep_clone__

      rebuild_conf = {}
      @@default_values.each do |defval|
        rebuild_conf.deep_merge!(defval)
      end

      @conf = rebuild_conf.deep_merge!(@conf)
    end
  end
end
