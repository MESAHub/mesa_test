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
require 'socket'

REPO = File.expand_path('../..', __dir__)
TESTHUB_DIR = ENV['TESTHUB_DIR'] && File.expand_path(ENV['TESTHUB_DIR'])
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
    out = utf8(out)
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

  # From the fake MESA's timing log: the build's thread settings, and one
  # { test:, start:, finish:, omp: } per test run.
  def timing
    path = File.join(@dir, 'timing_log.txt')
    lines = File.exist?(path) ? File.readlines(path, chomp: true) : []
    build = lines.grep(/\Abuild /).first
    runs = lines.grep_v(/\Abuild /).map do |l|
      start, finish, test, omp = l.split
      { test: test, start: start.to_f, finish: finish.to_f, omp: omp.delete_prefix('omp=') }
    end
    [build, runs]
  end

  # No bulk submissions: exactly one build-status submission (empty) plus
  # one submission per test, none `entire`.
  def self.one_build_then_per_test?(submissions)
    submissions.none? { |sub| sub['entire'] } &&
      submissions.count { |sub| sub['empty'] } == 1 &&
      submissions.count { |sub| !sub['empty'] } == TESTS.size
  end

  # Largest number of runs in progress at once.
  def self.max_overlap(runs)
    events = runs.flat_map { |r| [[r[:start], 1], [r[:finish], -1]] }.sort_by { |t, d| [t, d] }
    events.reduce([0, 0]) { |(cur, best), (_, d)| [cur + d, [best, cur + d].max] }.last
  end

  def work_dir
    File.join(@dir, 'work')
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
    out = utf8(out)
    raise "bin/rails #{task} failed:\n#{out}" unless status.success?

    out.lines.last.to_s.strip
  end

  # Subprocess output is UTF-8 (e.g. the "·" in claim environments)
  # whatever the shell's locale says.
  def utf8(text)
    text.dup.force_encoding(Encoding::UTF_8)
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

