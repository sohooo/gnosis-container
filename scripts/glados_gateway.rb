#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
begin
  require "rack"
rescue LoadError
  # Allow tests to run without rack installed; runtime requires rack.
end
require "securerandom"
require "stringio"
require "timeout"
require "time"
require "uri"
begin
  require "webrick"
rescue LoadError
  # Allow tests to run without webrick installed; runtime requires it.
end

class GladosGateway
  DEFAULT_PORT = Integer(ENV.fetch("CODEX_GATEWAY_PORT", "4000"))
  DEFAULT_HOST = ENV.fetch("CODEX_GATEWAY_BIND", "0.0.0.0")
  DEFAULT_TIMEOUT_MS = Integer(ENV.fetch("CODEX_GATEWAY_TIMEOUT_MS", "120000"))
  DEFAULT_IDLE_TIMEOUT_MS = Integer(ENV.fetch("CODEX_GATEWAY_IDLE_TIMEOUT_MS", "900000"))
  MAX_TIMEOUT_MS = Integer(ENV.fetch("CODEX_GATEWAY_MAX_TIMEOUT_MS", "1800000"))
  DEFAULT_MODEL = ENV.fetch("CODEX_GATEWAY_DEFAULT_MODEL", "")
  MAX_BODY_BYTES = Integer(ENV.fetch("CODEX_GATEWAY_MAX_BODY_BYTES", "1048576"))
  MAX_CONCURRENT = Integer(ENV.fetch("CODEX_GATEWAY_MAX_CONCURRENT", "2"))
  MAX_RETRIES = Integer(ENV.fetch("CODEX_GATEWAY_MAX_RETRIES", "0"))
  RETRY_BASE_DELAY_MS = Integer(ENV.fetch("CODEX_GATEWAY_RETRY_DELAY_MS", "2000"))
  RETRY_ON_EMPTY = ENV.fetch("CODEX_GATEWAY_RETRY_ON_EMPTY", "false") == "true"
  CODEX_JSON_FLAG = ENV.fetch("CODEX_GATEWAY_JSON_FLAG", "--experimental-json")
  EXTRA_ARGS = ENV.fetch("CODEX_GATEWAY_EXTRA_ARGS", "").split(/\s+/).reject(&:empty?)
  SECURE_SESSION_DIR = ENV["CODEX_GATEWAY_SECURE_SESSION_DIR"]
  SECURE_SESSION_TOKEN = ENV["CODEX_GATEWAY_SECURE_TOKEN"]
  DEFAULT_TAIL_LINES = Integer(ENV.fetch("CODEX_GATEWAY_DEFAULT_TAIL_LINES", "200"))
  MAX_TAIL_LINES = Integer(ENV.fetch("CODEX_GATEWAY_MAX_TAIL_LINES", "2000"))

  def initialize(config = {})
    @clock = config.fetch(:clock, -> { Time.now })
    @monotonic = config.fetch(:monotonic, -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @codex_runner = config.fetch(:codex_runner, method(:run_codex))
    @max_body_bytes = Integer(config.fetch(:max_body_bytes, MAX_BODY_BYTES))
    @default_timeout_ms = Integer(config.fetch(:default_timeout_ms, DEFAULT_TIMEOUT_MS))
    @max_timeout_ms = Integer(config.fetch(:max_timeout_ms, MAX_TIMEOUT_MS))
    @default_model = config.fetch(:default_model, DEFAULT_MODEL)
    @default_tail_lines = Integer(config.fetch(:default_tail_lines, DEFAULT_TAIL_LINES))
    @max_tail_lines = Integer(config.fetch(:max_tail_lines, MAX_TAIL_LINES))
    @concurrency = ConcurrencyLimiter.new(Integer(config.fetch(:max_concurrent, MAX_CONCURRENT)))
    @max_retries = Integer(config.fetch(:max_retries, MAX_RETRIES))
    @retry_base_delay_ms = Integer(config.fetch(:retry_base_delay_ms, RETRY_BASE_DELAY_MS))
    @retry_on_empty = config.fetch(:retry_on_empty, RETRY_ON_EMPTY)
    @sleeper = config.fetch(:sleeper, ->(seconds) { sleep(seconds) })

    session_dirs = config[:session_dirs] || session_dirs_from_env
    @session_dirs = normalize_dirs(session_dirs)
    @primary_session_dir = @session_dirs.first
    @secure_session_dir = config.fetch(:secure_session_dir, SECURE_SESSION_DIR)
    @secure_session_token = config.fetch(:secure_session_token, SECURE_SESSION_TOKEN)
  end

  def call(env)
    request = request_factory.new(env)
    path = request.path_info

    return json_response(200, status: "ok") if path == "/health"
    return info_response if path == "/"
    return status_response if path == "/status"

    case request.request_method
    when "POST"
      return handle_completion(request) if path == "/completion"
    when "GET"
      return list_sessions if path == "/sessions"
      return session_detail(request) if path.start_with?("/sessions/")
    end

    json_response(404, error: "Not found")
  rescue StandardError => e
    json_response(500, error: e.message)
  end

  def start!
    unless defined?(Rack::Handler::WEBrick)
      raise "Rack is required to start the gateway. Install the 'rack' gem."
    end
    Rack::Handler::WEBrick.run(
      self,
      Host: DEFAULT_HOST,
      Port: DEFAULT_PORT,
      AccessLog: [],
      Logger: WEBrick::Log.new($stdout, WEBrick::Log::WARN)
    )
  end

  private

  def request_factory
    @request_factory ||= if defined?(Rack::Request)
                           Rack::Request
                         else
                           SimpleRequest
                         end
  end

  class SimpleRequest
    def initialize(env)
      @env = env
    end

    def path_info
      @env.fetch("PATH_INFO", "/")
    end

    def request_method
      @env.fetch("REQUEST_METHOD", "GET")
    end

    def body
      @env.fetch("rack.input", StringIO.new(""))
    end

    def params
      query = @env.fetch("QUERY_STRING", "")
      return {} if query.nil? || query.empty?
      query.split("&").each_with_object({}) do |pair, memo|
        key, value = pair.split("=", 2)
        memo[URI.decode_www_form_component(key)] = URI.decode_www_form_component(value.to_s)
      end
    end
  end

  def info_response
    json_response(
      200,
      status: "glados-gateway",
      env: {
        "CODEX_GATEWAY_SESSION_DIRS" => @session_dirs
      },
      endpoints: {
        health: "/health",
        status: "/status",
        completion: { path: "/completion", method: "POST" },
        sessions: {
          list: { path: "/sessions", method: "GET" },
          detail: { path: "/sessions/:id", method: "GET" }
        }
      }
    )
  end

  def status_response
    json_response(
      200,
      concurrency: @concurrency.status,
      uptime: @monotonic.call.to_i
    )
  end

  def handle_completion(request)
    unless @concurrency.try_acquire
      return json_response(429, error: "Too many concurrent requests", retry_after: 5)
    end

    begin
      payload = parse_json_body(request)
      prompt = extract_prompt(payload)
      return json_response(400, error: "prompt or messages required") unless prompt

      timeout_ms = [payload["timeout_ms"].to_i, @default_timeout_ms].max
      timeout_ms = [timeout_ms, @max_timeout_ms].min
      json_mode = payload["json_mode"] == true
      model = payload["model"] || @default_model

      session_id = payload["session_id"] || "session-#{SecureRandom.hex(8)}"
      logs_path = prepare_session_dir(session_id)
      result = run_with_retries(prompt, model: model, json_mode: json_mode, timeout_ms: timeout_ms, env: payload["env"])

      write_session_output(
        logs_path,
        prompt,
        result[:stdout],
        stderr: result[:stderr],
        exit_code: result[:exit_code]
      )

      json_response(
        200,
        session_id: session_id,
        gateway_session_id: session_id,
        model: model,
        output: result[:stdout],
        stderr: result[:stderr],
        exit_code: result[:exit_code],
        logs_path: logs_path
      )
    rescue Timeout::Error
      json_response(408, error: "Timeout exceeded")
    rescue CodexExecutionError => e
      json_response(500, error: e.message, stderr: e.stderr, exit_code: e.exit_code)
    ensure
      @concurrency.release
    end
  end

  def list_sessions
    sessions = @session_dirs.flat_map do |dir|
      next [] unless Dir.exist?(dir)
      Dir.children(dir).select { |entry| File.directory?(File.join(dir, entry)) }
    end
    json_response(200, sessions: sessions.uniq.sort)
  end

  def session_detail(request)
    session_id = request.path_info.split("/").last
    secure = request.params["secure"] == "true"
    logs_path = find_session_dir(session_id, secure: secure)
    return json_response(404, error: "Session not found") unless logs_path

    payload_path = File.join(logs_path, "summary.json")
    summary = File.exist?(payload_path) ? JSON.parse(File.read(payload_path)) : { "session_id" => session_id }
    logs_path = File.join(logs_path, "run.log")
    tail = read_tail(logs_path, request.params["tail_lines"])

    json_response(
      200,
      summary.merge(
        "session_id" => session_id,
        "logs" => tail
      )
    )
  end

  def parse_json_body(request)
    body = request.body.read(@max_body_bytes + 1)
    raise "Body too large" if body.bytesize > @max_body_bytes
    return {} if body.strip.empty?
    JSON.parse(body)
  end

  def extract_prompt(payload)
    return payload["prompt"] if payload["prompt"].is_a?(String)
    messages = payload["messages"]
    return nil unless messages.is_a?(Array) && messages.any?
    messages.map { |msg| msg["content"] }.compact.join("\n")
  end

  def run_codex(prompt, model:, json_mode:, timeout_ms:, env:)
    command = ["codex", "exec", "--skip-git-repo-check"]
    command.insert(2, CODEX_JSON_FLAG) if json_mode
    command += ["--model", model] unless model.to_s.empty?
    command.concat(EXTRA_ARGS) if EXTRA_ARGS.any?
    command << prompt

    env_vars = {}
    if env.is_a?(Hash)
      env.each { |key, value| env_vars[key.to_s] = value.to_s }
    end

    Timeout.timeout(timeout_ms / 1000.0) do
      stdout_data = +""
      stderr_data = +""
      status = nil

      Open3.popen3(env_vars, *command) do |stdin, stdout, stderr, wait|
        stdin.close
        stdout_thread = Thread.new { stdout.read }
        stderr_thread = Thread.new { stderr.read }
        stdout_data = stdout_thread.value
        stderr_data = stderr_thread.value
        status = wait.value
      end

      result = {
        stdout: stdout_data.to_s.strip,
        stderr: stderr_data.to_s.strip,
        exit_code: status&.exitstatus
      }
      raise CodexExecutionError.new(result) unless status&.success?
      result
    end
  end

  def run_with_retries(prompt, model:, json_mode:, timeout_ms:, env:)
    attempts = 0
    loop do
      attempts += 1
      begin
        result = @codex_runner.call(prompt, model: model, json_mode: json_mode, timeout_ms: timeout_ms, env: env)
        if @retry_on_empty && result[:stdout].to_s.strip.empty? && attempts <= @max_retries
          sleep_retry(attempts)
          next
        end
        return result
      rescue CodexExecutionError => e
        if attempts <= @max_retries
          sleep_retry(attempts)
          next
        end
        raise e
      end
    end
  end

  def sleep_retry(attempt)
    delay_s = (@retry_base_delay_ms * attempt) / 1000.0
    @sleeper.call(delay_s)
  end

  def prepare_session_dir(session_id, secure: false)
    root = secure ? secure_session_root : @primary_session_dir
    FileUtils.mkdir_p(root)
    session_dir = File.join(root, session_id)
    FileUtils.mkdir_p(session_dir)
    session_dir
  end

  def write_session_output(session_dir, prompt, output, stderr: nil, exit_code: nil)
    payload = {
      prompt: prompt,
      output: output,
      created_at: @clock.call.utc.iso8601
    }
    payload[:stderr] = stderr if stderr
    payload[:exit_code] = exit_code if exit_code
    File.write(File.join(session_dir, "summary.json"), JSON.pretty_generate(payload))
    log_path = File.join(session_dir, "run.log")
    log_lines = []
    log_lines << "[#{@clock.call.utc.iso8601}] prompt: #{prompt}"
    log_lines << "[#{@clock.call.utc.iso8601}] output: #{output}"
    log_lines << "[#{@clock.call.utc.iso8601}] stderr: #{stderr}" if stderr
    log_lines << "[#{@clock.call.utc.iso8601}] exit_code: #{exit_code}" if exit_code
    File.open(log_path, "a") { |file| file.puts(log_lines) }
  end

  def find_session_dir(session_id, secure: false)
    candidates = secure ? [secure_session_root] : @session_dirs
    candidates.each do |dir|
      next unless dir
      candidate = File.join(dir, session_id)
      return candidate if Dir.exist?(candidate)
    end
    nil
  end

  def session_dirs_from_env
    dirs = []
    if (multi = ENV["CODEX_GATEWAY_SESSION_DIRS"])
      dirs.concat(multi.split(",").map(&:strip))
    end
    dirs << ENV["CODEX_GATEWAY_SESSION_DIR"] if ENV["CODEX_GATEWAY_SESSION_DIR"]
    if dirs.empty?
      dirs << File.join(Dir.pwd, ".codex-gateway-sessions")
      codex_home = ENV["CODEX_GATEWAY_CODEX_HOME"] || ENV["CODEX_HOME"] || ENV["HOME"] || "/opt/codex-home"
      dirs << File.join(codex_home, "sessions", "gateway")
    end
    dirs << File.join(Dir.pwd, ".codex-gateway-sessions")
    dirs
  end

  def secure_session_root
    return @secure_session_dir if @secure_session_dir && !@secure_session_dir.empty?
    File.join(@primary_session_dir, "secure")
  end

  def read_tail(path, requested)
    lines = parse_tail_lines(requested)
    return { "tail" => "", "tail_lines" => lines } unless File.exist?(path)
    file_lines = File.readlines(path, chomp: true)
    tail = file_lines.last(lines).join("\n")
    { "tail" => tail, "tail_lines" => lines }
  end

  def parse_tail_lines(requested)
    return @default_tail_lines if requested.nil? || requested.to_s.strip.empty?
    value = requested.to_i
    return @default_tail_lines if value <= 0
    [value, @max_tail_lines].min
  end

  def normalize_dirs(list)
    list.map { |entry| File.expand_path(entry) }.uniq
  end

  def json_response(status, payload)
    [status, { "Content-Type" => "application/json" }, [JSON.generate(payload)]]
  end

  class CodexExecutionError < StandardError
    attr_reader :stderr, :exit_code

    def initialize(result)
      @stderr = result[:stderr]
      @exit_code = result[:exit_code]
      super("Codex execution failed (exit #{@exit_code})")
    end
  end

  class ConcurrencyLimiter
    def initialize(max)
      @max = max
      @active = 0
      @mutex = Mutex.new
    end

    def try_acquire
      @mutex.synchronize do
        return false if @active >= @max
        @active += 1
        true
      end
    end

    def release
      @mutex.synchronize do
        @active -= 1 if @active.positive?
      end
    end

    def status
      @mutex.synchronize do
        {
          active: @active,
          max: @max,
          available: @max - @active
        }
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  GladosGateway.new.start!
end
