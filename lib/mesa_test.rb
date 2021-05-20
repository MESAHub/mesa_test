require 'fileutils'
require 'socket'
require 'os'
require 'yaml'
require 'uri'
require 'net/http'
require 'net/https'
require 'thor'
require 'json'
require 'base64'

MesaDirError = Class.new(StandardError)
TestCaseDirError = Class.new(StandardError)
InvalidDataType = Class.new(StandardError)
GitHubError = Class.new(StandardError)

GITHUB_HTTPS = 'https://github.com/MESAHub/mesa.git'.freeze
GITHUB_SSH = 'git@github.com:MESAHub/mesa.git'.freeze

class MesaTestSubmitter
  DEFAULT_URI = 'https://mesa-test-hub.herokuapp.com'.freeze

  # set up config file for computer
  def setup
    update do |s|
      shell.say 'This wizard will guide you through setting up a computer
profile and default data for test case submissions to MESATestHub. You
will be able to confirm entries at the end. Default/current values are always
shown in parentheses at the end of a prompt. Pressing enter will accept the
default values.

To submit to MESATestHub, a valid computer name, email address, and password
are all required. To actually run a test, you need to specify a location for
your base MESA git repository. All other data are useful, but optional. Any data
transferred to MESATestHub will be encrypted via HTTPS, but be warned that your
e-mail and password will be stored in plain text.'
      # Get computer name
      response = shell.ask('What is the name of this computer (required)? ' \
        "(#{s.computer_name}):", :blue)
      s.computer_name = response unless response.empty?

      # Get user e-mail
      response = shell.ask 'What is the email you can be reached ' \
        "at (required)? (#{s.email}):", :blue
      s.email = response unless response.empty?

      # Get user password
      response = shell.ask 'What is the password associated with the email ' \
        "#{s.email} (required)? (#{s.password})", :blue
      s.password = response unless response.empty?

      # Get API key for submitting failure logs
      response = shell.ask 'What is the logs submission API token associated '\
        "with the email #{s.email} (required; contact Josiah Schwab if you "\
        "need a key)? (#{s.logs_token})", :blue
      s.logs_token = response unless response.empty?

      # Determine if we'll use ssh or https to access github
      response = shell.ask 'When accessing GitHub, which protocol do you '\
        'want to use?', :blue, limited_to: %w[ssh https]
      s.github_protocol = response.strip.downcase.to_sym

      # Get location of source MESA repo (the mirror)
      response = shell.ask "Where is/should your mirrored MESA repository " \
      "located? This is where a mirror will be stored from which test " \
      "repos will be generated. You won't touch this in regular operation. " \
      "(#{s.mesa_mirror}):", :blue
      s.mesa_mirror = response unless response.empty?

      # Get location of source MESA work (where testing happens)
      response = shell.ask "Where is/should your working directory for "\
      "testing be located? This is where testing actually occurs, but all "\
      "files it uses are cached in the mirror repo to save time later. " \
      "(#{s.mesa_work}):", :blue
      s.mesa_work = response unless response.empty?

      # Get platform information
      response = shell.ask 'What is the platform of this computer (eg. ' \
        "macOS, Ubuntu)? (#{s.platform}):", :blue
      s.platform = response unless response.empty?
      response = shell.ask 'What is the version of the platform (eg. 10.15.5, ' \
        "Ubuntu 16.04)? (#{s.platform_version}):", :blue
      s.platform_version = response unless response.empty?

      # we are powerless to do change the location for now, so stop asking
      # about it
      # # Confirm save location
      # response = shell.ask "This will be saved in #{s.config_file}. Press " \
      #   'enter to accept or enter a new location:', :blue, path: true
      # s.config_file = response unless response.empty?
    end

    # Confirm data. If not confirmed, restart whole wizard.
    if confirm_computer_data
      save_computer_data
    else
      shell.say "Restarting wizard.\n"
      setup
    end
  end

  def self.new_from_config(
    config_file: File.join(ENV['HOME'], '.mesa_test', 'config.yml'),
    force_setup: false,
    base_uri: DEFAULT_URI
  )
    new_submitter = new(config_file: config_file, base_uri: base_uri)
    if force_setup
      new_submitter.setup
    elsif not File.exist? config_file
      puts "No such config file #{config_file}. Starting setup wizard."
      new_submitter.setup
    end
    new_submitter.load_computer_data
    return new_submitter
  end

  attr_accessor :computer_name, :user_name, :email, :password, :platform,
                :mesa_mirror, :mesa_work, :platform_version, :processor,
                :config_file, :base_uri, :github_protocol, :logs_token

  attr_reader :shell

  # many defaults are set in body
  def initialize(
      computer_name: nil, user_name: nil, email: nil, github_protocol: nil,
      mesa_mirror: nil, platform: nil, platform_version: nil, processor: nil,
      config_file: nil, base_uri: nil, logs_token: nil
  )
    @computer_name = computer_name || Socket.gethostname.scan(/^[^\.]+\.?/)[0]
    @computer_name.chomp!('.') if @computer_name
    @user_name = user_name || (ENV['USER'] || ENV['USERNAME'])
    @email = email || ''
    @password = password || ''
    @github_protocol = github_protocol || :ssh
    @mesa_mirror = mesa_mirror ||
      File.join(ENV['HOME'], '.mesa_test', 'mirror')
    @mesa_work = mesa_work ||
      File.join(ENV['HOME'], '.mesa_test', 'work')
    @platform = platform
    if @platform.nil?
      @platform =
        if OS.osx?
          'macOS'
        elsif OS.linux?
          'Linux'
        else
          ''
        end
    end
    @platform_version = platform_version || ''
    @processor = processor || ''
    @config_file = config_file || File.join(ENV['HOME'], '.mesa_test',
                                            'config.yml')
    @base_uri = base_uri
    @logs_token = logs_token || ENV['MESA_LOGS_TOKEN']

    # set up thor-proof way to get responses from user. Thor hijacks the
    # gets command, so we have to use its built-in "ask" method, which is
    # actually more useful
    @shell = Thor::Shell::Color.new

    yield self if block_given?
  end

  # ease setup of a blank/default submitter
  def update
    yield self if block_given?
  end

  def confirm_computer_data
    puts 'Ready to submit the following data:'
    puts '-------------------------------------------------------'
    puts "Computer Name           #{computer_name}"
    puts "User email              #{email}"
    puts 'Password                ***********'
    puts "logs API token          #{logs_token}"
    puts "GitHub Protocol         #{github_protocol}"
    puts "MESA Mirror Location    #{mesa_mirror}"
    puts "MESA Work Location      #{mesa_work}"
    puts "Platform                #{platform} #{platform_version}"
    # puts "Config location         #{config_file}"
    puts '-------------------------------------------------------'
    puts ''
    response = shell.ask 'Is this correct? (y/Y = Yes, anything else = No):'
    response.strip.casecmp('y').zero?
  end

  # For one "computer" on the web server, and for [subjective] consistency
  # reasons, the platform, processor, and RAM cannot be changed! If you
  # change platforms (i.e. switch from mac to linux, or change between linux
  # flavors), you should create a new computer account. Similarly, create new
  # computer accounts if you change your RAM or processor. You do not need
  # to change computers if you upgrade your platform (macOS 10.12 -> 10.13
  def save_computer_data
    data_hash = {
      'computer_name' => computer_name,
      'email' => email,
      'password' => password,
      'logs_token' => logs_token,
      'github_protocol' => github_protocol,
      'mesa_mirror' => mesa_mirror,
      'mesa_work' => mesa_work,
      'platform' => platform,
      'platform_version' => platform_version,
    }
    # make sure there's a directory to write to
    unless dir_or_symlink_exists? File.dirname(config_file)
      FileUtils.mkdir_p File.dirname(config_file)
    end
    File.open(config_file, 'w') { |f| f.write(YAML.dump(data_hash)) }
  end

  def load_computer_data
    data_hash = YAML.safe_load(File.read(config_file), [Symbol])
    @computer_name = data_hash['computer_name']
    @email = data_hash['email']
    @password = data_hash['password']
    @logs_token = data_hash['logs_token']
    @github_protocol = data_hash['github_protocol'].to_sym
    @mesa_mirror = data_hash['mesa_mirror']
    @mesa_work = data_hash['mesa_work']
    @platform = data_hash['platform']
    @platform_version = data_hash['platform_version']
  end

  # Parameters to be submitted in JSON format for reporting information about
  # the submitting user and computer
  def submitter_params
    {
      email: email,
      password: password,
      computer: computer_name,
      platform_version: platform_version
    }
  end

  # Parameters to be submitted in JSON format for reporting information about
  # the overall commit being tested; used even if only submitting an entire
  # test. This also determines if the submission is for an entire commit 
  # (compilation information and every test), an empty commit (just
  # compilation information), or a non-empty, but also non-entire submission
  # (results for a single test without compilation information)
  def commit_params(mesa, entire: true, empty: false)
    # the compiler data should be able to be used as-is, but right now the
    # names don't match with what the database expects, so we do some renaming
    # shenanigans.
    # 
    ####################################
    # THIS SHOULD GO BEFORE PRODUCTION #
    {
      sha: mesa.sha,
      compiled: mesa.installed?,
      entire: entire,
      empty: empty,
    }.merge(mesa.compiler_hash)
  end

  # Given a valid +Mesa+ object, create an array of hashes that describe the
  # test cases and the test results. These will be encoded as an array of
  # JSON objects.
  def instance_params(mesa)
    has_errors = []
    res = []
    mesa.test_case_names.each do |mod, names|
      names.each do |test_name|
        begin
          test_case = mesa.test_cases[mod][test_name]
          res << test_case.results_hash
        rescue TestCaseDirError
          # shell.say "It appears that #{test_case.test_name} has not been "\
          #           'run yet. Unable to submit data for this test.', :red
          has_errors << test_case
        end
      end
    end
    unless has_errors.empty?
      shell.say "The following test cases could NOT be read for submission:",
                :red
      has_errors.each do |test_case|
        shell.say "- #{test_case.test_name}", :red
      end
    end
    res
  end

  # Parameters for reporting a failed compilation to the logs server
  def build_log_params(mesa)
    {
      'computer_name' => computer_name,
      'commit' => mesa.sha,
      'build.log' => mesa.build_log_64
    }
  end

  # Parameters for reporting a failed test to the logs server
  def test_log_params(test_case)
    res = {
      'computer_name' => computer_name,
      'commit' => test_case.mesa.sha, 
      'test_case' => test_case.test_name     
    }
    res['mk.txt'] = test_case.mk_64 unless test_case.mk_64.empty?
    res['out.txt'] = test_case.out_64 unless test_case.out_64.empty?
    res['err.txt'] = test_case.err_64 unless test_case.err_64.empty?
    res
  end

  # Parameters for a single test case. +mesa+ is an instance of +Mesa+, and
  # +test_case+ is an instance of MesaTestCase representing the test case to
  # be submitted
  def single_instance_params(test_case)
    [test_case.results_hash]
  end

  # Phone home to testhub and confirm that computer and user are valid. Useful
  # for confirming that submissions will be accepted before wasting time on a
  # test later.
  def confirm_computer
    uri = URI.parse(base_uri + '/check_computer.json')
    https = Net::HTTP.new(uri.hostname, uri.port)
    https.use_ssl = base_uri.include? 'https'

    request = Net::HTTP::Post.new(
      uri, initheader = { 'Accept' => 'application/json', 'Content-Type' => 'application/json' }
    )
    request.body = {
      email: email,
      password: password,
      computer_name: computer_name
    }.to_json
    JSON.parse(https.request(request).body).to_hash
  end

  # submit entire commit's worth of test cases, OR submit compilation status
  # and NO test cases
  def submit_commit(mesa, empty: false)
    unless mesa.install_attempted?
      raise MesaDirError, 'No testhub.yml file found in installation; '\
                          'must attempt to install before subitting.'
    end
    uri = URI.parse(base_uri + '/submissions/create.json')
    https = Net::HTTP.new(uri.hostname, uri.port)
    https.use_ssl = true if base_uri.include? 'https'

    request = Net::HTTP::Post.new(
      uri,
      initheader = { 'Accept' => 'application/json', 'Content-Type' => 'application/json' }
    )

    # create the request body for submission to the submissions API
    # 
    # if we have an empty submission, then it is necessarily not entire.
    # Similarly, a non-empty submission is necessarily entire (otherwise one
    # would use +submit_instance+). Also, make a "nonempty" submission be
    # empty if there was an overall build error
    empty ||= !mesa.installed?
    request_data = {submitter: submitter_params,
                    commit: commit_params(mesa, empty: empty, entire: !empty)}
    # don't need test instances if it's an empty submission or if compilation
    # failed
    if !empty && request_data[:commit][:compiled]
      request_data[:instances] = instance_params(mesa)
    end
    request.body = request_data.to_json

    # actually do the submission
    response = https.request request

    if !response.is_a? Net::HTTPCreated
      shell.say "\nFailed to submit some or all test case instances and/or "\
                'commit data.', :red
      false
    else
      shell.say "\nSuccessfully submitted commit #{mesa.sha}.", :green
      # commit submitted to testhub, now submit build log if compilation failed
      # and exit
      unless mesa.installed?
        return submit_build_log(mesa)
      end

      # compilation succeded, so submit any logs for failing tests
      res = true
      unless empty
        mesa.test_cases.each do |mod, test_case_hash|
          test_case_hash.each do |tc_name, test_case|
            # get at each individual test case, see if it failed, and if it
            # did, submit its log files
            unless test_case.passed?
              res &&= submit_test_log(test_case)
            end
          end
        end
      end

      # a true return value means that any and all log submission were
      # successful
      res
    end
  end

  # submit results for a single test case instance. Does *not* report overall
  # compilation status to testhub. Use an empty commit submission for that
  def submit_instance(mesa, test_case)
    unless mesa.install_attempted?
      raise MesaDirError, 'No testhub.yml file found in installation; '\
                          'must attempt to install before subitting.'
    end

    uri = URI.parse(base_uri + '/submissions/create.json')
    https = Net::HTTP.new(uri.hostname, uri.port)
    https.use_ssl = true if base_uri.include? 'https'

    request = Net::HTTP::Post.new(
      uri,
      initheader = { 'Accept' => 'application/json', 'Content-Type' => 'application/json' }
    )

    # create the request body for submission to the submissions API
    # 
    # submission is not empty (there is one test case), and it is also not
    # entire (... there is only test case)
    request_data = {submitter: submitter_params,
                    commit: commit_params(mesa, empty: false, entire: false),
                    instances: single_instance_params(test_case)}
    request.body = request_data.to_json

    # actually do the submission
    response = https.request request

    if !response.is_a? Net::HTTPCreated
      shell.say "\nFailed to submit #{test_case.test_name} for commit "\
                "#{mesa.sha}", :red
      false
    else
      shell.say "\nSuccessfully submitted instance of #{test_case.test_name} "\
                "for commit #{mesa.sha}.", :green
      # submit logs if test failed
      return submit_test_log(test_case) unless test_case.passed?
      true
    end
  end

  # make generic request to LOGS server
  # +params+ is a hash of data to be encoded as JSON and sent off
  def submit_logs(params)
    uri = URI('https://logs.mesastar.org/uploads')
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    req = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json',
                              'X-Api-Key' => logs_token)
    req.body = params.to_json
    https.request(req)
  end

  # send build log to the logs server
  def submit_build_log(mesa)
    # intercept and don't send if mesa was properly installed
    return true if mesa.installed?

    # don't even try unless we have a logs token set
    unless logs_token
      shell.say 'Cannot submit to logs server; need to set mesa_logs_token '\
                'in the mesa_test config file.'
      return false
    end

    # do submission
    res = submit_logs(build_log_params(mesa))

    # report out results
    if !res.is_a? Net::HTTPOK
      shell.say "\nFailed to submit build.log to the LOGS server for commit "\
                "#{mesa.sha}.", :red
      false
    else
      shell.say "\nSuccessfully submitted build.log to the LOGS server for "\
                "#{mesa.sha}.", :green
      true
    end
  end

  # send build log to the logs server
  def submit_test_log(test_case)
    # skip submission if mesa was never installed or if the test passed
    return true if !test_case.mesa.installed? || test_case.passed?

    # don't even try unless we have a logs token set
    unless logs_token
      shell.say 'Cannot submit to logs server; need to set mesa_logs_token '\
                'in the mesa_test config file..'
      return false
    end
  
    # do submission
    res = submit_logs(test_log_params(test_case))

    # report out results
    if !res.is_a? Net::HTTPOK
      shell.say "Failed to submit logs for test case #{test_case.test_name} "\
                "in commit #{test_case.mesa.sha}.", :red
      false
    else
      shell.say "Successfully submitted logs for test case "\
                "#{test_case.test_name} in commit #{test_case.mesa.sha}.",
                :green
      true
    end
  end

