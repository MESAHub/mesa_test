#!/usr/bin/env ruby
# End-to-end check of mesa_test against a local MESATestHub dev server.
#
#   TESTHUB_DIR=~/Repositories/MESATestHub \
#   MESATESTHUB_URL=http://localhost:3000 \
#   ruby dev/e2e/run.rb [scenario ...]
#
# Needs: the testhub dev server running from TESTHUB_DIR (so its code
# matches), git-lfs, and nothing else -- no MESA build. Each scenario builds
# a fake MESA repo (fake_mesa.sh), seeds a throwaway user/computer/commit
# with the testhub's `dev:client_fixture:setup` task, runs real mesa_test
# commands (this checkout's lib + bin, under a scratch HOME, so your own
# ~/.mesa_test is never touched), then checks the testhub's view of what
# happened (`dev:client_fixture:report`) and the environment every fake
# build and test ran with. The fixture is torn down after each scenario.
require 'json'
require 'yaml'
require 'tmpdir'
require 'fileutils'
require 'open3'

REPO = File.expand_path('../..', __dir__)
TESTHUB_DIR = File.expand_path(ENV.fetch('TESTHUB_DIR') { abort 'Set TESTHUB_DIR to a MESATestHub checkout.' })
URL = ENV.fetch('MESATESTHUB_URL', 'http://localhost:3000')
TESTS = %w[star/fake_alpha star/fake_beta binary/fake_gamma].freeze
NOTHING_TO_DO_EXIT = 3

class Scenario
  attr_reader :failures

  def initialize(name, wants:, auth:, capabilities: [])
    @name = name
    @wants = wants
    @auth = auth
    @capabilities = capabilities
    @failures = []
  end

  # Scratch files (mesa_test logs, env log, work dir) are deleted afterwards
  # unless the scenario fails or E2E_KEEP is set.
  def run
    puts "\n== #{@name}"
    @dir = Dir.mktmpdir('mesa_test_e2e')
    begin
      @sha = sh!('bash', File.join(__dir__, 'fake_mesa.sh'), File.join(@dir, 'src')).lines.last.strip
      sh!('git', 'clone', '-q', '--mirror', File.join(@dir, 'src'), File.join(@dir, 'mirror'))
      fixture = JSON.parse(rails('dev:client_fixture:setup', 'SHA' => @sha, 'TESTS' => TESTS.join(','),
                                                             'WANTS' => @wants.join(',')))
      write_config(fixture)
      yield self
    rescue StandardError => e
      @failures << "#{e.class}: #{e.message}"
    ensure
      rails('dev:client_fixture:teardown')
    end
    puts(@failures.empty? ? '   ok' : @failures.map { |f| "   FAIL: #{f}" })
    if @failures.empty? && !ENV['E2E_KEEP']
      FileUtils.rm_rf(@dir)
    else
      puts "   scratch files kept in #{@dir}"
    end
    self
  end

  attr_reader :sha

  # Run mesa_test; returns [exit status, combined output].
  def mesa_test(*args, env: {})
    cmd = ['ruby', '-I', File.join(REPO, 'lib'), File.join(REPO, 'bin', 'mesa_test'), *args]
    out, status = Open3.capture2e({ 'HOME' => home, 'MESATESTHUB_URL' => URL }.merge(env), *cmd,
                                  chdir: @dir)
    File.write(File.join(@dir, "mesa_test-#{args.first}.log"), out, mode: 'a')
    [status.exitstatus, out]
  end

  def report
    JSON.parse(rails('dev:client_fixture:report'))
  end

  # Lines the fake install / each_test_run logged, e.g.
  # "test star/fake_alpha skip_optional=unset fpe=1 res=unset"
  def env_log
    path = File.join(@dir, 'env_log.txt')
    File.exist?(path) ? File.readlines(path, chomp: true) : []
  end

  def run_modes_in_testhub_yml
    YAML.safe_load(File.read(File.join(@dir, 'work', 'testhub.yml')))['mesa_test_run_modes']
  end

  def check(condition, message)
    @failures << message unless condition
  end

  private

  def home
    File.join(@dir, 'home')
  end

  def write_config(fixture)
    FileUtils.mkdir_p(File.join(home, '.mesa_test'))
    config = {
      'computer_name' => fixture['computer'], 'email' => fixture['email'],
      'password' => @auth == :password ? fixture['password'] : '',
      'api_key' => @auth == :key ? fixture['api_key'] : nil,
      'capabilities' => @capabilities, 'logs_token' => nil,
      'github_protocol' => :https,
      'mesa_mirror' => File.join(@dir, 'mirror'), 'mesa_work' => File.join(@dir, 'work'),
      'platform' => 'linux', 'platform_version' => 'e2e'
    }
    File.write(File.join(home, '.mesa_test', 'config.yml'), config.to_yaml)
  end

  def rails(task, env = {})
    out, status = Open3.capture2e({ 'DISABLE_SPRING' => '1' }.merge(env), 'bin/rails', task,
                                  chdir: TESTHUB_DIR)
    raise "bin/rails #{task} failed:\n#{out}" unless status.success?

    out.lines.last.to_s.strip
  end

  def sh!(*cmd)
    out, status = Open3.capture2e(*cmd)
    raise "#{cmd.join(' ')} failed:\n#{out}" unless status.success?

    out
  end
end

def tests_logged(s)
  s.env_log.grep(/\Atest /)
end

