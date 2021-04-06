require 'mixlib/cli'
require 'pathname'

module MarkdownLint
  # Our Mixlib::CLI class
  class CLI
    include Mixlib::CLI

    CONFIG_FILE = 'mdlrc'.freeze
    CONFIG_DOT_FILE = '.'.freeze + CONFIG_FILE

    banner "Usage: #{File.basename($PROGRAM_NAME)} [options] [FILE.md|DIR ...]"

    option :show_aliases,
           :short => '-a',
           :long => '--[no-]show-aliases',
           :description =>
             'Show rule alias instead of rule ID when viewing rules',
           :boolean => true

    option :config_file,
           :short => '-c',
           :long => '--config FILE',
           :description => 'The configuration file to use',
           :default => CONFIG_DOT_FILE.to_s

    option :verbose,
           :short => '-v',
           :long => '--[no-]verbose',
           :description => 'Increase verbosity',
           :boolean => true

    option :ignore_front_matter,
           :short => '-i',
           :long => '--[no-]ignore-front-matter',
           :boolean => true,
           :description => 'Ignore YAML front matter'

    option :show_kramdown_warnings,
           :short => '-w',
           :long => '--[no-]warnings',
           :description => 'Show kramdown warnings',
           :boolean => true

    option :tags,
           :short => '-t',
           :long => '--tags TAG1,TAG2',
           :description => 'Only process rules with these tags',
           :proc => proc { |v| toggle_list(v, true) }

    option :rules,
           :short => '-r',
           :long => '--rules RULE1,RULE2',
           :description => 'Only process these rules',
           :proc => proc { |v| toggle_list(v) }

    option :style,
           :short => '-s',
           :long => '--style STYLE',
           :description => 'Load the given style'

    option :list_rules,
           :short => '-l',
           :long => '--list-rules',
           :boolean => true,
           :description => "Don't process any files, just list enabled rules"

    option :git_recurse,
           :short => '-g',
           :long => '--git-recurse',
           :boolean => true,
           :description =>
             'Only process files known to git when given a directory'

    option :rulesets,
           :short => '-u',
           :long => '--rulesets RULESET1,RULESET2',
           :proc => proc { |v| v.split(',') },
           :description => 'Specify additional ruleset files to load'

    option :skip_default_ruleset,
           :short => '-d',
           :long => '--skip-default-ruleset',
           :boolean => true,
           :description => "Don't load the default markdownlint ruleset"

    option :help,
           :on => :tail,
           :short => '-h',
           :long => '--help',
           :description => 'Show this message',
           :boolean => true,
           :show_options => true,
           :exit => 0

    option :version,
           :on => :tail,
           :short => '-V',
           :long => '--version',
           :description => 'Show version',
           :boolean => true,
           :proc => proc { puts MarkdownLint::VERSION },
           :exit => 0

    option :json,
           :short => '-j',
           :long => '--json',
           :description => 'JSON output',
           :boolean => true

    def run(argv = ARGV)
      parse_options(argv)

      # Load the config file if it's present
      filename = CLI.probe_config_file(config[:config_file])

      # Only fall back to the global config if we are using the default value for -c
      if filename.nil? && (config[:config_file] == CONFIG_DOT_FILE)
        filename = [
          File.expand_path("~/#{CONFIG_DOT_FILE}"),
          File.join(ENV.fetch('XDG_CONFIG_HOME', File.expand_path('~/.config')),
                    CONFIG_FILE)
        ].find(&File.method(:exist?))
      end

      if !filename.nil? && File.exist?(filename)
        MarkdownLint::Config.from_file(filename.to_s)
        puts "Loaded config from #{filename}" if config[:verbose]
      end

      # Put values in the config file
      MarkdownLint::Config.merge!(config)

      # Set the correct format for any rules/tags configuration loaded from
      # the config file. Ideally this would probably be done as part of the
      # config class itself rather than here.
      unless MarkdownLint::Config[:rules].nil?
        MarkdownLint::Config[:rules] = CLI.toggle_list(
          MarkdownLint::Config[:rules],
        )
      end
      unless MarkdownLint::Config[:tags].nil?
        MarkdownLint::Config[:tags] = CLI.toggle_list(
          MarkdownLint::Config[:tags], true
        )
      end

      # Read from stdin if we didn't provide a filename
      cli_arguments << '-' if cli_arguments.empty? && !config[:list_rules]
    end

    def self.toggle_list(parts, to_sym = false)
      parts = parts.split(',') if parts.instance_of?(String)
      if parts.instance_of?(Array)
        inc = parts.reject { |p| p.start_with?('~') }
        exc = parts.select { |p| p.start_with?('~') }.map { |p| p[1..-1] }
        if to_sym
          inc.map!(&:to_sym)
          exc.map!(&:to_sym)
        end
        { :include => inc, :exclude => exc }
      else
        # We already converted the string into a list of include/exclude
        # pairs, so just return as is
        parts
      end
    end

    def self.probe_config_file(path)
      expanded_path = File.expand_path(path)
      return expanded_path if File.exist?(expanded_path)

      # Look for a file up from the working dir
      Pathname.new(expanded_path).ascend do |p|
        next unless p.directory?

        config_file = p.join(CONFIG_FILE)
        return config_file if File.exist?(config_file)
      end
      nil
    end
  end
end
