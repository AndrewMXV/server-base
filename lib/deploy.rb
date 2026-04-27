#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'open3'
require 'json'
require 'pathname'
require 'shellwords'

module Deploy
  DEBUG_TRUE_VALUES = %w[1 true yes on].freeze

  def self.debug? = @debug == true
  def self.enable_debug! = @debug = true
  def self.debug_from_env! = @debug = DEBUG_TRUE_VALUES.include?(ENV.fetch('DEBUG', '').strip.downcase)

  ServerConfig = Struct.new(
    :name, :host, :host_port, :tls_domain, :main_domain, :scheme,
    :installs, :rsyncs, :configs, :env, :ssh_proxy, :ssh_proxy_url, :ssh_proxy_exclude_hosts,
    keyword_init: true
  )

  module ColorHelpers
    COLORS = {
      green:  "\e[32m",
      yellow: "\e[33m",
      cyan:   "\e[36m",
      red:    "\e[31m",
      gray:   "\e[90m"
    }.freeze
    RESET = "\e[0m"

    module_function

    def colorize(name, text)
      code = COLORS[name]
      return text.to_s unless code
      "#{code}#{text}#{RESET}"
    end
  end

  module Actions
    class Action
      attr_reader :name, :base_dir, :depends, :before

      def initialize(name, base_dir, default: false, depends: [], before: [])
        @name = name.to_sym
        @base_dir = base_dir
        @check = @apply = nil
        @default = default
        @depends = Array(depends).map(&:to_sym).uniq
        @before = Array(before).map(&:to_sym).uniq
      end

      def check(&block)
        @check = block
      end

      def apply(&block)
        @apply = block
      end

      def default? = @default

      def run(context, params = {})
        puts color(:cyan, "[action #{@name}] check")
        if @check && context.instance_exec(params, &@check)
          puts color(:yellow, "[action #{@name}] skip")
          return
        end
        return unless @apply
        puts color(:green, "[action #{@name}] apply")
        context.instance_exec(params, &@apply)
      end

      private

      def color(name, text)
        ColorHelpers.colorize(name, text)
      end

      def self.color_static(name, text)
        ColorHelpers.colorize(name, text)
      end
    end

    class Registry
      def initialize = @actions = {}
      def register(action) = @actions[action.name] = action
      def fetch(name) = @actions[name.to_sym]
      def each(&block) = @actions.each_value(&block)
      def names = @actions.keys
    end

    class Loader
      def initialize(directory, registry)
        @directory = directory
        @registry = registry
      end

      def load_all
        Dir[File.join(@directory, '**', 'action.rb')].sort.each { |file| load_file(file) }
      end

      private

      def load_file(file)
        registry = @registry
        base_dir = File.dirname(file)
        mod = Module.new
        mod.define_singleton_method(:Action) do |name, default: false, depends: [], before: [], &block|
          action = Action.new(name, base_dir, default: default, depends: depends, before: before)
          action.instance_eval(&block)
          registry.register(action)
        end
        mod.module_eval(File.read(file), file)
      end
    end
  end

  class DSL
    def self.load(file_path)
      config = nil
      runner = Object.new
      runner.define_singleton_method(:Server) do |name, &block|
        b = DSL.new(name.to_s, File.dirname(file_path))
        b.instance_eval(&block)
        config = b.to_config
      end
      runner.instance_eval(File.read(file_path), file_path)
      raise "Server block not found in #{file_path}" unless config
      config
    end

    def initialize(name, config_dir)
      @name = name
      @config_dir = config_dir
      @attrs = {
        installs: [],
        rsyncs: [],
        configs: [],
        env: {},
        host_port: 22,
        ssh_proxy: false,
        ssh_proxy_url: nil,
        ssh_proxy_exclude_hosts: []
      }
    end

    def host(value) = @attrs[:host] = value
    def host_port(value) = @attrs[:host_port] = value.to_i
    def tls_domain(value) = @attrs[:tls_domain] = value
    def main_domain(value) = @attrs[:main_domain] = value
    def ssh_proxy(value = true, proxy: nil, exclude_hosts: nil)
      @attrs[:ssh_proxy] = !!value
      @attrs[:ssh_proxy_url] = proxy.to_s.strip unless proxy.nil?
      return if exclude_hosts.nil?
      @attrs[:ssh_proxy_exclude_hosts] = Array(exclude_hosts).flat_map { |v| v.to_s.split(',') }.map(&:strip).reject(&:empty?).uniq
    end
    def install(name, **opts)
      sym = name.to_sym
      if @attrs[:installs].any? { |i| i[:name] == sym }
        raise "Duplicate install '#{sym}' in server #{@name}"
      end
      @attrs[:installs] << { name: name.to_sym, opts: opts }
    end
    def rsync(source:, target:)
      source = source.to_s
      target = target.to_s
      raise "rsync source is required in server #{@name}" if source.empty?
      raise "rsync target is required in server #{@name}" if target.empty?
      @attrs[:rsyncs] << { source: source, target: target }
    end

    def env(**vars)
      @attrs[:env].merge!(vars.transform_keys { |k| k.to_s })
    end

    def config(target:, file_content:)
      @attrs[:configs] << { target: target.to_s, file_content: file_content.to_s }
    end

    def to_config
      @attrs[:main_domain] ||= @attrs[:tls_domain]
      @attrs[:scheme] = @attrs[:tls_domain] ? 'https' : 'http'
      @attrs[:ssh_proxy_exclude_hosts] = Array(@attrs[:ssh_proxy_exclude_hosts]).flat_map { |v| v.to_s.split(',') }.map(&:strip).reject(&:empty?).uniq
      @attrs[:rsyncs] = @attrs[:rsyncs].map do |entry|
        source = File.expand_path(entry[:source], @config_dir)
        source = "#{source}/" if entry[:source].end_with?('/') && !source.end_with?('/')
        { source: source, target: entry[:target] }
      end
      ServerConfig.new(**@attrs.merge(name: @name))
    end
  end

  class SSH
    SSH_OPTS = %w[
      -o StrictHostKeyChecking=no
      -o ConnectTimeout=15
      -o BatchMode=yes
      -o PasswordAuthentication=no
      -o PreferredAuthentications=publickey
      -o UserKnownHostsFile=/dev/null
    ].freeze

    def initialize(host:, port:, ssh_proxy: false, proxy: nil, exclude_hosts: [])
      @host = host
      @port = port
      @ssh_opts = SSH_OPTS.dup
      @remote_env = {}
      if ssh_proxy
        proxy_url = proxy.to_s.strip
        if proxy_url.empty?
          proxy_url = 'socks5h://127.0.0.1:1080'
          @ssh_opts += ['-R', '127.0.0.1:1080']
        end
        @remote_env['ALL_PROXY'] = proxy_url
        @remote_env['all_proxy'] = proxy_url
        @remote_env['HTTP_PROXY'] = proxy_url
        @remote_env['http_proxy'] = proxy_url
        @remote_env['HTTPS_PROXY'] = proxy_url
        @remote_env['https_proxy'] = proxy_url
        no_proxy = Array(exclude_hosts).flat_map { |v| v.to_s.split(',') }.map(&:strip).reject(&:empty?).uniq.join(',')
        unless no_proxy.empty?
          @remote_env['NO_PROXY'] = no_proxy
          @remote_env['no_proxy'] = no_proxy
        end
      end
    end

    def remote_cmd(cmd)
      return cmd if @remote_env.empty?
      exports = @remote_env.map { |k, v| "#{k}=#{Shellwords.escape(v)}" }.join(' ')
      "env #{exports} bash -c #{Shellwords.escape(cmd)}"
    end

    def exec!(cmd)
      puts color(:gray, "[ssh exec] #{cmd[0, 30]}...")
      full_cmd = ["ssh", *@ssh_opts, "-p", @port.to_s, "root@#{@host}", remote_cmd(cmd)]
      status = Open3.popen2e(*full_cmd) do |_stdin, stdout_err, wait_thr|
        stdout_err.each_line { |line| puts line.rstrip }
        wait_thr.value
      end
      raise "Remote command failed: #{cmd}" unless status.success?
    end

    def script!(content)
      puts color(:gray, "[ssh script] #{content[0, 30]}...")
      shell_cmd = Deploy.debug? ? "bash -x -s" : "bash -s"
      puts color(:gray, "[debug ssh script] #{shell_cmd}") if Deploy.debug?
      status = Open3.popen2e("ssh", *@ssh_opts, "-p", @port.to_s, "root@#{@host}", remote_cmd(shell_cmd)) do |stdin, stdout_err, wait_thr|
        t = Thread.new { stdout_err.each_line { |line| puts line.rstrip } }
        stdin.write(content)
        stdin.close
        wait_thr.value.tap { t.join }
      end
      raise "Remote script failed" unless status.success?
    end

    def capture(cmd)
      puts color(:gray, "[ssh capture] #{cmd[0, 30]}...")
      stdout, status = Open3.capture2('ssh', *@ssh_opts, '-p', @port.to_s, "root@#{@host}", remote_cmd(cmd))
      raise "Remote command failed: #{cmd}" unless status.success?
      stdout
    end

    def rsync!(source:, target:)
      raise "Rsync source not found: #{source}" unless File.exist?(source)

      puts color(:gray, "[rsync] #{source} -> #{@host}:#{target}")
      ssh_cmd = ['ssh', *@ssh_opts, '-p', @port.to_s].join(' ')
      if Deploy.debug?
        proxy_env = @remote_env.select { |k, _| k.downcase.include?('proxy') }
        puts color(:gray, "[debug rsync] ssh transport: #{ssh_cmd}")
        puts color(:gray, "[debug rsync] proxy env: #{proxy_env}") unless proxy_env.empty?
      end
      return rsync_native!(source, target, ssh_cmd) if remote_has?('rsync')
      puts color(:yellow, "[rsync] remote rsync missing, falling back to tar stream")
      tar_fallback_copy!(source, target)
    end

    def rsync_native!(source, target, ssh_cmd)
      args = ['rsync', '-az', '-e', ssh_cmd, source, "root@#{@host}:#{target}"]
      ok = system(*args)
      raise "Rsync failed: #{source} -> #{target}" unless ok
    end

    def tar_fallback_copy!(source, target)
      src = source.end_with?('/') && source != '/' ? source.chomp('/') : source
      tar_cmd = build_tar_cmd(src, include_contents: source.end_with?('/') && File.directory?(src))
      remote_extract = remote_cmd("set -e; command -v tar >/dev/null 2>&1 || { echo 'tar not found on remote host' >&2; exit 127; }; mkdir -p #{Shellwords.escape(target)}; tar -C #{Shellwords.escape(target)} -xf -")
      full_cmd = "#{shell_join(tar_cmd)} | #{shell_join(['ssh', *@ssh_opts, '-p', @port.to_s, "root@#{@host}", remote_extract])}"
      puts color(:gray, "[debug rsync fallback] #{full_cmd}") if Deploy.debug?
      ok = system(full_cmd)
      raise "Rsync fallback failed: #{source} -> #{target}" unless ok
    end

    def build_tar_cmd(source, include_contents:)
      return ['tar', '-C', source, '-cf', '-', '.'] if include_contents

      ['tar', '-C', File.dirname(source), '-cf', '-', File.basename(source)]
    end

    def remote_has?(binary)
      _out, status = Open3.capture2(
        'ssh', *@ssh_opts, '-p', @port.to_s, "root@#{@host}",
        remote_cmd("command -v #{Shellwords.escape(binary)} >/dev/null 2>&1")
      )
      status.success?
    end

    def shell_join(argv) = argv.map { |arg| Shellwords.escape(arg) }.join(' ')


    def color(name, text) = ColorHelpers.colorize(name, text)
  end

  class ActionContext
    attr_reader :config, :ssh, :distro
    attr_accessor :params, :current_action_dir

    def initialize(config, ssh, distro, destroy: false)
      @config = config
      @ssh = ssh
      @distro = distro
      @params = {}
      @current_action_dir = nil
      @destroy = destroy
    end

    def destroying? = @destroy

    def remote(script)
      @ssh.script!(script)
    end

    def exec(cmd)
      @ssh.exec!(cmd)
    end

    def capture(cmd)
      @ssh.capture(cmd)
    end

    def read_file(path, default: nil)
      escaped = Shellwords.escape(path)
      fallback = default.nil? ? ':' : "printf %s #{Shellwords.escape(default)}"
      capture("if [ -f #{escaped} ]; then cat #{escaped}; else #{fallback}; fi")
    end

    def write_file(path, content)
      escaped = Shellwords.escape(path)
      marker = "__DEPLOY_FILE_#{Process.pid}_#{rand(36**6).to_s(36)}__"
      marker = "#{marker}_X" while content.include?(marker)
      remote <<~SH
        set -euo pipefail
        cat > #{escaped} <<'#{marker}'
        #{content}
        #{marker}
      SH
    end

    def deploy_drs(drs_files, env = {})
      drs_paths = Array(drs_files).map { |drs| Pathname.new(File.join(@current_action_dir, drs)) }
      drs_paths.each { |p| raise "DRS not found: #{p}" unless p.file? }

      return destroy_drs_stacks(drs_paths) if @destroy

      env_builder = EnvBuilder.new(config: @config, params_env: @params[:env], call_env: env)
      cmd = ['dry-stack', 'swarm_deploy', '-x', "ssh://root@#{@config.host}:#{@config.host_port}"]
      cmd << "--tls-domain=#{@config.tls_domain}" if @config.tls_domain
      cmd << '--'
      cmd << '--prune'
      puts "[deploy_drs] #{cmd.join(' ')} < #{drs_paths.map(&:basename).join(' ')}"

      status = nil
      Open3.popen3(env_builder.effective_env, *cmd, chdir: drs_paths.first.dirname.to_s) do |stdin, stdout, stderr, wait_thr|
        stdin.write drs_paths.map { |p| File.read(p) }.join("\n")
        stdin.close
        streams = { stdout => $stdout, stderr => $stderr }
        until streams.empty?
          readable, = IO.select(streams.keys)
          readable.each do |io|
            streams[io].print io.readpartial(4096)
          rescue EOFError
            streams.delete(io)
          end
        end
        status = wait_thr.value
      end
      raise("Failed to deploy #{drs_paths.join(', ')}") unless status&.success?
    end

    private

    def destroy_drs_stacks(drs_paths)
      stack_names = drs_paths.filter_map { |p| extract_stack_name(File.read(p)) }.uniq
      raise "Could not determine stack name(s) from: #{drs_paths.map(&:basename).join(', ')}" if stack_names.empty?

      stack_names.each do |name|
        puts ColorHelpers.colorize(:yellow, "[destroy] removing stack: #{name}")
        @ssh.script!(<<~SH)
          set -e
          if docker stack ls --format '{{.Name}}' | grep -qx #{Shellwords.escape(name)}; then
            docker stack rm #{Shellwords.escape(name)}
            echo "Stack #{name} removed."
          else
            echo "Stack #{name} not found, skipping."
          fi
        SH
      end
    end

    def extract_stack_name(content)
      match = content.match(/^\s*Options\s+.*\bname:\s*['"]([^'"]+)['"]/)
      match&.[](1)
    end
  end

  # Responsible for composing environment for stack deployments in a predictable order.
  class EnvBuilder
    def initialize(config:, params_env:, call_env:)
      @config = config
      @params_env = params_env || {}
      @call_env = call_env || {}
    end

    def effective_env
      @effective_env ||= begin
        base = {}
        base.merge! stringified(@config.env) if @config.respond_to?(:env) && @config.env
        base['MAIN_DOMAIN'] ||= @config.main_domain if @config.main_domain
        base['TLS_DOMAIN'] ||= @config.tls_domain if @config.tls_domain
        base['SCHEME'] ||= @config.scheme if @config.scheme
        base.merge!(stringified(@params_env))
        base.merge!(stringified(@call_env))
        base
      end
    end

    private

    def stringified(hash)
      hash.each_with_object({}) do |(k, v), acc|
        next if v.nil?
        acc[k.to_s] = v.to_s
      end
    end
  end

  class Executor
    MAX_TIME_DRIFT_SECONDS = 30

    def initialize(config, actions:, destroy: false)
      @config = config
      @destroy = destroy
      @ssh = SSH.new(
        host: config.host,
        port: config.host_port,
        ssh_proxy: config.ssh_proxy,
        proxy: config.ssh_proxy_url,
        exclude_hosts: config.ssh_proxy_exclude_hosts
      )
      @actions = actions
    end

    def run!
      raise "host is required" unless @config.host
      raise "tls_domain or main_domain is required" unless @config.tls_domain || @config.main_domain

      preflight = preflight!
      unless @destroy
        run_rsyncs!
        run_configs!
      end

      distro = preflight[:distro]
      context = ActionContext.new(@config, @ssh, distro, destroy: @destroy)

      install_steps = @config.installs
      params_by_name = install_steps.each_with_object({}) { |s, h| h[s[:name].to_sym] = s[:opts] || {} }
      requested = params_by_name.keys
      defaults = []
      @actions.each { |action| defaults << action.name if action.default? }
      seed = defaults + requested
      unknown_seed = requested - @actions.names
      raise "Unknown actions requested: #{unknown_seed.join(', ')}" unless unknown_seed.empty?

      before_by_target = Hash.new { |h, k| h[k] = [] }
      @actions.each { |action| action.before.each { |target| before_by_target[target] << action.name } }
      before_unknown = before_by_target.keys - @actions.names
      raise "Unknown actions in before: #{before_unknown.join(', ')}" unless before_unknown.empty?

      depends_for = lambda do |name|
        return [] unless @actions.names.include?(name)
        @actions.fetch(name).depends
      end

      expand = lambda do |names|
        seen = {}
        order = []
        queue = names.dup
        until queue.empty?
          name = queue.shift
          next if seen[name]
          seen[name] = true
          order << name
          depends_for.call(name).each { |dep| queue << dep }
        end
        order
      end

      all_needed = expand.call(seed)
      unknown = all_needed - @actions.names
      raise "Unknown actions requested: #{unknown.join(', ')}" unless unknown.empty?

      needed_set = all_needed.each_with_object({}) { |name, h| h[name] = true }
      deps_for = lambda do |name|
        action = @actions.fetch(name)
        deps = action.depends
        before_by_target[name].each { |dep| deps << dep if needed_set[dep] }
        deps.uniq
      end

      ordered = []
      state = {}
      visit = lambda do |name|
        case state[name]
        when :visiting then raise "Dependency cycle detected at #{name}"
        when :done then return
        end
        state[name] = :visiting
        action = @actions.fetch(name)
        deps_for.call(name).each { |dep| visit.call(dep) }
        state[name] = :done
        ordered << name
      end

      seed.each { |name| visit.call(name) }
      ordered.each do |name|
        action = @actions.fetch(name)
        run_action(context, action, params_by_name[name] || {})
      end

    end

    private

    def run_rsyncs!
      Array(@config.rsyncs).each { |entry| @ssh.rsync!(source: entry[:source], target: entry[:target]) }
    end

    def run_configs!
      require 'tempfile'
      Array(@config.configs).each do |entry|
        Tempfile.create('deploy_config') do |tmp|
          tmp.write(entry[:file_content])
          tmp.flush
          @ssh.rsync!(source: tmp.path, target: entry[:target])
        end
      end
    end

    def run_action(context, action, params)
      context.current_action_dir = action.base_dir
      context.params = params
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      action.run(context, params)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      puts Actions::Action.color_static(:gray, "[action #{action.name}] done in #{elapsed.round(2)}s")
    rescue StandardError => e
      puts Actions::Action.color_static(:red, "[action #{action.name}] error: #{e.message}")
      raise "Action #{action.name} failed: #{e.message}"
    end

    def preflight!
      info = fetch_preflight_info!
      local_epoch = Time.now.to_i
      drift_seconds = (info[:server_epoch] - local_epoch).abs
      print_preflight_banner(info[:distro], info[:server_hostname], local_epoch, info[:server_epoch], drift_seconds)
      if drift_seconds > MAX_TIME_DRIFT_SECONDS
        puts Actions::Action.color_static(:yellow, "[preflight] drift #{drift_seconds}s is above #{MAX_TIME_DRIFT_SECONDS}s, attempting time sync")
        sync_method = try_sync_server_time!
        sleep 2

        info = fetch_preflight_info!
        local_epoch = Time.now.to_i
        drift_seconds = (info[:server_epoch] - local_epoch).abs
        print_preflight_banner(info[:distro], info[:server_hostname], local_epoch, info[:server_epoch], drift_seconds)
        if drift_seconds > MAX_TIME_DRIFT_SECONDS
          force_method = force_set_server_time!(local_epoch)
          sleep 1

          info = fetch_preflight_info!
          local_epoch = Time.now.to_i
          drift_seconds = (info[:server_epoch] - local_epoch).abs
          print_preflight_banner(info[:distro], info[:server_hostname], local_epoch, info[:server_epoch], drift_seconds)
          raise "Server time drift is #{drift_seconds}s (limit #{MAX_TIME_DRIFT_SECONDS}s) after sync attempts (#{sync_method}, #{force_method})" if drift_seconds > MAX_TIME_DRIFT_SECONDS
        end
      end
      { distro: info[:distro] }
    end

    def fetch_preflight_info!
      raw = @ssh.capture(<<~SH)
        set -e
        if [ -f /etc/os-release ]; then
          . /etc/os-release
          distro="$ID"
        else
          distro="unsupported"
        fi
        server_hostname="$(hostname -f 2>/dev/null || hostname)"
        server_epoch="$(date +%s)"
        printf '%s\\t%s\\t%s\\n' "$distro" "$server_hostname" "$server_epoch"
      SH
      distro, server_hostname, server_epoch_raw = raw.strip.split("\t", 3)
      raise "Preflight failed: unable to parse remote info" unless distro && server_hostname && server_epoch_raw
      { distro: distro, server_hostname: server_hostname, server_epoch: Integer(server_epoch_raw, 10) }
    rescue ArgumentError
      raise "Preflight failed: invalid remote epoch '#{server_epoch_raw}'"
    end

    def try_sync_server_time!
      @ssh.capture(<<~SH).strip
        set +e
        method="none"
        if command -v chronyc >/dev/null 2>&1; then
          if chronyc -a makestep >/dev/null 2>&1 || chronyc makestep >/dev/null 2>&1; then
            method="chronyc"
          fi
        fi
        if [ "$method" = "none" ] && command -v timedatectl >/dev/null 2>&1; then
          timedatectl set-ntp true >/dev/null 2>&1 || true
          systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
          systemctl restart chronyd >/dev/null 2>&1 || true
          systemctl restart chrony >/dev/null 2>&1 || true
          method="timedatectl"
        fi
        if [ "$method" = "none" ] && command -v ntpd >/dev/null 2>&1; then
          if ntpd -gq >/dev/null 2>&1; then
            method="ntpd"
          fi
        fi
        printf '%s\\n' "$method"
      SH
    rescue StandardError => e
      "failed: #{e.message}"
    end

    def force_set_server_time!(target_epoch)
      @ssh.capture(<<~SH).strip
        set +e
        if date -u -s "@#{target_epoch}" >/dev/null 2>&1; then
          printf '%s\\n' "date-set"
        else
          printf '%s\\n' "date-set-failed"
        fi
      SH
    rescue StandardError => e
      "failed: #{e.message}"
    end

    def print_preflight_banner(distro, server_hostname, local_epoch, server_epoch, drift_seconds)
      local_time = Time.at(local_epoch).utc.strftime('%Y-%m-%d %H:%M:%S UTC')
      server_time = Time.at(server_epoch).utc.strftime('%Y-%m-%d %H:%M:%S UTC')
      puts Actions::Action.color_static(:cyan, "[preflight] host=#{@config.host}:#{@config.host_port} hostname=#{server_hostname} distro=#{distro}")
      puts Actions::Action.color_static(:cyan, "[preflight] local_time=#{local_time} server_time=#{server_time} drift=#{drift_seconds}s (max #{MAX_TIME_DRIFT_SECONDS}s)")
    end
  end

  class CLI
    def self.run(argv)
      Deploy.debug_from_env!
      options = {
        servers_dir: File.expand_path("../config/servers", __dir__),
        actions_dir: File.expand_path("../actions", __dir__),
        debug: Deploy.debug?,
        destroy: false
      }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: deploy --server NAME [options]"
        opts.on("--server NAME", "Server DSL filename (without .rb)") { |v| options[:server] = v }
        opts.on("--servers-dir PATH", "Directory with server DSL files") { |v| options[:servers_dir] = v }
        opts.on("--actions-dir PATH", "Directory with action definitions") { |v| options[:actions_dir] = v }
        opts.on("--destroy", "Destroy deployed stacks instead of deploying") { options[:destroy] = true }
        opts.on("--debug", "Enable debug output") { options[:debug] = true }
      end
      parser.parse!(argv)
      Deploy.enable_debug! if options[:debug]
      raise "Server name required" unless options[:server]

      server_file = File.join(options[:servers_dir], "#{options[:server]}.rb")
      raise "Server file not found: #{server_file}" unless File.exist?(server_file)

      registry = Actions::Registry.new
      Actions::Loader.new(options[:actions_dir], registry).load_all

      config = DSL.load(server_file)
      Executor.new(config, actions: registry, destroy: options[:destroy]).run!
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Deploy::CLI.run(ARGV)
end