end

class Mesa
  attr_reader :mesa_dir, :mirror_dir, :names_to_numbers, :shell,
              :test_case_names, :test_cases, :github_protocol

  def self.checkout(sha: nil, work_dir: nil, mirror_dir: nil,
                    github_protocol: :ssh)
    m = Mesa.new(mesa_dir: work_dir, mirror_dir: mirror_dir,
                 github_protocol: github_protocol)   
    m.checkout(new_sha: sha)
    m
  end

  def initialize(mesa_dir: ENV['MESA_DIR'], mirror_dir: nil,
                 github_protocol: :ssh)
    # absolute_path ensures that it doesn't matter where commands are executed
    # from
    @mesa_dir = File.absolute_path(mesa_dir)
    @mirror_dir = File.absolute_path(mirror_dir)

    # don't worry about validity of github protocol until it is needed in a
    # checkout. This way you can have garbage in there if you never really need
    # it.
    @github_protocol = if github_protocol.respond_to? :to_sym
                         github_protocol.to_sym
                       else
                         github_protocol
                       end

    # these get populated by calling #load_test_data
    @test_cases = {}
    @test_case_names = {}
    @names_to_numbers = {}

    # way to output colored text
    @shell = Thor::Shell::Color.new
  end

  def checkout(new_sha: 'HEAD')
    # before anything confirm that git-lfs has been installed
    shell.say "\nEnsuring that git-lfs is installed... ", :blue
    command = 'git lfs help >> /dev/null 2>&1'
    if bash_execute(command)
      shell.say "yes", :green
    else
      shell.say "no", :red
      raise(GitHubError, "The command #{command} returned with an error "\
                         'status, indicating that git-lfs is not installed. '\
                         'Make sure it is installed and try again.')
    end

    # set up mirror if it doesn't exist
    unless dir_or_symlink_exists?(mirror_dir)
      shell.say "\nCreating initial mirror at #{mirror_dir}. "\
                'This might take awhile...', :blue
      FileUtils.mkdir_p mirror_dir
      case github_protocol
      when :ssh
        command = "git clone --mirror #{GITHUB_SSH} #{mirror_dir}"
        shell.say command
        # fail loudly if this doesn't work
        unless bash_execute(command)
          # nuke the mirror directory since it is probably bogus (make this
          # code fire off the next time checkout is done)
          shell.say "Failed. Removing the [potentially corrupted] mirror.", :red
          command = "rm -rf #{mirror_dir}"
          shell.say command
          bash_execute(command)

          raise(GitHubError, 'Error while executing the following command:'\
                             "#{command}. Perhaps you haven't set up "\
                             'ssh keys with your GitHub account?')
        end
      when :https
        command = "git clone --mirror #{GITHUB_HTTPS} #{mirror_dir}"
        shell.say command
        # fail loudly if this doesn't work
        unless bash_execute(command)
          # nuke the mirror directory since it is probably bogus (make this
          # code fire off the next time checkout is done)
          shell.say "Failed. Removing the [potentially corrupted] mirror.", :red
          command = "rm -rf #{mirror_dir}"
          shell.say command
          bash_execute(command)

          raise(GitHubError, 'Error while executing the following command: '\
                             "#{command}. Perhaps you need to configure "\
                             'global GitHub account settings for https '\
                             'authentication to work properly?')
        end
      else
        raise(GitHubError, "Invalid GitHub protocol: \"#{github_protocol}\"")
      end
    end

    update_mirror

    # ensure "work" directory is removed from worktree
    remove

    # create "work" directory with proper commit
    shell.say "\nSetting up worktree repo...", :blue
    FileUtils.mkdir_p mesa_dir
    command = "git -C #{mirror_dir} worktree add #{mesa_dir} #{new_sha}"
    shell.say command
    return if bash_execute(command)

    raise(GitHubError, 'Failed while executing the following command: '\
                       "\"#{command}\".")
  end

  def update_mirror
    shell.say "\nFetching MESA history...", :blue
    command = "git -C #{mirror_dir} fetch origin"
    shell.say command
    # fail loudly
    return if bash_execute(command)

    raise(GitHubError, 'Failed while executing the following command: '\
                       "\"#{command}\".")
  end

  def remove
    return unless File.exist? mesa_dir
    shell.say "\nRemoving work directory from worktree (clearing old data)...",
              :blue
    command = "git -C #{mirror_dir} worktree remove --force #{mesa_dir}"
    shell.say command
    return if bash_execute(command)

    shell.say "Failed. Simply trying to remove the directory.", :red
    command = "rm -rf #{mesa_dir}"
    shell.say command
    # fail loudly (the "true" tells bash_execute to raise an exception if
    # the command fails)
    bash_execute(command, true)
  end

  def git_sha
    bashticks("git -C #{mesa_dir} rev-parse HEAD")
  end

  def sha
    git_sha
  end

  def clean
    with_mesa_dir do
      visit_and_check mesa_dir, MesaDirError, 'E\countered a problem in ' \
                                "running `clean` in #{mesa_dir}." do
        shell.say('MESA_DIR = ' + ENV['MESA_DIR'])
        shell.say './clean'
        bash_execute('./clean')
      end
    end
    self
  end

  def install
    with_mesa_dir do
      visit_and_check mesa_dir, MesaDirError, 'Encountered a problem in ' \
                                "running `install` in #{mesa_dir}." do
        shell.say('MESA_DIR = ' + ENV['MESA_DIR'])
        shell.say './install'
        bash_execute('./install')
      end
    end
    # this should never happen if visit_and_check works properly.
    check_installation
    self
  end

  # throw an error unless it seems like it's properly compiled
  def check_installation
    return if installed?

    raise MesaDirError, 'Installation check failed (build.log doesn\'t '\
                        'show a successful installation).'
  end

  # base 64-encoded contents of build.log
  def build_log_64
    build_log = File.join(mesa_dir, 'build.log')
    return '' unless File.exist?(build_log)

    b64_file(build_log)
  end

  # sourced from $MESA_DIR/testhub.yml, which should be created after
  # installation
  def compiler_hash
    data_file = File.join(mesa_dir, 'testhub.yml')
    res = {
            compiler: 'Unknown',
            sdk_version: 'Unknown',
            math_backend: 'Unknown'
          }
    if File.exist? data_file
      res = res.merge(YAML.safe_load(File.read(data_file)) || {})
      # currently version_number is reported, but we don't need that in Git land
      res.delete('version_number') # returns the value, not the updated hash
      res
    end
  end

  ## TEST SUITE METHODS

  def check_mod(mod)
    return if MesaTestCase.modules.include? mod

    raise TestCaseDirError, "Invalid module: #{mod}. Must be one of: " +
                            MesaTestCase.modules.join(', ')
  end

  def test_suite_dir(mod: nil)
    check_mod mod
    File.join(mesa_dir, mod.to_s, 'test_suite')
  end

  # load data from the `do1_test_source` file that gets used in a lot of
  # testing
  def load_test_source_data(mod: :all)
    # allow for brainless loading of all module data
    if mod == :all
      MesaTestCase.modules.each do |this_mod|
        load_test_source_data(mod: this_mod)
      end
    else
      check_mod mod

      # convert output of +list_tests+ to a dictionary that maps
      # names to numbers since +each_test_run+ only knows about numbers
      @names_to_numbers[mod] = {}
      @test_case_names[mod] = []
      @test_cases[mod] = {}
      visit_dir(test_suite_dir(mod: mod), quiet: true) do
        bashticks('./list_tests').split("\n").each do |line|
          num, tc_name = line.strip.split
          @names_to_numbers[mod][tc_name.strip] = num.to_i
          @test_case_names[mod] << tc_name.strip
          begin
            @test_cases[mod][tc_name.strip] = MesaTestCase.new(
              test: tc_name.strip,
              mod: mod,
              position: num.to_i,
              mesa: self
            )
          rescue TestCaseDirError
            shell.say "No such test case #{tc_name.strip}. Skipping loading it.", :red
          end
        end
      end
    end
  end

  def test_case_count(mod: :all)
    all_names_ordered(mod: mod).count
  end

  # can accept a number (in string form) as a name for indexed access
  def find_test_case(test_case_name: nil, mod: :all)
    if /\A[0-9]+\z/ =~ test_case_name
      find_test_case_by_number(test_number: test_case_name.to_i, mod: mod)
    else
      find_test_case_by_name(test_case_name: test_case_name, mod: mod)
    end
  end

  def each_test_run(mod: :all)
    check_installation

    if mod == :all
      MesaTestCase.modules.each do |this_mod|
        each_test_run(mod: this_mod)
      end
    else
      visit_dir(test_suite_dir(mod: mod)) do
        bash_execute('./each_test_run')
      end
    end
  end

  def downloaded?
    check_mesa_dir
  end

  def installed?
    # assume build log reflects installation status; does not account for
    # mucking with modules after the fact
    build_log = File.join(mesa_dir, 'build.log')
    downloaded? && File.exist?(build_log) && File.read(build_log).include?(
      'MESA installation was successful'
    )
  end

  def install_attempted?
    File.exist? File.join(mesa_dir, 'testhub.yml')
  end

  private

  # verify that mesa_dir is valid by checking for existence of test_suite
  # directory for each module (somewhat arbitrary)
  def check_mesa_dir
    MesaTestCase.modules.inject(true) do |res, mod|
      res && dir_or_symlink_exists?(test_suite_dir(mod: mod))
    end
  end

  # change MESA_DIR for the execution of the block and then revert to the
  # original value
  def with_mesa_dir
    # change MESA_DIR, holding on to old value
    orig_mesa_dir = ENV['MESA_DIR']
    ENV['MESA_DIR'] = mesa_dir
    shell.say "Temporarily changed MESA_DIR to #{ENV['MESA_DIR']}.", :blue

    # do the stuff
    begin
      yield
    # make sure we undo MESA_DIR change
    ensure
      ENV['MESA_DIR'] = orig_mesa_dir
      shell.say "Changed MESA_DIR back to #{ENV['MESA_DIR']}.", :blue
    end
  end

  def all_names_ordered(mod: :all)
    load_test_source_data unless @names_to_numbers
    if mod == :all
      # build up list by first constructing each modules list and then
      # concatenating them
      MesaTestCase.modules.inject([]) do |res, this_mod|
        res += all_names_ordered(mod: this_mod)
      end
    else
      check_mod mod
      res = Array.new(@names_to_numbers[mod].length, '')

      # values of the hash give their order, keys are the names, so
      # we assign keys to positions in the array according to their value
      @names_to_numbers[mod].each_pair do |key, val|
        res[val - 1] = key # +list_tests+ gives 1-indexed positions
      end
      res
    end
  end

  def find_test_case_by_name(test_case_name: nil, mod: :all)
    load_test_source_data unless @names_to_numbers
    if mod == :all
      # look through all loaded modules for desired test case name, only 
      # return a test case if a single case is found with that name
      case all_names_ordered.count(test_case_name)
      when 1
        # it exists in exactly one module, but we need to find the module
        # and then return the +MesaTestCase+ object
        MesaTestCase.modules.each do |this_mod|
          if @test_case_names[this_mod].include? test_case_name
            # found it, return the appropriate object
            return @test_cases[this_mod][test_case_name]
          end
        end
        raise 'Weird problem: found test case in overall names, but '\
          "not in any particular module. This shouldn't happen."
      when 0
        raise(TestCaseDirError, "Could not find test case #{test_case_name} "\
                                'in any module.')
      else
        raise(TestCaseDirError, 'Found multiple test cases named '\
          "#{test_case_name} in multiple modules. Indicate the module you "\
          'want to search.')
      end
      # append this array to the end of the exisitng one
    else
      # module specified; check it and return the proper test case (may be nil
      # if the test case doesn't exist)
      check_mod mod
      if @test_case_names[mod].include? test_case_name
        # happy path: test case exists in the specified module
        return @test_cases[mod][test_case_name]
      else
        raise TestCaseDirError.new('Could not find test case ' \
          "#{test_case_name} in the #{mod} module.")
      end
    end
  end

  def find_test_case_by_number(test_number: nil, mod: :all)
    # this will be the index in the name array of the proper module of
    # the desired test case
    # input numbers are 1-indexed, but we'll fix that later
    if test_number < 1 || test_number > test_case_count(mod: mod)
      raise TestCaseDirError.new('Invalid test case number for searching '\
        "in module #{mod}. Must be between 1 and #{test_case_count(mod: mod)}.")
    end

    if mod == :all
      # can get the name easily, now need to find the module
      test_case_name = all_names_ordered[test_number - 1]
      MesaTestCase.modules.each do |mod|
        if test_number <= test_case_count(mod: mod)
          # test must live in this module; we have everything
          return MesaTestCase.new(
            test: test_case_name,
            mod: mod,
            mesa: self,
            position: @names_to_numbers[mod][test_case_name]
          )
        else
          # number was too big, so decrement by this modules case count
          # and move on to next one
          test_number -= test_case_count(mod: mod)
        end
      end
      # should return before we get here, but fail hard if we do
      raise TestCaseDirError.new('Unknown problem in loading test case #' +
        test_number + '.') 
    else
      # module was specified, so we can get at everything right away
      check_mod mod
      return MesaTestCase.new(
        test: all_names_ordered(mod: mod)[test_number - 1],
        mod: mod,
        mesa: self,
        position: test_number
      )
    end
  end