# A stand-in hub for the "nothing to do" checks: real dev data always has
# some recent commit to recommend, so this answers check_computer with
# "valid" and every dispatch with 204, and records every request it sees.
class StubHub
  attr_reader :requests

  def initialize
    @server = TCPServer.new('127.0.0.1', 0)
    @requests = []
    @thread = Thread.new { loop { serve(@server.accept) } }
  end

  def url
    "http://127.0.0.1:#{@server.addr[1]}"
  end

  def stop
    @thread.kill
    @server.close
  end

  private

  def serve(client)
    method, path = client.gets.to_s.split
    length = 0
    while (line = client.gets) && line != "\r\n"
      length = line.split(':', 2).last.to_i if line =~ /\Acontent-length:/i
    end
    client.read(length) if length.positive?
    @requests << "#{method} #{path}"
    case path
    when '/check_computer.json'
      body = '{"valid":true,"message":"stub hub"}'
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    when '/api/v1/dispatch'
      client.write("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
    else
      client.write("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    end
  ensure
    client.close
  end
end

# Run mesa_test with a scratch HOME/config pointed at +url+; [status, output].
def standalone_mesa_test(dir, url, *args)
  home = File.join(dir, 'home')
  FileUtils.mkdir_p(File.join(home, '.mesa_test'))
  File.write(File.join(home, '.mesa_test', 'config.yml'), {
    'computer_name' => 'stub-box', 'email' => '', 'password' => '',
    'api_key' => 'mth_stub', 'capabilities' => [], 'logs_token' => nil,
    'github_protocol' => :https, 'mesa_mirror' => File.join(dir, 'mirror'),
    'mesa_work' => File.join(dir, 'work'), 'platform' => 'linux', 'platform_version' => 'e2e'
  }.to_yaml)
  cmd = ['ruby', '-I', File.join(REPO, 'lib'), File.join(REPO, 'bin', 'mesa_test'), *args]
  out, status = Open3.capture2e({ 'HOME' => home, 'MESATESTHUB_URL' => url }, *cmd, chdir: dir)
  [status.exitstatus, out]
end

# Same reporting shape as Scenario, for checks that need no testhub fixture.
class StandaloneCheck
  attr_reader :failures

  def initialize(name)
    @name = name
    @failures = []
  end

  def run
    puts "\n== #{@name}"
    Dir.mktmpdir('mesa_test_e2e') { |dir| yield self, dir }
  rescue StandardError => e
    @failures << "#{e.class}: #{e.message}"
  ensure
    puts(@failures.empty? ? '   ok' : @failures.map { |f| "   FAIL: #{f}" })
  end

  def check(condition, message)
    @failures << message unless condition
  end
end

SCENARIOS = {
  # The cluster workflow: install best, submit the build, then one
  # `mesa_test test N` per test (array jobs) in a shell that skips optional
  # inlists. The modes recorded at install must win over the shell.
  'cluster' => lambda do
    Scenario.new('cluster: install best / submit --empty / test N',
                 wants: %w[optional fpe], auth: :key, capabilities: %w[full_inlists]).run do |s|
      shell = { 'MESA_SKIP_OPTIONAL' => 't', 'OMP_NUM_THREADS' => '3', 'MESASDK_VERSION' => 'e2e-sdk' }
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
      # Claims say what they run on: test claims from the build's own
      # testhub.yml, the build claim from the shell (made before compiling).
      tests_env = r['claims'].select { |c| c['scope'] == 'test' }.map { |c| c['environment'] }.uniq
      s.check(tests_env == ['SDK aarch64-macos-26.3.2 · gfortran 15.2.0 · CRMATH · 3 threads · linux e2e'],
              "test claims' environment: #{tests_env}")
      build_env = r['claims'].find { |c| c['scope'] == 'build' }&.dig('environment')
      s.check(build_env == 'SDK e2e-sdk · 3 threads · linux e2e', "build claim's environment: #{build_env.inspect}")
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

  # `[ci converge 0.5]` names its factor: it beats the shell's own
  # MESA_TEST_SUITE_RESOLUTION_FACTOR (with a warning) at install and in
  # every array job, and only runs at 0.5 satisfy the request.
  'converge-factor' => lambda do
    Scenario.new('[ci converge 0.5]: the named factor wins, with a warning',
                 wants: %w[converge=0.5], auth: :key, capabilities: %w[converge]).run do |s|
      shell = { 'MESA_SKIP_OPTIONAL' => 't', 'MESA_TEST_SUITE_RESOLUTION_FACTOR' => '0.9' }
      status, out = s.mesa_test('install', 'best', env: shell)
      s.check(status.zero?, "install best exited #{status}")
      s.check(out.include?('asked for resolution factor 0.5') && out.include?('=0.9'),
              'no warning about overriding the shell factor at install')
      s.check(s.run_modes_in_testhub_yml == { 'resolution_factor' => '0.5' },
              "recorded modes were #{s.run_modes_in_testhub_yml.inspect}")

      s.mesa_test('submit', '--empty', env: shell)
      _, out = s.mesa_test('test', '1', env: shell)
      s.check(out.include?('set up for resolution factor 0.5'), 'no warning in the array job')
      s.mesa_test('test', '2', env: shell)
      s.mesa_test('test', '3', env: shell)
      s.check(tests_logged(s).size == TESTS.size && tests_logged(s).all? { |l| l.end_with?('res=0.5') },
              "array jobs didn't run at 0.5: #{tests_logged(s)}")

      r = s.report
      s.check(r['converge_factor'] == 0.5, "commit's factor: #{r['converge_factor'].inspect}")
      s.check(r['runs'].all? { |run| run['resolution_factor'] == 0.5 }, "runs: #{r['runs']}")
      s.check(r['satisfied']['converge'], "converge request not met: #{r['satisfied']}")
    end
  end,

  # --jobs / --test-threads / --build-threads on a whole-suite run: the
  # build gets NPROCS + OMP_NUM_THREADS, tests run concurrently with their
  # own thread count and log, the build status is submitted on its own,
  # and each test is claimed as it starts and submitted as it finishes.
  'parallel' => lambda do
    Scenario.new('install_and_test SHA --jobs 3 (whole suite, parallel)', wants: [], auth: :key).run do |s|
      status, out = s.mesa_test('install_and_test', s.sha, '--jobs', '3', '--test-threads', '2',
                                '--build-threads', '4', env: { 'OMP_NUM_THREADS' => '8' })
      s.check(status.zero?, "install_and_test --jobs 3 exited #{status}")
      build, runs = s.timing
      s.check(build == 'build nprocs=4 omp=4', "build threads: #{build.inspect}")
      s.check(runs.size == TESTS.size && runs.all? { |r| r[:omp] == '2' }, "runs: #{runs}")
      s.check(Scenario.max_overlap(runs) >= 2, "tests didn't overlap: #{runs}")
      s.check(out.scan(/\[\d+\/#{TESTS.size}\] \S+: pass/).size == TESTS.size, 'missing per-test progress lines')
      logs = Dir[File.join(s.work_dir, '*', 'test_suite', '*', 'each_test_run.log')]
      s.check(logs.size == TESTS.size, "per-test logs: #{logs.size}")
      r = s.report
      s.check(Scenario.one_build_then_per_test?(r['submissions']), "submissions: #{r['submissions']}")
      s.check(r['claims'].size == 1 + TESTS.size && r['claims'].all? { |c| c['status'] == 'fulfilled' },
              "claims: #{r['claims']}")
    end
  end,

  # `install_and_test best --jobs 2`: workers share the dispatch loop
  # without ever running one test twice at once, and finish the same work
  # the serial loop does.
  'parallel-best' => lambda do
    Scenario.new('install_and_test best --jobs 2', wants: %w[optional converge], auth: :key,
                                                   capabilities: %w[full_inlists converge]).run do |s|
      status, out = s.mesa_test('install_and_test', 'best', '--jobs', '2',
                                env: { 'MESA_SKIP_OPTIONAL' => 't', 'OMP_NUM_THREADS' => '8' })
      s.check(status.zero?, "install_and_test best --jobs 2 exited #{status}")
      _, runs = s.timing
      # No --test-threads: the shell's 8 is split across the 2 jobs.
      s.check(runs.all? { |r| r[:omp] == '4' }, "per-test threads: #{runs.map { |r| r[:omp] }.uniq}")
      s.check(out.include?('2 tests at a time, 4 threads each (OMP_NUM_THREADS=8 ÷ 2)'),
              'no message about the thread split')
      s.check(runs.size == 2 * TESTS.size, "expected #{2 * TESTS.size} runs, got #{runs.size}")
      s.check(Scenario.max_overlap(runs) == 2, "max concurrent runs: #{Scenario.max_overlap(runs)}")
      same_test_overlap = runs.group_by { |r| r[:test] }.values.any? { |rs| Scenario.max_overlap(rs) > 1 }
      s.check(!same_test_overlap, 'one test ran twice at the same time')
      s.check(tests_logged(s).none? { |l| l.include?('skip_optional=unset') && !l.include?('res=unset') },
              'a run combined full inlists and converge')
      r = s.report
      s.check(r['claims'].all? { |c| c['status'] == 'fulfilled' }, "claims: #{r['claims']}")
      s.check(r['runs'].size == 2 * TESTS.size, "hub saw #{r['runs'].size} runs")
      s.check(r['satisfied']['optional'] && r['satisfied']['converge'], "requests: #{r['satisfied']}")
    end
  end,

  # `test` (all tests) and a later plain `submit` also never send a bulk
  # submission: `test --no-submit` sends nothing at all, then `submit` sends
  # the build status and one submission per test with results.
  'submit-split' => lambda do
    Scenario.new('test --no-submit, then submit (no bulk submission)', wants: [], auth: :key).run do |s|
      s.mesa_test('install', s.sha, '--no-claim')
      status, = s.mesa_test('test', '--no-submit')
      s.check(status.zero?, "test --no-submit exited #{status}")
      s.check(tests_logged(s).size == TESTS.size, "runs: #{tests_logged(s)}")
      s.check(s.report['submissions'].empty?, '--no-submit submitted something')

      status, = s.mesa_test('submit')
      s.check(status.zero?, "submit exited #{status}")
      r = s.report
      s.check(Scenario.one_build_then_per_test?(r['submissions']), "submissions: #{r['submissions']}")
      s.check(r['runs'].size == TESTS.size, "hub saw #{r['runs'].size} runs")
    end
  end,

  # When the hub has nothing for this computer, every dispatching command
  # exits NOTHING_TO_DO_EXIT without touching the work directory or claiming
  # anything -- and an unreachable hub is an ordinary failure, not "nothing
  # to do", so scripts can tell the two apart. Needs no testhub server.
  'nothing' => lambda do
    check = StandaloneCheck.new('nothing to do: exit 3, work dir untouched')
    check.run do |c, dir|
      hub = StubHub.new
      begin
        [%w[install best], %w[install_and_test best], %w[request_work],
         %w[request_work --scope=test --sha=0123456789abcdef0123456789abcdef01234567]].each do |args|
          status, out = standalone_mesa_test(dir, hub.url, *args)
          c.check(status == NOTHING_TO_DO_EXIT,
                  "`mesa_test #{args.join(' ')}` exited #{status.inspect}, not #{NOTHING_TO_DO_EXIT}:\n#{out}")
        end
        c.check(!File.exist?(File.join(dir, 'work')), 'the work directory was created')
        stray = hub.requests.reject { |r| r.end_with?('/api/v1/dispatch', '/check_computer.json') }
        c.check(stray.empty?, "unexpected requests to the hub: #{stray}")
      ensure
        hub.stop
      end

      closed = TCPServer.new('127.0.0.1', 0)
      port = closed.addr[1]
      closed.close
      status, out = standalone_mesa_test(dir, "http://127.0.0.1:#{port}", 'install', 'best')
      c.check(![0, NOTHING_TO_DO_EXIT].include?(status),
              "an unreachable hub exited #{status.inspect}:\n#{out}")
    end
    check
  end,

  # Whole-suite run with email + password and an explicit SHA: the build
  # status goes in on its own, then each test is claimed as it starts and
  # submitted as it finishes (no bulk submission).
  'legacy' => lambda do
    Scenario.new('install_and_test SHA with email + password', wants: [], auth: :password).run do |s|
      status, out = s.mesa_test('install_and_test', s.sha, '--no-skip-optional',
                                env: { 'MESA_SKIP_OPTIONAL' => 't' })
      s.check(status.zero?, "install_and_test exited #{status}")
      # Results roll in: the first test is submitted before the last starts.
      first_submit = out.index('Successfully submitted instance')
      last_start = out.rindex('Testing ')
      s.check(first_submit && last_start && first_submit < last_start,
              'tests were not submitted as they finished')
      runs = tests_logged(s)
      s.check(runs.size == TESTS.size && runs.all? { |l| l.include?('skip_optional=unset') },
              "--no-skip-optional not applied: #{runs}")
      r = s.report
      s.check(Scenario.one_build_then_per_test?(r['submissions']), "submissions: #{r['submissions']}")
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

needs_testhub = wanted - %w[nothing]
if needs_testhub.any? && TESTHUB_DIR.nil?
  abort "Set TESTHUB_DIR to a MESATestHub checkout (needed for: #{needs_testhub.join(', ')})."
end

results = wanted.map { |name| SCENARIOS.fetch(name).call }
failed = results.reject { |r| r.failures.empty? }
puts "\n#{results.size - failed.size}/#{results.size} scenarios passed."
exit(failed.empty? ? 0 : 1)
