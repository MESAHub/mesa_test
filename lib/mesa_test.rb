require 'fileutils'
require 'socket'
require 'os'
require 'yaml'
require 'uri'
require 'net/http'
require 'net/https'
require 'thor'
require 'json'

MesaDirError = Class.new(StandardError)
TestCaseDirError = Class.new(StandardError)
InvalidDataType = Class.new(StandardError)

DEFAULT_REVISION = 10_000

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

      # Get compiler information
      response = shell.ask "Which compiler are you using? (#{s.compiler}):",
                           :blue, limited_to: ['', 'SDK', 'gfortran', 'ifort']
      s.compiler = response unless response.empty?

      # Get compiler version
      response = shell.ask 'What version of the compiler (eg. '\
        "x86_64-macos-20.3.1 or 7.2.0)? (#{s.compiler_version}):", :blue
      s.compiler_version = response unless response.empty?

      # Confirm save location
      response = shell.ask "This will be saved in #{s.config_file}. Press " \
        'enter to accept or enter a new location:', :blue, path: true
      s.config_file = response unless response.empty?
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
                :compiler, :compiler_version, :config_file, :base_uri,
                :last_tested

  attr_reader :shell

  # many defaults are set in body
  def initialize(
      computer_name: nil, user_name: nil, email: nil, mesa_mirror: nil,
      platform: nil, platform_version: nil, processor: nil, compiler: nil,
      compiler_version: nil, config_file: nil, base_uri: nil, last_tested: nil
  )
    @computer_name = computer_name || Socket.gethostname.scan(/^[^\.]+\.?/)[0]
    @computer_name.chomp!('.') if @computer_name
    @user_name = user_name || (ENV['USER'] || ENV['USERNAME'])
    @email = email || ''
    @password = password || ''
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
    @compiler = compiler || 'SDK'
    @compiler_version = compiler_version || ''
    @config_file = config_file || File.join(ENV['HOME'], '.mesa_test',
                                            'config.yml')
    @base_uri = base_uri
    @last_tested = last_tested || DEFAULT_REVISION

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
    puts "MESA Mirror Location    #{mesa_mirror}"
    puts "MESA Work Location      #{mesa_work}"
    puts "Platform                #{platform} #{platform_version}"
    puts "Compiler                #{compiler} #{compiler_version}"
    puts "Config location         #{config_file}"
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
  # to change computers if you upgrade your platform (macOS 10.12 -> 10.13) or
  # if you try different compilers
  #
  # Note this is NOT checked! The server really only uses the test-by-test
  # quantities (platform version, compiler, compiler version) and the
  # computer name. Once the computer is found (by the name) all the other
  # data is assumed to be fixed. The others... probably shouldn't be here,
  # but remain so you can confirm that the computer on the web server is the
  # same one you think you are working with locally.
  def save_computer_data
    data_hash = {
      'computer_name' => computer_name,
      'email' => email,
      'password' => password,
      'mesa_mirror' => mesa_mirror,
      'mesa_work' => mesa_work,
      'platform' => platform,
      'platform_version' => platform_version,
      'compiler' => compiler,
      'compiler_version' => compiler_version
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
    @mesa_mirror = data_hash['mesa_mirror']
    @mesa_work = data_hash['mesa_work']
    @platform = data_hash['platform']
    @platform_version = data_hash['platform_version']
    @compiler = data_hash['compiler']
    @compiler_version = data_hash['compiler_version']
  end

  # Parameters to be submitted in JSON format for reporting information about
  # the submitting user and computer
  def submitter_params
    {email: email, password: password, computer: computer_name}
  end

  # Parameters to be submitted in JSON format for reporting information about
  # the overall commit being tested; used even if only submitting an entire
  # test. This also determines if the submission is for an entire commit 
  # (compilation information and every test), an empty commit (just
  # compilation information), or a non-empty, but also non-entire submission
  # (results for a single test without compilation information)
  def commit_params(mesa, entire: true, empty: false)
    {
      sha: mesa.sha,
      compiled: mesa.installed?,
      entire: entire,
      empty: empty,
      test_case_names: (entire || empty) ? mesa.test_case_names : ''
    }
  end

  # Given a valid +Mesa+ object, create an array of hashes that describe the
  # test cases and the test results. These will be encoded as an array of
  # JSON objects.
  def instance_params(mesa)
    has_errors = []
    res = []
    mesa.test_names.each do |mod, names|
      names.each do |test_name|
        begin
          test_case = mesa.test_cases[mod][test_name]
          res << {
            test_case: test_name,
            mod: mod,
            runtime_seconds: test_case.runtime_seconds,
            re_time: test_case.re_time,
            total_runtime_seconds: test_case.total_runtime_seconds,
            passed: test_case.passed?,
            compiler: test_case.compiler || compiler,
            compiler_version: test_case.compiler_version || compiler_version,
            platform_version: platform_version,
            omp_num_threads: test_case.test_omp_num_threads,
            success_type: test_case.success_type,
            failure_type: test_case.failure_type,
            steps: test_case.steps,
            retries: test_case.retries,
            checksum: test_case.checksum,
            rn_mem: test_case.rn_mem,
            re_mem: test_case.re_mem,
            summary_text: test_case.summary_text
          }
        rescue TestCaseDirError
          shell.say "Passage status for #{test_case.test_name} not yet "\
                    'known. Run test first and then submit.', :red
          has_errors << test_case
        end
      end
    end
    unless has_errors.empty?
      shell.say "The following test cases could NOT be read for submission:",
                :red
      has_errors.each do |test_case|
        shell.say "#{test_case.test_name}"
      end
    end
    res
  end

  # Parameters for a single test case. +mesa+ is an instance of +Mesa+, and
  # +test_case_name+ is a string that is a valid test case name OR a number
  # indicating its position in the list of test cases
  def single_instance_params(test_case)
    [{
      test_case: test_case.test_name,
      mod: test_case.mod,
      runtime_seconds: test_case.runtime_seconds,
      re_time: test_case.re_time,
      total_runtime_seconds: test_case.total_runtime_seconds,
      passed: test_case.passed?,
      compiler: test_case.compiler || compiler,
      compiler_version: test_case.compiler_version || compiler_version,
      platform_version: platform_version,
      omp_num_threads: test_case.test_omp_num_threads,
      success_type: test_case.success_type,
      failure_type: test_case.failure_type,
      steps: test_case.steps,
      retries: test_case.retries,
      checksum: test_case.checksum,
      rn_mem: test_case.rn_mem,
      re_mem: test_case.re_mem,
      summary_text: test_case.summary_text
    }]
  end

  # Phone home to testhub and confirm that computer and user are valid. Useful
  # for confirming that submissions will be accepted before wasting time on a
  # test later.
  def confirm_computer
    uri = URI.parse(base_uri + '/check_computer.json')
    https = Net::HTTP.new(uri.hostname, uri.port)
    https.use_ssl = base_uri.include? 'https'

    request = Net::HTTP::Post.new(
      uri, initheader = { 'Content-Type' => 'application/json' }
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
    uri = URI.parse(base_uri + '/submissions/create.json')
    https = Net::HTTP.new(uri.hostname, uri.port)
    https.use_ssl = true if base_uri.include? 'https'

    request = Net::HTTP::Post.new(
      uri,
      initheader = { 'Content-Type' => 'application/json' }
    )

    # create the request body for submission to the submissions API
    # 
    # if we have an empty submission, then it is necessarily not entire.
    # Similarly, a non-empty submission is necessarily entire (otherwise one
    # would use +submit_instance+)
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
      true
    end
  end

  # submit results for a single test case instance. Does *not* report overall
  # compilation status to testhub. Use an empty commit submission for that
  def submit_instance(mesa, test_case)
    uri = URI.parse(base_uri + '/submissions/create.json')
    https = Net::HTTP.new(uri.hostname, uri.port)
    https.use_ssl = true if base_uri.include? 'https'

    request = Net::HTTP::Post.new(
      uri,
      initheader = { 'Content-Type' => 'application/json' }
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
      true
    end
  end
end

class Mesa
  attr_reader :mesa_dir, :mirror_dir, :names_to_numbers, :shell, :using_sdk

  def self.checkout(sha: nil, work_dir: nil, mirror_dir: nil, using_sdk: true)
    m = Mesa.new(mesa_dir: work_dir, mirror_dir: mirror_dir,
                 using_sdk: using_sdk)
    m.checkout(sha: sha)
    m
  end

  def initialize(mesa_dir: ENV['MESA_DIR'], mirror_dir: nil, using_sdk: true)
    # absolute_path ensures that it doesn't matter where commands are executed
    # from
    @mesa_dir = File.absolute_path(mesa_dir)
    @mirror_dir = File.absolute_path(mirror_dir)
    @using_sdk = using_sdk

    # this get populated by calling #load_test_data
    @names_to_numbers = nil

    # way to output colored text
    @shell = Thor::Shell::Color.new
  end

  def checkout(sha: 'HEAD')
    # set up mirror if it doesn't exist
    unless dir_or_symlink_exists?(mirror_dir)
      shell.say "\nCreating initial mirror at #{mirror_dir}. "\
                'This might take awhile...', :blue
      FileUtils.mkdir_p mirror_dir
      command = 'git clone --mirror https://github.com/MESAHub/mesa-sandbox'\
                "-lfs.git #{mirror_dir}"
      shell.say command
      bash_execute(command)
    end

    update_mirror

    # ensure "work" directory is removed from worktree
    remove

    # create "work" directory with proper commit
    shell.say "\nSetting up worktree repo...", :blue
    FileUtils.mkdir_p mesa_dir
    command = "git -C #{mirror_dir} worktree add #{mesa_dir} #{sha}"
    shell.say command
    bash_execute(command)
  end

  def update_mirror
    shell.say "\nFetching MESA history...", :blue
    command = "git -C #{mirror_dir} fetch origin"
    shell.say command
    bash_execute(command)
  end

  def remove
    return unless File.exist? mesa_dir
    shell.say "\nRemoving work directory from worktree (clearing old data)...",
              :blue
    command = "git -C #{mirror_dir} worktree remove --force #{mesa_dir}"
    shell.say command
    unless bash_execute(command)
      shell.say "Failed. Simply trying to remove the directory.", :red
      command = "rm -rf #{mesa_dir}"
      shell.say command
      bash_execute(command)
    end
  end

  def sha
    bashticks("git -C #{mesa_dir} rev-parse HEAD")
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
    unless installed?
      raise MesaDirError, 'Installation check failed (build.log doesn\'t '\
                          'show a successful installation).'
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
      @names_to_numbers ||= {}
      @names_to_numbers[mod] = {}
      visit_dir(test_suite_dir(mod: mod)) do
        bashticks('./list_tests').split("\n").each do |line|
          num, tc_name = line.strip.split
          @names_to_numbers[tc_name] = num.to_i
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
      visit_dir(test_suite_dir(mod)) do
        bash_execute("./each_test_run")
      end
    end
  end

  # def each_test_load_results(mod: :all)
  #   if mod == :all
  #     MesaTestCase.modules.each do |this_mod|
  #       each_test_load_results(mod: this_mod)
  #     end
  #   else
  #     test_names[mod].each do |test_name|
  #       test_cases[mod][test_name].load_results
  #     end
  #   end
  # end

  def downloaded?
    check_mesa_dir
  end

  def installed?
    # assume build log reflects installation status; does not account for
    # mucking with modules after the fact
    downloaded? && File.read(File.join(mesa_dir, 'build.log')).include?(
      'MESA installation was successful')
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
      res = MesaTestCase.inject([]) do |res, mod|
        res += all_names_ordered(mod: mod)
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
      # look through all loaded modules for desired test case name, return
      # FIRST found (assuming no name duplication across modules)
      case all_names_ordered.count(test_case_name)
      when 1
        # it exists in exactly one module, but we need to find the module
        # and then return the +MesaTestCase+ object
        MesaTestCase.modules.each do |mod|
          if @names_to_numbers.keys.include? test_case_name
            # found it, return the appropriate object
            return MesaTestCase.new(
              test: test_case_name,
              mod: mod,
              mesa: self,
              position: @names_to_numbers[mod][test_case_name]
            )
          end
        end
      when 0
        raise TestCaseDirError.new('Could not find test case ' \
          "#{test_case_name} in any module.")
      else
        raise TestCaseDirError.new('Found multiple test cases named '\
          "#{test_case_name} in multiple modules. Indicate the module you "\
          'want to search.')
      end
        # append this array to the end of the exisitng one
    else
      # module specified; check it and return the proper test case (may be nil
      # if the test case doesn't exist)
      check_mod mod
      if @names_to_numbers[mod].keys.include? test_case_name
        # happy path: test case exists in the specified module
        return MesaTestCase.new(
          test: test_case_name,
          mod: mod,
          mesa: self,
          position: @names_to_numbers[mod][test_case_name]
        )
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
  attr_reader :test_name, :mesa, :mod, :position, :mesa_dir, :failure_msg,
              :success_msg, :photo, :runtime_seconds, :test_omp_num_threads,
              :mesa_sha, :shell, :summary_text, :compiler, :compiler_version,
              :checksum, :rn_mem, :re_mem, :re_time, :total_runtime_seconds,
              :steps, :retries
  attr_accessor :data_names, :data_types, :failure_type, :success_type,
                :outcome

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


    @mesa_dir = mesa.mesa_dir
    @mesa_sha = mesa.sha
    @failure_type = nil
    @success_type = nil
    @outcome = :not_tested
    @runtime_seconds = 0
    @test_omp_num_threads = 1
    @total_runtime_seconds = 0
    @steps = 0
    @retries = 0

    # start with nil. Should only be updated to a non-nil value if test is
    # completely successful
    @checksum = nil
    @re_time = nil # rn_time is in the form of @runtime_seconds

    # these only get used with modern versions of both the sdk and the test
    # suite
    @rn_mem = nil
    @re_mem = nil

    # note: this gets overridden for new runs, so this is probably irrelevant
    @summary_text = nil

    # this overrides the submitters choice if it is non-nil
    @compiler = mesa.using_sdk ? 'SDK' : nil
    # only relevant if @compiler is SDK. Gets set during do_one
    @compiler_version = nil

    @failure_msg = {
      run_test_string: "#{test_name} run failed: does not match test string",
      final_model: "#{test_name} run failed: final model #{final_model} not " \
        'made.',
      photo_file: "#{test_name} restart failed: #{photo} does not exist",
      photo_checksum: "#{test_name} restart failed: checksum for " \
        "#{final_model} does not match after ./re",
      photo_diff: "#{test_name} restart failed; checksum for #{final_model} "\
        "does not match after ./re",
      compilation: "#{test_name} compilation failed"
    }
    @success_msg = {
      run_test_string: "#{test_name} run: found test string: " \
        "'#{success_string}'",
      photo_checksum: "#{test_name} restart: checksum for #{final_model} " \
        "matches after ./re #{photo}"
    }

    # validate stuff
    check_mesa_dir
    check_test_case

    @data = {}
    @data_names = []

    # way to output colored text to shell
    @shell = Thor::Shell::Color.new
  end

  def passed?
    case @outcome
    when :pass then true
    when :fail then false
    else
      raise TestCaseDirError, 'Cannot determine pass/fail status of ' \
      "#{test_name} yet."
    end
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

  def load_results
    # loads all parameters from a previous test run, likely for submission
    # purposes
    load_file = File.join(test_case_dir, 'test_results.yml')
    shell.say "Loading data from #{load_file}...", :blue
    unless File.exist? load_file
      shell.say "No such file: #{load_file}. No data loaded.", :red
      return
    end
    data = YAML.safe_load(File.read(load_file), [Symbol])
    @runtime_seconds = data['runtime_seconds'] || @runtime_seconds
    @re_time = data['re_time'] || @re_time
    @total_runtime_seconds = data['total_runtime_seconds'] || @total_runtime_seconds
    @mod = data['module'] || @mod
    @outcome = data['outcome'] || @outcome
    @test_omp_num_threads = data['omp_num_threads'] || @test_omp_num_threads
    @success_type = data['success_type'] || @success_type
    @failure_type = data['failure_type'] || @failure_type
    @checksum = data['checksum'] || @checksum
    @steps = data['steps'] || @steps
    @retries = data['retries'] || @retries
    @rn_mem = data['rn_mem'] || @rn_mem
    @re_mem = data['re_mem'] || @re_mem
    @summary_text = data['summary_text'] || @summary_text
    @compiler = data['compiler'] || @compiler

    @compiler_version = data['compiler_version'] || @compiler_version

    # convert select data to symbols since that is how they are used
    @outcome = @outcome.to_sym if @outcome
    @success_type = @success_type.to_sym if @success_type
    @failure_type = @failure_type.to_sym if @failure_type

    shell.say "Done loading data from #{load_file}.\n", :green
  end

  def load_summary_data
    begin
      @summary_text = get_summary_text
    rescue Errno::ENOENT
      shell.say "\nError loading data from #{out_file}. No summary data "\
                'loaded. Proceeding anyway.', :red
    end
  end

  private

  def data_types
    %i[float integer string boolean]
  end

  def rn_time
    runtime_seconds
  end

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
    raise MesaDirError, "Invalid MESA dir: #{mesa_dir}" unless is_valid
  end

  # append contents of err.txt to end of out.txt, then delete err.txt
  def append_and_rm_err(outfile = 'out.txt', errfile = 'err.txt')
    err_contents = File.read(errfile)
    display_errors(err_contents)
    log_errors(err_contents, outfile)
    FileUtils.rm errfile
  end

  def display_errors(err_contents)
    return if err_contents.strip.empty?
    shell.say("\nERRORS", :red)
    shell.say err_contents
    shell.say('END OF ERRORS', :red)
  end

  def log_errors(err_contents, outfile)
    return if err_contents.strip.empty?
    File.open(outfile, 'a') { |f_out| f_out.write(err_contents) }
    shell.say("appended to #{outfile}\n", :red)
  end

  def simple_clean
    shell.say './clean'
    return if bash_execute('./clean')
    raise TestCaseDirError, 'Encountered an error when running `clean` in ' \
      "#{Dir.getwd} for test case #{test_name}."
  end

  def out_file
    File.join(test_case_dir, 'out.txt')
  end

  def get_summary_text
    IO.readlines(out_file).select do |line|
      line =~ /^\s*runtime/ 
    end.join
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
def visit_dir(new_dir)
  cwd = Dir.getwd
  shell.say "Leaving  #{cwd}\n", :blue
  shell.say "\nEntering #{new_dir}.", :blue
  Dir.chdir(new_dir)
  yield if block_given?
  shell.say "Leaving  #{new_dir}\n", :blue
  shell.say "\nRe-entering #{cwd}.", :blue
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
def bash_execute(command)
  system('bash -c "' + command + '"')
end

# force execution to happen with bash, but return result rather than exit
# status (like backticks)
def bashticks(command)
  `bash -c "#{command}"`.chomp
end