end

class MesaTestCase
  attr_reader :test_name, :mesa, :mod, :position, :shell

  def self.modules
    %i[star binary astero]
  end

  def initialize(test: nil, mesa: nil, mod: nil, position: nil)
    @test_name = test
    @mesa = mesa
    unless MesaTestCase.modules.include? mod
      raise TestCaseDirError, "Invalid module: #{mod}. Must be one of: " +
                              MesaTestCase.modules.join(', ')
    end
    @mod = mod
    @position = position

    # way to output colored text to shell
    @shell = Thor::Shell::Color.new

    # validate stuff
    check_mesa_dir
    check_test_case

  end

  def test_suite_dir
    mesa.test_suite_dir(mod: @mod)
  end

  def test_case_dir
    File.join(test_suite_dir, test_name)
  end

  # just punt to +each_test_run+ in the test_suite directory. It's your problem
  # now, sucker!
  def do_one
    shell.say("Testing #{test_name}", :yellow)
    visit_dir(test_suite_dir) do
      bash_execute("./each_test_run #{position}")
    end
  end

  def results_hash
    testhub_file = File.join(test_case_dir, 'testhub.yml')
    unless File.exist?(testhub_file)
      raise TestCaseDirError.new('No results found for test case '\
                                 "#{test_name}.")
    end
    YAML.safe_load(File.read(testhub_file), [Symbol])
  end

  # whether or not a test case has passed; only has meaning
  # if we can load the results hash, though
  def passed?
    results_hash['outcome'] == :pass
  end

  # Base-64 encoded contents of mk.txt file
  def mk_64
    mk_file = File.join(test_case_dir, 'mk.txt')
    return '' unless File.exist?(mk_file)

    b64_file(mk_file)
  end

  # Base-64 encoded contents of err.txt file
  def err_64
    err_file = File.join(test_case_dir, 'err.txt')
    return '' unless File.exist?(err_file)

    b64_file(err_file)
  end

  # Base-64 encoded contents of out.txt file
  def out_64
    out_file = File.join(test_case_dir, 'out.txt')
    return '' unless File.exist?(out_file)

    b64_file(out_file)
  end

  private

  # cd into the test case directory, do something in a block, then cd back
  # to original directory
  def in_dir(&block)
    visit_dir(test_case_dir, &block)
  end

  # make sure that we can get to the test case directory. Throw an exception
  # if we cannot
  def check_test_case
    return if dir_or_symlink_exists? test_case_dir
    raise TestCaseDirError, "No such test case: #{test_case_dir}."
  end

  # "verify" that mesa_dir is valid by checking for test_suite directory
  def check_mesa_dir
    is_valid =  dir_or_symlink_exists? test_suite_dir
    raise MesaDirError, "Invalid MESA dir: #{mesa.mesa_dir}" unless is_valid
  end

