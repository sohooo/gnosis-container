#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/glados"

class GladosCliTest < Minitest::Test
  def test_parses_exec_prompt
    cli = Glados::CLI.new(["--exec", "say hello"])
    assert_equal "say hello", cli.send(:options).exec
  end

  def test_requires_single_action
    cli = Glados::CLI.new(["--exec", "hi", "--shell"])
    error = assert_raises(RuntimeError) { cli.run }
    assert_match(/Specify only one primary action/, error.message)
  end

  def test_builds_exec_arguments_with_json_flags
    cli = Glados::CLI.new(["--exec", "hi", "--json-e"])
    args = cli.send(:build_exec_arguments)
    assert_includes args, "exec"
    assert_includes args, "--experimental-json"
    assert_includes args, "--skip-git-repo-check"
  end

  def test_resolves_workspace_path_default
    cli = Glados::CLI.new([])
    path = cli.send(:resolve_workspace_path, nil, Dir.pwd)
    assert_equal Dir.pwd, path
  end
end