SCENARIOS = {
  # The cluster workflow: install best, submit the build, then one
  # `mesa_test test N` per test (array jobs) in a shell that skips optional
  # inlists. The modes recorded at install must win over the shell.
  'cluster' => lambda do
    Scenario.new('cluster: install best / submit --empty / test N',
                 wants: %w[optional fpe], auth: :key, capabilities: %w[full_inlists]).run do |s|
      shell = { 'MESA_SKIP_OPTIONAL' => 't' }
      status, = s.mesa_test('install', 'best', '--fpe', env: shell)
      s.check(status.zero?, "install best exited #{status}")
      s.check(s.env_log.first == 'install fpe=1', "install env was #{s.env_log.first.inspect}")
      s.check(s.run_modes_in_testhub_yml == { 'fpe' => true, 'skip_optional' => false },
              "recorded modes were #{s.run_modes_in_testhub_yml.inspect}")

      status, = s.mesa_test('submit', '--empty', env: shell)
      s.check(status.zero?, "submit --empty exited #{status}")
      (1..TESTS.size).each { |n| s.mesa_test('test', n.to_s, env: shell) }
      s.check(tests_logged(s).size == TESTS.size &&
              tests_logged(s).all? { |l| l.end_with?('skip_optional=unset fpe=1 res=unset') },
              "array-job runs didn't use the recorded modes: #{tests_logged(s)}")

      # Explicit flags beat the record -- except FPE, which is compiled in.
      _, out = s.mesa_test('test', '1', '--skip-optional', '--no-fpe', env: shell)
      s.check(out.include?('Ignoring --no-fpe'), 'no warning about overriding FPE')
      s.check(tests_logged(s).last.end_with?('skip_optional=t fpe=1 res=unset'),
              "explicit-flag run was #{tests_logged(s).last.inspect}")

      r = s.report
      s.check(r['claims'].any? && r['claims'].all? { |c| c['status'] == 'fulfilled' },
              "claims not all fulfilled: #{r['claims']}")
      build = r['submissions'].find { |sub| sub['empty'] }
      s.check(build && build['use_fpe'] && build['use_full_inlists'],
              "build submission didn't carry its modes: #{build.inspect}")
      s.check(r['runs'].size == TESTS.size + 1 && r['runs'].all? { |run| run['fpe_checks'] },
              "runs: #{r['runs']}")
      s.check(r['satisfied']['optional'] && r['satisfied']['fpe'],
              "requests not satisfied: #{r['satisfied']}")
    end
  end,

  # The hub drives everything. A commit wanting optional + converge gets
  # each test twice -- once per mode, never both in one run -- and then
  # nothing is left (exit 3).
  'best' => lambda do
    Scenario.new('install_and_test best',
                 wants: %w[optional converge], auth: :key,
                 capabilities: %w[full_inlists converge]).run do |s|
      status, = s.mesa_test('install_and_test', 'best', env: { 'MESA_SKIP_OPTIONAL' => 't' })
      s.check(status.zero?, "install_and_test best exited #{status}")
      runs = tests_logged(s)
      s.check(runs.size == 2 * TESTS.size, "expected #{2 * TESTS.size} runs, got #{runs}")
      s.check(runs.none? { |l| l.include?('skip_optional=unset') && !l.include?('res=unset') },
              "a run combined full inlists and converge: #{runs}")
      r = s.report
      s.check(r['claims'].all? { |c| c['status'] == 'fulfilled' }, "claims: #{r['claims']}")
      s.check(r['satisfied']['optional'] && r['satisfied']['converge'],
              "requests not satisfied: #{r['satisfied']}")

      status, out = s.mesa_test('request_work', '--scope=test', "--sha=#{s.sha}")
      s.check(status == NOTHING_TO_DO_EXIT && !out.include?('{'),
              "request_work with nothing left exited #{status}")
    end
  end,

  # Old-style whole-suite run with email + password and an explicit SHA:
  # still works, claims everything up front, one submission fulfills it all.
  'legacy' => lambda do
    Scenario.new('install_and_test SHA with email + password', wants: [], auth: :password).run do |s|
      status, = s.mesa_test('install_and_test', s.sha, '--no-skip-optional',
                            env: { 'MESA_SKIP_OPTIONAL' => 't' })
      s.check(status.zero?, "install_and_test exited #{status}")
      runs = tests_logged(s)
      s.check(runs.size == TESTS.size && runs.all? { |l| l.include?('skip_optional=unset') },
              "--no-skip-optional not applied: #{runs}")
      r = s.report
      s.check(r['submissions'].map { |sub| sub['entire'] } == [true], "submissions: #{r['submissions']}")
      s.check(r['claims'].size == 1 + TESTS.size && r['claims'].all? { |c| c['status'] == 'fulfilled' },
              "claims: #{r['claims']}")

      status, out = s.mesa_test('count', 'computer: client-fixture')
      s.check(status.zero? && JSON.parse(out.lines.last)['count'] == TESTS.size,
              "count over password auth: #{out.lines.last}")
    end
  end
}.freeze

wanted = ARGV.empty? ? SCENARIOS.keys : ARGV
unknown = wanted - SCENARIOS.keys
abort "Unknown scenario(s): #{unknown.join(', ')}. Known: #{SCENARIOS.keys.join(', ')}" if unknown.any?

results = wanted.map { |name| SCENARIOS.fetch(name).call }
failed = results.reject { |r| r.failures.empty? }
puts "\n#{results.size - failed.size}/#{results.size} scenarios passed."
exit(failed.empty? ? 0 : 1)