end

################################
#       GENERAL METHODS        #
################################

# cd into a new directory, execute a block whose return value is either
# true or false. Either way, cd back to original directory. Raise an
# exception if the block failed (returned false or nil)
def visit_and_check(new_dir, exception, message)
  cwd = Dir.getwd
  shell.say "Leaving  #{cwd}", :blue
  shell.say "\nEntering #{new_dir}.", :blue
  Dir.chdir(new_dir)
  success = yield if block_given?
  shell.say "Leaving  #{new_dir}", :blue
  shell.say "\nEntering #{cwd}.", :blue
  Dir.chdir(cwd)
  return if success
  raise exception, message
end

# cd into a new directory, execute a block, then cd back into original
# directory
def visit_dir(new_dir, quiet: false)
  cwd = Dir.getwd
  shell.say "Leaving  #{cwd}\n", :blue unless quiet
  shell.say "\nEntering #{new_dir}.", :blue unless quiet
  Dir.chdir(new_dir)
  yield if block_given?
  shell.say "Leaving  #{new_dir}\n", :blue unless quiet
  shell.say "\nRe-entering #{cwd}.", :blue unless quiet
  Dir.chdir(cwd)
end

# the next function probalby doesn't belong here, but keep it anyway, please
# create seed data for test cases for MesaTestHub of a given mesa version
def generate_seeds_rb(mesa_dir, outfile)
  m = Mesa.new(mesa_dir: mesa_dir)
  m.load_test_source_data
  File.open(outfile, 'w') do |f|
    f.puts 'test_cases = TestCase.create!('
    f.puts '  ['
    m.test_names.each do |test_case_name|
      f.puts '    {'
      f.puts "      name: '#{test_case_name}',"
      # no comma on last one
      if test_case_name == m.test_names[-1]
        f.puts('    }')
      else
        f.puts('    },')
      end
    end
    f.puts '  ]'
    f.puts ')'
  end
end

def dir_or_symlink_exists?(path)
   File.directory?(path) || File.symlink?(path)
end

# force the execution to happen with bash
def bash_execute(command, throw_exception=false)
  res = system('bash -c "' + command + '"')
  if !res && throw_exception
    raise BashError('Encountered an error when executing the following '\
      "command in bash: #{command}.")
  end
  res
end

# force execution to happen with bash, but return result rather than exit
# status (like backticks)
def bashticks(command)
  `bash -c "#{command}"`.chomp
end

# encode the contents of a file as base-64
def b64_file(filename)
  Base64.encode64(File.open(filename).read)
end
