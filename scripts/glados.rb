#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "ostruct"
require "pathname"
require "shellwords"
require "time"

module Glados
  class CLI
    DEFAULT_TAG = "gnosis/codex-service:dev"

    def initialize(argv)
      @argv = argv.dup
      @options = OpenStruct.new(
        install: false,
        rebuild: false,
        no_cache: false,
        login: false,
        run: false,
        serve: false,
        new_session: false,
        exec: nil,
        shell: false,
        push: false,
        tag: DEFAULT_TAG,
        workspace: nil,
        codex_home: nil,
        codex_args: [],
        oss_server_url: nil,
        ollama_host: nil,
        codex_model: nil,
        skip_update: false,
        no_auto_login: false,
        json: false,
        json_e: false,
        oss: false,
        oss_model: nil,
        speaker: false,
        speaker_port: 8777,
        danger: false,
        record: false,
        record_dir: nil,
        list_recordings: false,
        play_recording: nil,
        upload_recording: nil,
        gateway_port: nil,
        gateway_host: nil,
        gateway_timeout_ms: nil,
        gateway_default_model: nil,
        gateway_extra_args: [],
        gateway_session_dirs: nil,
        gateway_secure_dir: nil,
        gateway_secure_token: nil,
        gateway_log_level: nil,
        gateway_watch_paths: nil,
        gateway_watch_pattern: nil,
        gateway_watch_prompt_file: nil,
        gateway_watch_debounce_ms: nil,
        transcription_service_url: "http://host.docker.internal:8765",
        session_webhook_url: nil,
        session_webhook_auth_bearer: nil,
        session_webhook_headers_json: nil,
        session_id: nil,
        list_sessions: false,
        recent_limit: 20,
        since_days: 3,
        privileged: false
      )

      parse!
    end

    def run
      announce("Initializing. Try not to break anything important.")
      ensure_single_action!

      if @options.install || @options.rebuild
        build_image
        return
      end

      if @options.login
        login
        return
      end

      if @options.list_sessions
        list_sessions
        return
      end

      if @options.serve
        start_gateway
        return
      end

      if @options.shell
        open_shell
        return
      end

      if @options.exec
        exec_prompt
        return
      end

      start_interactive
    end

    private

    def ensure_single_action!
      actions = []
      actions << :install if @options.install || @options.rebuild
      actions << :login if @options.login
      actions << :shell if @options.shell
      actions << :exec if @options.exec
      actions << :run if @options.run
      actions << :serve if @options.serve
      actions << :list_sessions if @options.list_sessions
      return if actions.empty?
      return if actions.size == 1

      raise "Specify only one primary action. You chose: #{actions.join(', ')}"
    end

    def parse!
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: glados [options]"

        opts.on("-i", "--install", "Build Docker image") { @options.install = true }
        opts.on("--rebuild", "Rebuild Docker image") { @options.rebuild = true }
        opts.on("--no-cache", "Disable Docker build cache") { @options.no_cache = true }
        opts.on("--login", "Authenticate with Codex") { @options.login = true }
        opts.on("--run", "Start interactive Codex session") { @options.run = true }
        opts.on("--serve", "Start HTTP gateway") { @options.serve = true }
        opts.on("--exec PROMPT", String, "Run non-interactive prompt") { |v| @options.exec = v }
        opts.on("--shell", "Open bash shell inside container") { @options.shell = true }
        opts.on("--tag TAG", String, "Docker image tag") { |v| @options.tag = v }
        opts.on("--workspace PATH", String, "Workspace directory") { |v| @options.workspace = v }
        opts.on("--codex-home PATH", String, "Codex home directory") { |v| @options.codex_home = v }

        opts.on("--oss", "Use local OSS model") { @options.oss = true }
        opts.on("--oss-model MODEL", String, "Specify OSS model") { |v| @options.oss_model = v }
        opts.on("--oss-server-url URL", String, "Override OSS server URL") { |v| @options.oss_server_url = v }
        opts.on("--ollama-host HOST", String, "Alias for OSS host override") { |v| @options.ollama_host = v }

        opts.on("--codex-model MODEL", String, "Override cloud model") { |v| @options.codex_model = v }
        opts.on("--json", "Legacy JSON output mode") { @options.json = true }
        opts.on("--json-e", "Experimental JSON output mode") { @options.json_e = true }

        opts.on("--danger", "Enable danger mode (no sandbox)") { @options.danger = true }
        opts.on("--privileged", "Run docker with --privileged") { @options.privileged = true }

        opts.on("--gateway-port PORT", Integer, "Gateway port") { |v| @options.gateway_port = v }
        opts.on("--gateway-host HOST", String, "Gateway bind host") { |v| @options.gateway_host = v }
        opts.on("--gateway-timeout-ms MS", Integer, "Gateway timeout") { |v| @options.gateway_timeout_ms = v }
        opts.on("--gateway-default-model MODEL", String, "Gateway default model") { |v| @options.gateway_default_model = v }
        opts.on("--gateway-extra-args ARGS", String, "Extra gateway args") { |v| @options.gateway_extra_args << v }

        opts.on("--session-id ID", String, "Resume a session") { |v| @options.session_id = v }
        opts.on("--list-sessions", "List sessions and exit") { @options.list_sessions = true }

        opts.on("-h", "--help", "Show help") do
          puts opts
          exit 0
        end
      end

      parser.parse!(@argv)
      @options.codex_args.concat(@argv)
    end

    def build_image
      announce("Building the container. Try to look busy.")
      context = build_context
      ensure_docker_daemon!

      log_dir = File.join(context[:codex_home], "logs")
      FileUtils.mkdir_p(log_dir)
      timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
      log_file = File.join(log_dir, "build-#{timestamp}.log")

      build_args = ["build"]
      buildkit = ENV.fetch("DOCKER_BUILDKIT", "1") != "0"
      build_args << "--progress=plain" if buildkit
      build_args << "--no-cache" if @options.no_cache
      build_args += ["-f", context[:dockerfile], "-t", context[:tag], context[:codex_root]]

      write_log(log_file, "[build] docker #{shell_join(build_args)}")
      run_cmd(["docker", *build_args], log_file: log_file)
      announce("Build complete. Log saved to #{log_file}")
    end

    def login
      announce("Logging you in. This is where I'd applaud your security hygiene.")
      context = build_context
      ensure_docker_image!(context[:tag])
      run_container(
        context,
        command: ["/bin/bash", "-c", 'sed -i "s/\\r$//" /workspace/scripts/codex_login.sh && /bin/bash /workspace/scripts/codex_login.sh'],
        expose_login_port: true
      )
    end

    def list_sessions
      announce("Listing sessions. I hope you kept notes.")
      context = build_context
      show_recent_sessions(context, limit: @options.recent_limit, since_days: @options.since_days)
    end

    def start_gateway
      announce("Starting gateway. Please do not lick the ports.")
      context = build_context
      ensure_docker_image!(context[:tag])
      ensure_codex_auth!(context)

      port = @options.gateway_port || 4000
      bind_host = @options.gateway_host || "127.0.0.1"
      publish = "#{bind_host}:#{port}:#{port}"

      env_vars = {
        "CODEX_GATEWAY_PORT" => port.to_s,
        "CODEX_GATEWAY_BIND" => "0.0.0.0"
      }
      env_vars["CODEX_GATEWAY_TIMEOUT_MS"] = @options.gateway_timeout_ms.to_s if @options.gateway_timeout_ms
      env_vars["CODEX_GATEWAY_DEFAULT_MODEL"] = @options.gateway_default_model if @options.gateway_default_model
      if @options.gateway_extra_args.any?
        env_vars["CODEX_GATEWAY_EXTRA_ARGS"] = @options.gateway_extra_args.join(" ")
      end

      run_container(
        context,
        command: ["node", "/usr/local/bin/codex_gateway.js"],
        additional_args: ["-p", publish],
        additional_env: env_vars,
        gateway_mode: true
      )
    end

    def open_shell
      announce("Opening shell. Try not to set anything on fire.")
      context = build_context
      ensure_docker_image!(context[:tag])
      ensure_codex_auth!(context)
      run_container(context, command: ["/bin/bash"])
    end

    def exec_prompt
      announce("Executing prompt. I'll be over here, judging silently.")
      context = build_context
      ensure_docker_image!(context[:tag])
      ensure_codex_auth!(context, silent: @options.json || @options.json_e)

      args = build_exec_arguments
      run_codex(context, args)
    end

    def start_interactive
      announce("Starting interactive session. This should be fun for me.")
      context = build_context
      ensure_docker_image!(context[:tag])
      ensure_codex_auth!(context, silent: @options.json || @options.json_e)

      args = build_run_arguments(context)
      run_codex(context, args)
    end

    def announce(message)
      puts "GLaDOS: #{message}"
    end

    def run_cmd(cmd, log_file: nil)
      puts "→ #{cmd.is_a?(Array) ? shell_join(cmd) : cmd}"
      stdout, stderr, status = Open3.capture3(*Array(cmd))
      write_log(log_file, stdout) if log_file && !stdout.empty?
      write_log(log_file, stderr) if log_file && !stderr.empty?
      puts stdout unless stdout.empty?
      warn stderr unless stderr.empty?
      raise "Command failed with exit code #{status.exitstatus}" unless status.success?
    end

    def write_log(path, content)
      return unless path
      File.open(path, "a") { |f| f.puts(content) }
    end

    def build_context
      script_dir = Pathname.new(__FILE__).expand_path.dirname
      codex_root = script_dir.join("..").expand_path.to_s
      dockerfile = File.join(codex_root, "Dockerfile")
      raise "Dockerfile not found at #{dockerfile}" unless File.exist?(dockerfile)
      raise "docker command not found on PATH." unless system("command -v docker >/dev/null 2>&1")

      workspace_path = resolve_workspace_path(@options.workspace, codex_root)
      codex_home = resolve_codex_home(@options.codex_home)
      whisper_cache = File.join(codex_home, "whisper-cache")
      FileUtils.mkdir_p(whisper_cache)

      config = read_project_config(workspace_path)
      workspace_container = resolve_workspace_container_path(workspace_path, config)
      default_prompt = resolve_default_prompt_path(workspace_path, workspace_container)

      {
        tag: @options.tag,
        codex_root: codex_root,
        dockerfile: dockerfile,
        codex_home: codex_home,
        whisper_cache: whisper_cache,
        workspace_path: workspace_path,
        workspace_container: workspace_container,
        config: config,
        default_system_prompt: default_prompt
      }
    end

    def resolve_workspace_path(workspace, codex_root)
      return Dir.pwd if workspace.nil? || workspace.strip.empty?
      path = Pathname.new(workspace)
      return path.expand_path.to_s if path.absolute? && path.exist?
      candidate = Pathname.new(Dir.pwd).join(workspace)
      return candidate.expand_path.to_s if candidate.exist?
      candidate = Pathname.new(codex_root).join(workspace)
      return candidate.expand_path.to_s if candidate.exist?
      raise "Workspace path '#{workspace}' could not be resolved."
    end

    def resolve_codex_home(override)
      candidate = override || ENV["CODEX_CONTAINER_HOME"]
      if candidate.nil? || candidate.strip.empty?
        home = Dir.home
        candidate = File.join(home, ".codex-service")
      end
      FileUtils.mkdir_p(candidate)
      candidate
    end

    def resolve_workspace_container_path(workspace_path, config)
      return "/workspace" unless workspace_path
      workspace_name = File.basename(workspace_path.chomp("/"))
      workspace_name = "workspace" if workspace_name.empty?
      if config&.dig(:workspace_container)
        container = config[:workspace_container]
      elsif config&.dig(:workspace_mount_mode).to_s.downcase == "named"
        container = "/workspace/#{workspace_name}"
      else
        container = "/workspace"
      end
      container.start_with?("/") ? container.chomp("/") : "/workspace/#{container}".chomp("/")
    end

    def resolve_default_prompt_path(workspace_path, workspace_container)
      return nil if ENV["CODEX_DISABLE_DEFAULT_PROMPT"].to_s.match?(/^(1|true|on)$/i)
      candidates = []
      candidates << ENV["CODEX_SYSTEM_PROMPT_FILE"] if ENV["CODEX_SYSTEM_PROMPT_FILE"]
      candidates << "PROMPT.md"

      candidates.each do |candidate|
        next if candidate.nil? || candidate.strip.empty?
        host_path = Pathname.new(candidate)
        host_path = Pathname.new(workspace_path).join(candidate) unless host_path.absolute?
        next unless host_path.exist?
        workspace = Pathname.new(workspace_path).expand_path
        resolved = host_path.expand_path
        next unless resolved.to_s.start_with?(workspace.to_s)
        relative = resolved.to_s.sub(workspace.to_s, "").sub(%r{\A/}, "")
        return "#{workspace_container}/#{relative}"
      end
      nil
    end

    def read_project_config(workspace_path)
      config_path = find_config_file(workspace_path)
      return nil unless config_path
      case File.extname(config_path)
      when ".json"
        data = JSON.parse(File.read(config_path))
        normalize_config(data)
      when ".toml"
        parse_toml_config(File.read(config_path))
      else
        nil
      end
    rescue JSON::ParserError => e
      warn "Failed to parse JSON config #{config_path}: #{e.message}"
      nil
    end

    def find_config_file(workspace_path)
      return nil unless workspace_path
      candidates = [
        ".codex-container.json",
        ".codex_container.json",
        ".codex-container.toml",
        ".codex_container.toml"
      ].map { |name| File.join(workspace_path, name) }
      candidates.find { |path| File.exist?(path) }
    end

    def normalize_config(data)
      {
        env: data.fetch("env", {}),
        mounts: data.fetch("mounts", []),
        tools: data.fetch("tools", []),
        env_imports: data.fetch("env_imports", []),
        workspace_mount_mode: data["workspace_mount_mode"],
        workspace_container: data["workspace_container"]
      }
    end

    def parse_toml_config(content)
      env = {}
      env_imports = []
      mounts = []
      tools = []
      workspace_mount_mode = nil
      workspace_container = nil
      in_env = false
      in_mount = false
      current_mount = nil
      env_import_buffer = []
      in_env_imports = false

      content.each_line do |line|
        trim = line.strip
        if trim.start_with?("[[mounts]]")
          in_env = false
          if current_mount
            mounts << current_mount if current_mount.values.any?(&:itself)
          end
          current_mount = {}
          in_mount = true
          next
        end
        if trim.start_with?("[env]")
          in_env = true
          next
        end
        if trim.start_with?("[") && !trim.start_with?("[[")
          in_env = false
          if in_mount && current_mount
            mounts << current_mount if current_mount.values.any?(&:itself)
          end
          in_mount = false
        end

        if in_env && trim =~ /\A(?<k>[A-Za-z0-9_]+)\s*=\s*"(?<v>[^"]*)"\z/
          env[Regexp.last_match[:k]] = Regexp.last_match[:v]
        end
        workspace_mount_mode = Regexp.last_match[:v] if trim =~ /\Aworkspace_mount_mode\s*=\s*"(?<v>[^"]*)"\z/
        workspace_container = Regexp.last_match[:v] if trim =~ /\Aworkspace_container\s*=\s*"(?<v>[^"]*)"\z/
        if in_mount && trim =~ /\A(host|container|mode)\s*=\s*"(?<v>[^"]*)"\z/
          current_mount[Regexp.last_match(1)] = Regexp.last_match[:v]
        end
        if !in_env_imports && trim =~ /\Aenv_imports\s*=\s*\[(?<rest>.*)\z/
          in_env_imports = true
          env_import_buffer = []
          env_import_buffer << Regexp.last_match[:rest] if Regexp.last_match[:rest]
          if trim.include?("]")
            in_env_imports = false
            env_imports.concat(parse_array_buffer(env_import_buffer))
          end
          next
        end
        if in_env_imports
          env_import_buffer << trim
          if trim.include?("]")
            in_env_imports = false
            env_imports.concat(parse_array_buffer(env_import_buffer))
          end
        end
        if trim =~ /\Amounts\s*=\s*\[(?<arr>.*)\]\z/
          mounts.concat(parse_array_items(Regexp.last_match[:arr]))
        end
        if trim =~ /\Atools\s*=\s*\[(?<arr>.*)\]\z/
          tools.concat(parse_array_items(Regexp.last_match[:arr]))
        end
      end

      if in_mount && current_mount
        mounts << current_mount if current_mount.values.any?(&:itself)
      end

      {
        env: env,
        env_imports: env_imports,
        mounts: mounts,
        tools: tools,
        workspace_mount_mode: workspace_mount_mode,
        workspace_container: workspace_container
      }
    end

    def parse_array_buffer(buffer)
      joined = buffer.join(" ")
      joined = joined.sub(/\A\[/, "").sub(/\]\z/, "")
      parse_array_items(joined)
    end

    def parse_array_items(raw)
      raw.split(",").map { |item| item.strip.delete_prefix('"').delete_suffix('"') }.reject(&:empty?)
    end

    def ensure_docker_daemon!
      run_cmd(["docker", "info", "--format", "{{.ID}}"])
    rescue StandardError
      raise "Docker daemon not reachable. Start Docker Desktop and retry."
    end

    def ensure_docker_image!(tag)
      system("docker image inspect #{Shellwords.escape(tag)} >/dev/null 2>&1")
      return if $?.success?
      raise "Docker image '#{tag}' not found locally. Run glados --install first."
    end

    def ensure_codex_auth!(context, silent: false)
      auth_path = File.join(context[:codex_home], ".codex", "auth.json")
      if File.exist?(auth_path) && !File.read(auth_path).strip.empty?
        return
      end
      raise "Codex credentials not found. Re-run with --login." if silent || @options.no_auto_login
      announce("No Codex credentials detected; starting login flow.")
      login
      if !File.exist?(auth_path) || File.read(auth_path).strip.empty?
        raise "Codex login did not complete successfully."
      end
    end

    def build_base_run_args(context, expose_login_port: false, additional_args: [], additional_env: {}, gateway_mode: false)
      args = [
        "run",
        "--rm",
        "-it",
        "--user", "0:0",
        "--network", "codex-network",
        "--add-host", "host.docker.internal:host-gateway",
        "-v", "#{context[:codex_home]}:/opt/codex-home",
        "-v", "#{context[:whisper_cache]}:/opt/whisper-cache",
        "-e", "HOME=/opt/codex-home",
        "-e", "XDG_CONFIG_HOME=/opt/codex-home",
        "-e", "HF_HOME=/opt/whisper-cache"
      ]
      args << "--privileged" if @options.privileged
      args += ["-p", "1455:1455"] if expose_login_port

      workspace_mount = context[:workspace_path].to_s.tr("\\", "/")
      workspace_mount = "#{workspace_mount}/" if workspace_mount.match?(/\A[A-Za-z]:\/?\z/)
      args += ["-v", "#{workspace_mount}:#{context[:workspace_container]}", "-w", context[:workspace_container]] if workspace_mount

      config = context[:config]
      args.concat(build_mount_args(config&.dig(:mounts)))
      args.concat(build_env_args(config&.dig(:env)))
      args.concat(build_env_import_args(config&.dig(:env_imports)))

      if context[:default_system_prompt]
        args += ["-e", "CODEX_SYSTEM_PROMPT_FILE=#{context[:default_system_prompt]}"]
      end

      additional_env.each do |key, value|
        args += ["-e", "#{key}=#{value}"]
      end

      args.concat(additional_args) if additional_args
      args << context[:tag]
      args += ["/usr/bin/tini", "--"]
      unless gateway_mode
        args << "/usr/local/bin/codex_entry.sh"
        args << "--dangerously-bypass-approvals-and-sandbox" if @options.danger
      end
      args.compact
    end

    def build_mount_args(mounts)
      return [] unless mounts
      mounts.flat_map do |mount|
        host, container, mode = nil
        if mount.is_a?(String)
          host = mount
        else
          host = mount["host"] || mount[:host]
          container = mount["container"] || mount[:container]
          mode = mount["mode"] || mount[:mode]
        end
        next [] unless host
        host_norm = host.tr("\\", "/")
        container ||= "/workspace/#{File.basename(host_norm)}"
        suffix = mode.to_s.downcase == "ro" ? ":ro" : ""
        ["-v", "#{host_norm}:#{container}#{suffix}"]
      end.flatten
    end

    def build_env_args(env_map)
      return [] unless env_map
      env_map.flat_map { |key, value| value.nil? ? [] : ["-e", "#{key}=#{value}"] }
    end

    def build_env_import_args(names)
      return [] unless names
      names.flat_map do |name|
        value = ENV[name]
        value.nil? || value.empty? ? [] : ["-e", "#{name}=#{value}"]
      end
    end

    def run_container(context, command:, expose_login_port: false, additional_args: [], additional_env: {}, gateway_mode: false)
      args = build_base_run_args(
        context,
        expose_login_port: expose_login_port,
        additional_args: additional_args,
        additional_env: additional_env,
        gateway_mode: gateway_mode
      )
      args += command if command
      cleaned = args.reject { |arg| arg.nil? || arg == "" }
      run_cmd(["docker", *cleaned])
    end

    def run_codex(context, arguments)
      args = ["codex"]
      args << "--oss" if @options.oss
      args += ["--model", @options.oss_model] if @options.oss_model && !arguments.include?("--model")
      if @options.codex_model && !arguments.include?("--model")
        args += ["--model", @options.codex_model]
      end
      args += arguments

      run_container(context, command: args)
    end

    def build_exec_arguments
      raise "Exec requires a prompt." unless @options.exec
      args = ["exec", @options.exec]
      args.insert(1, "--skip-git-repo-check") unless args.include?("--skip-git-repo-check")
      if @options.json_e
        args.insert(1, "--experimental-json") unless args.include?("--experimental-json")
      elsif @options.json
        args.insert(1, "--json") unless args.include?("--json")
      end
      args
    end

    def build_run_arguments(context)
      resolved_session = resolve_session_id(context, @options.session_id)
      args = []
      args += ["resume", resolved_session] if resolved_session
      args.concat(@options.codex_args) if @options.codex_args.any?
      if !(@options.json || @options.json_e) && !resolved_session
        show_recent_sessions(context, limit: @options.recent_limit, since_days: @options.since_days)
      end
      args
    end

    def resolve_session_id(context, requested)
      return nil unless requested
      sessions_dir = File.join(context[:codex_home], ".codex", "sessions")
      return nil unless Dir.exist?(sessions_dir)
      matches = Dir.glob(File.join(sessions_dir, "**", "rollout-*.jsonl")).filter_map do |file|
        if file.match(/rollout-.*-([0-9a-f-]{36})\.jsonl$/)
          id = Regexp.last_match(1)
          id if id.end_with?(requested)
        end
      end
      raise "No session found matching '#{requested}'" if matches.empty?
      raise "Multiple sessions match '#{requested}': #{matches.join(', ')}" if matches.size > 1
      announce("Resuming session: #{matches.first}")
      matches.first
    end

    def show_recent_sessions(context, limit:, since_days:)
      sessions_dir = File.join(context[:codex_home], ".codex", "sessions")
      return unless Dir.exist?(sessions_dir)
      cutoff = since_days.to_i > 0 ? Time.now - (since_days.to_i * 86_400) : nil
      files = Dir.glob(File.join(sessions_dir, "**", "rollout-*.jsonl"))
      files = files.select { |f| cutoff.nil? || File.mtime(f) >= cutoff }
      files = files.sort_by { |f| File.mtime(f) }.reverse.first(limit.to_i)
      return if files.empty?

      puts "\nRecent Codex sessions:\n\n"
      files.each do |file|
        next unless file.match(/rollout-.*-([0-9a-f-]{36})\.jsonl$/)
        session_id = Regexp.last_match(1)
        short_id = session_id[-5..]
        age = Time.now - File.mtime(file)
        age_str = if age < 3600
                    "#{(age / 60).floor} min ago"
                  elsif age < 86_400
                    "#{(age / 3600).floor}h ago"
                  else
                    "#{(age / 86_400).floor}d ago"
                  end

        preview = ""
        begin
          first_line = File.open(file, &:readline)
          json = JSON.parse(first_line)
          if json["role"] == "user" && json["content"]
            preview = json["content"][0, 70]
            preview = "#{preview[0, 67]}..." if preview.length > 70
          end
        rescue EOFError, JSON::ParserError
          preview = ""
        end

        puts "  [#{age_str}] ...#{short_id}"
        puts "    #{preview}" unless preview.empty?
        puts "    glados --session-id #{short_id}\n\n"
      end
    end

    def shell_join(args)
      args.map { |arg| arg.include?(" ") ? "'#{arg.gsub("'", "'\\''")}'" : arg }.join(" ")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Glados::CLI.new(ARGV).run
end
