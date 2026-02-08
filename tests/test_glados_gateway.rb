#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../scripts/glados_gateway"

class GladosGatewayTest < Minitest::Test
  def setup
    @fixed_time = Time.utc(2025, 1, 15, 10, 30, 0)
    @runner_calls = []
    @runner = lambda do |prompt, model:, json_mode:, timeout_ms:, env:|
      @runner_calls << { prompt: prompt, model: model, json_mode: json_mode, timeout_ms: timeout_ms, env: env }
      { stdout: "ok", stderr: "", exit_code: 0 }
    end
  end

  def build_gateway(session_dir:)
    GladosGateway.new(
      session_dirs: [session_dir],
      codex_runner: @runner,
      clock: -> { @fixed_time },
      monotonic: -> { 123.4 },
      sleeper: ->(_seconds) {}
    )
  end

  def test_health_endpoint
    session_dir = Dir.mktmpdir
    gateway = build_gateway(session_dir: session_dir)
    status, _headers, body = request(gateway, "GET", "/health")
    assert_equal 200, status
    assert_equal({ "status" => "ok" }, JSON.parse(body))
  ensure
    FileUtils.remove_entry_secure(session_dir) if session_dir
  end

  def test_completion_writes_summary_and_returns_output
    session_dir = Dir.mktmpdir
    gateway = build_gateway(session_dir: session_dir)

    payload = { "prompt" => "hello", "json_mode" => true, "model" => "gpt-test" }
    status, _headers, raw_body = request(gateway, "POST", "/completion", body: JSON.generate(payload))

    assert_equal 200, status
    body = JSON.parse(raw_body)
    assert_equal "ok", body["output"]
    assert_equal "", body["stderr"]
    assert_equal 0, body["exit_code"]
    assert_equal "gpt-test", body["model"]

    summary = read_summary(body["logs_path"])
    assert_equal "hello", summary["prompt"]
    assert_equal "ok", summary["output"]
    assert_equal @fixed_time.iso8601, summary["created_at"]
    assert_equal "", summary["stderr"]
    assert_equal 0, summary["exit_code"]
    assert_equal 1, @runner_calls.size
  ensure
    FileUtils.remove_entry_secure(session_dir) if session_dir
  end

  def test_sessions_listing_and_detail
    session_dir = Dir.mktmpdir
    gateway = build_gateway(session_dir: session_dir)

    status, _headers, raw_body = request(gateway, "POST", "/completion", body: JSON.generate("prompt" => "hello"))
    body = JSON.parse(raw_body)
    assert_equal 200, status

    list_status, _list_headers, list_body = request(gateway, "GET", "/sessions")
    assert_equal 200, list_status
    sessions = JSON.parse(list_body)["sessions"]
    assert_includes sessions, File.basename(body["logs_path"])

    detail_status, _detail_headers, detail_body = request(gateway, "GET", "/sessions/#{File.basename(body["logs_path"])}")
    assert_equal 200, detail_status
    detail_body = JSON.parse(detail_body)
    assert_equal "hello", detail_body["prompt"]
    assert detail_body["logs"]["tail"].include?("prompt: hello")
  ensure
    FileUtils.remove_entry_secure(session_dir) if session_dir
  end

  def test_session_detail_tail_lines
    session_dir = Dir.mktmpdir
    gateway = build_gateway(session_dir: session_dir)

    status, _headers, raw_body = request(gateway, "POST", "/completion", body: JSON.generate("prompt" => "hello"))
    body = JSON.parse(raw_body)
    assert_equal 200, status

    detail_status, _detail_headers, detail_body = request(
      gateway,
      "GET",
      "/sessions/#{File.basename(body["logs_path"])}?tail_lines=1"
    )
    assert_equal 200, detail_status
    detail_body = JSON.parse(detail_body)
    assert_equal 1, detail_body["logs"]["tail_lines"]
  ensure
    FileUtils.remove_entry_secure(session_dir) if session_dir
  end

  def test_retries_on_empty_output_when_enabled
    session_dir = Dir.mktmpdir
    calls = 0
    runner = lambda do |prompt, model:, json_mode:, timeout_ms:, env:|
      calls += 1
      if calls < 2
        { stdout: "", stderr: "", exit_code: 0 }
      else
        { stdout: "ok", stderr: "", exit_code: 0 }
      end
    end

    gateway = GladosGateway.new(
      session_dirs: [session_dir],
      codex_runner: runner,
      clock: -> { @fixed_time },
      monotonic: -> { 123.4 },
      max_retries: 2,
      retry_on_empty: true,
      sleeper: ->(_seconds) {}
    )

    status, _headers, raw_body = request(gateway, "POST", "/completion", body: JSON.generate("prompt" => "hello"))
    body = JSON.parse(raw_body)
    assert_equal 200, status
    assert_equal "ok", body["output"]
    assert_equal 2, calls
  ensure
    FileUtils.remove_entry_secure(session_dir) if session_dir
  end

  def test_returns_429_when_concurrency_exceeded
    session_dir = Dir.mktmpdir
    limiter = GladosGateway::ConcurrencyLimiter.new(1)
    limiter.try_acquire

    gateway = GladosGateway.new(
      session_dirs: [session_dir],
      codex_runner: @runner,
      clock: -> { @fixed_time },
      monotonic: -> { 123.4 },
      max_concurrent: 1,
      sleeper: ->(_seconds) {}
    )
    gateway.instance_variable_set(:@concurrency, limiter)

    status, _headers, body = request(gateway, "POST", "/completion", body: JSON.generate("prompt" => "hello"))
    parsed = JSON.parse(body)
    assert_equal 429, status
    assert_equal "Too many concurrent requests", parsed["error"]
    assert_equal 5, parsed["retry_after"]
  ensure
    limiter.release
    FileUtils.remove_entry_secure(session_dir) if session_dir
  end

  private

  def request(gateway, method, path, body: nil)
    input = StringIO.new(body.to_s)
    path_info, query = path.split("?", 2)
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path_info,
      "QUERY_STRING" => query.to_s,
      "rack.input" => input,
      "CONTENT_TYPE" => "application/json",
      "CONTENT_LENGTH" => body.to_s.bytesize.to_s
    }
    status, headers, response_body = gateway.call(env)
    [status, headers, response_body.join]
  end

  def read_summary(path)
    JSON.parse(File.read(File.join(path, "summary.json")))
  end

end
