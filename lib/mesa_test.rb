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

Commit = Struct.new(:revision, :author, :datetime, :message)
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
are all required. All other data are useful, but optional. Any data
transferred to MESATestHub will be encrypted via HTTPS, but be warned that your
e-mail and password will be stored in plain text.'
      # Get computer name
      response = shell.ask('What is the name of this computer (required)? ' \
        "(#{s.computer_name}):", :blue)
      s.computer_name = response unless response.empty?

      # Get user name
      response = shell.ask 'What is the name of the operator of this ' \
        "computer? (#{s.user_name}):", :blue
      s.user_name = response unless response.empty?

      # Get user e-mail
      response = shell.ask 'What is the email you can be reached ' \
        "at (required)? (#{s.email}):", :blue
      s.email = response unless response.empty?

      # Get user password
      response = shell.ask 'What is the password associated with the email ' \
        "#{s.email} (required)? (#{s.password})", :blue
      s.password = response unless response.empty?

      # Get platform information
      response = shell.ask 'What is the platform of this computer (eg. ' \
        "macOS, Ubuntu)? (#{s.platform}):", :blue
      s.platform = response unless response.empty?
      response = shell.ask 'What is the version of the platform (eg. 10.13, ' \
        "16.04)? (#{s.platform_version}):", :blue
      s.platform_version = response unless response.empty?

      # Get processor information
      response = shell.ask 'What type of processor does this computer have ' \
        "(eg. 3.1 GHz Intel i7)? (#{s.processor}):", :blue
      s.processor = response unless response.empty?

      # Get ram information
      response = shell.ask 'How much RAM (in integer GB) does this computer ' \
        "have (eg. 8)? (#{s.ram_gb}) ", :blue
      s.ram_gb = response.to_i unless response.empty?

      # Get compiler information
      response = shell.ask "Which compiler are you using? (#{s.compiler}):",
                           :blue, limited_to: ['', 'SDK', 'gfortran', 'ifort']
      s.compiler = response unless response.empty?

      # Get compiler version
      response = shell.ask 'What version of the compiler (eg. 20170921 or ' \
        "7.2.0)? (#{s.compiler_version}): ", :blue
      s.compiler_version = response unless response.empty?

      # Get earliest revision to check
      response = shell.ask "What's the earliest revision to search back to " \
        'when finding the latest testable revision (eg. 10000)? ' \
        "(#{s.last_tested}): ", :blue
      s.last_tested = response.to_i unless response.empty?

      # Confirm save location
      response = shell.ask "This will be saved in #{s.config_file}. Press " \
        'enter to accept or enter a new location:', :blue, path: true
      s.config_file = response unless response.empty?
    end

    # Confirm data. If not confirmed, restart whole wizard.
    if confirm_computer_data
      save_computer_data
    else
      puts "Restarting wizard.\n"
      setup
    end
  end

  def self.new_from_config(
    config_file: File.join(ENV['HOME'], '.mesa_test.yml'), force_setup: false,
    base_uri: DEFAULT_URI
    # base_uri: 'http://localhost:3000'
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
                :platform_version, :processor, :ram_gb, :compiler,
                :compiler_version, :config_file, :base_uri, :last_tested

  attr_reader :shell

  # many defaults are set in body
  def initialize(
      computer_name: nil, user_name: nil, email: nil, platform: nil,
      platform_version: nil, processor: nil, ram_gb: nil, compiler: nil,
      compiler_version: nil, config_file: nil, base_uri: nil, last_tested: nil
  )
    @computer_name = computer_name || Socket.gethostname.scan(/^[^\.]+\.?/)[0]
    @computer_name.chomp!('.') if @computer_name
    @user_name = user_name || (ENV['USER'] || ENV['USERNAME'])
    @email = email || ''
    @password = password || ''
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
    @ram_gb = ram_gb || 0
    @compiler = compiler || 'SDK'
    @compiler_version = compiler_version || ''
    @config_file = config_file || File.join(ENV['HOME'], '.mesa_test.yml')
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
    puts "User Name               #{user_name}"
    puts "User email              #{email}"
    puts 'Password                ***********'
    puts "Platform                #{platform} #{platform_version}"
    puts "Processor               #{processor}"
    puts "RAM                     #{ram_gb} GB"
    puts "Compiler                #{compiler} #{compiler_version}"
    puts "Last tested revision    #{last_tested}"
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
      'user_name' => user_name,
      'email' => email,
      'password' => password,
      'platform' => platform,
      'processor' => processor,
      'ram_gb' => ram_gb,
      'platform_version' => platform_version,
      'compiler' => compiler,
      'compiler_version' => compiler_version,
      'last_tested' => last_tested
    }
    File.open(config_file, 'w') { |f| f.write(YAML.dump(data_hash)) }
  end

  def load_computer_data
    data_hash = YAML.safe_load(File.read(config_file), [Symbol])
    @computer_name = data_hash['computer_name']
    @user_name = data_hash['user_name']
    @email = data_hash['email']
    @password = data_hash['password']
    @platform = data_hash['platform']
    @processor = data_hash['processor']
    @ram_gb = data_hash['ram_gb']
    @platform_version = data_hash['platform_version']
    @compiler = data_hash['compiler']
    @compiler_version = data_hash['compiler_version']
    @last_tested = data_hash['last_tested'] || @last_tested
  end

  # create and return hash of parameters for a TestInstance submission
  # Note: prefer test case's self-reported compiler and compiler version over
  # user reported
  def submit_params(test_case)
    res = {
      test_case: test_case.test_name,
      mod: test_case.mod,
      computer: computer_name,
      email: email,
      password: password,
      runtime_seconds: test_case.runtime_seconds,
      mesa_version: test_case.mesa_version,
      passed: test_case.passed? ? 1 : 0,
      compiler: test_case.compiler || compiler,
      compiler_version: test_case.compiler_version || compiler_version,
      platform_version: platform_version,
      omp_num_threads: test_case.test_omp_num_threads,
      success_type: test_case.success_type,
      failure_type: test_case.failure_type,
      steps: test_case.steps,
      retries: test_case.retries,
      backups: test_case.backups,
      summary_text: test_case.summary_text
    }

    # enter in test-specific data, DISABLED FOR NOW
    # test_case.data_names.each do |data_name|
    #   unless test_case.data[data_name].nil?
    #     res[data_name] = test_case.data[data_name]
    #   end
    # end
    res
  end

  def revision_submit_params(mesa)
    mesa.load_svn_data if mesa.use_svn?      
    # version gives data about version
    # user gives data about the user and computer submitting information
    # instances is array of hashes that identify test instances (more below)
    res = {
            version: {number: mesa.version_number, compiled: mesa.installed?},
            user: {email: email, password: password, computer: computer_name},
            instances: []
          }
    if mesa.use_svn?
      res[:version][:author] = mesa.svn_author
      res[:version][:log] = mesa.svn_log
    end

    # bail out if installation failed (and we care)
    return [res, []] unless res[:version][:compiled]

    # Successfully compiled, now gather test instance data.

    # hold on to test case names that fail in synthesizing params
    has_errors = []

    # each instance has basic information in :test_instance and extra
    # information that requires the web app to work, stored in :extra
    mesa.test_names.each do |mod, names|
      names.each do |test_name|
        begin
          test_case = mesa.test_cases[mod][test_name]
          res[:instances] << {
            test_instance: {
              runtime_seconds: test_case.runtime_seconds,
              passed: test_case.passed?,
              compiler: compiler,
              compiler_version: compiler_version,
              platform_version: platform_version,
              omp_num_threads: test_case.test_omp_num_threads,
              success_type: test_case.success_type,
              failure_type: test_case.failure_type,
              steps: test_case.steps,
              retries: test_case.retries,
              backups: test_case.backups,
              summary_text: test_case.summary_text
            },
            extra: { test_case: test_name, mod: mod }
          }
        rescue TestCaseDirError
          shell.say "Passage status for #{test_case.test_name} not yet "\
                    'known. Run test first and then submit.', :red
          has_errors << test_case
        end
      end
    end
    [res, has_errors]
  end

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

  # attempt to post to MesaTestHub with test_case parameters
  # returns true if the id is in the returned JSON (indicating success)
  # otherwise returns false (maybe failed in authorization or in finding
  # computer or test case) No error thrown for failure, though.
  def submit(test_case)
    uri = URI.parse(base_uri + '/test_instances/submit.json')
    https = Net::HTTP.new(uri.hostname, uri.port)
    https.use_ssl = true if base_uri.include? 'https'

    request = Net::HTTP::Post.new(
      uri,
      initheader = { 'Content-Type' => 'application/json' }
    )
    begin
      request.body = submit_params(test_case).to_json
    rescue TestCaseDirError
      shell.say "\nPassage status for #{test_case.test_name} not yet known. " \
                'Run test first and then submit.', :red
      return false
    end

    # verbose = true
    # puts "\n" if verbose
    # puts JSON.parse(request.body).to_hash if verbose

    response = https.request request
    # puts JSON.parse(response.body).to_hash if verbose
    response.is_a? Net::HTTPCreated
  end

  def submit_all(mesa, mod = :all)
    submitted_cases = []
    unsubmitted_cases = []
    if mod == :all
      success = true
      mesa.test_names.each_key do |this_mod|
        success &&= submit_all(mesa, mod = this_mod)
      end
    else
      mesa.test_names[mod].each do |test_name|
        # get at test case
        test_case = mesa.test_cases[mod][test_name]
        # try to submit and note if it does or doesn't successfully submit
        submitted = false
        submitted = submit(test_case) unless test_case.outcome == :not_tested
        if submitted
          submitted_cases << test_name
        else
          unsubmitted_cases << test_name
        end
      end
      puts "\nSubmission results for #{mod} module:"
      puts '#####################################'
      if !submitted_cases.empty?
        shell.say 'Submitted the following cases:', :green
        puts submitted_cases.join("\n")
      else
        shell.say 'Did not successfully submit any cases.', :red
      end
      unless unsubmitted_cases.empty?
        puts "\n\n\n"
        shell.say 'Failed to submit the following cases:', :red
        puts unsubmitted_cases.join("\n")
      end
      # return true and update last tested if all cases were submitted
      success = submitted_cases.length == mesa.test_names[mod].length
      if success
        @last_tested = mesa.version_number
        shell.say "\n\nUpdating last tested revision to #{last_tested}."
        save_computer_data
      end
    end
    # return boolean indicating whether or not all cases successfully
    # SUBMITTED (irrespective of passing status)
    success
  end

  # similar to submit_all, but does EVERYTHING in one post, including
  # version information. No support for individual modules now.
  def submit_revision(mesa)
    uri = URI.parse(base_uri + '/versions/submit_revision.json')
    https = Net::HTTP.new(uri.hostname, uri.port)
    https.use_ssl = true if base_uri.include? 'https'

    request = Net::HTTP::Post.new(
      uri,
      initheader = { 'Content-Type' => 'application/json' }
    )
    request_data, error_cases = revision_submit_params(mesa)
    if request_data[:instances].empty? && mesa.installed?
      shell.say "No completed test data found in #{mesa.mesa_dir}. Aborting.",
                :red
      return false
    end
    request.body = request_data.to_json

    # verbose = true
    # puts "\n" if verbose
    # puts JSON.parse(request.body).to_hash if verbose

    response = https.request request
    # puts JSON.parse(response.body).to_hash if verbose
    if !response.is_a? Net::HTTPCreated
      shell.say "\nFailed to submit some or all cases and/or version data.",
                :red
      false
    elsif !error_cases.empty?
      shell.say "\nFailed to gather data for the following cases:", :red
      error_cases.each { |tc| shell.say "  #{tc.test_name}", :red }
      false
    else
      shell.say "\nSuccessfully submitted revision #{mesa.version_number}.", :green
      @last_tested = mesa.version_number
      shell.say "\n\nUpdating last tested revision to #{last_tested}."
      save_computer_data
      true      
    end
  end
end

class Mesa
  SVN_URI = 'svn://svn.code.sf.net/p/mesa/code/trunk'.freeze    

  attr_reader :mesa_dir, :test_data, :test_names, :test_cases, :shell,
              :svn_version, :svn_author, :svn_log, :using_sdk
  attr_accessor :update_checksums

  def self.download(version_number: nil, new_mesa_dir: nil, use_svn: true,
    using_sdk: true)
    new_mesa_dir ||= File.join(ENV['HOME'], 'mesa-test-r' + version_number.to_s)
    success = bash_execute(
      "svn co -r #{version_number} " \
      "svn://svn.code.sf.net/p/mesa/code/trunk #{new_mesa_dir}"
    )
    unless success
      raise MesaDirError, 'Encountered a problem in downloading mesa ' \
                          "revision #{version_number}. Perhaps svn isn't " \
                          'working properly?'
    end
    Mesa.new(mesa_dir: new_mesa_dir, use_svn: use_svn, using_sdk: using_sdk)
  end

  def self.log_since(last_tested = DEFAULT_REVISION)
    # svn commit log back to, but excluding, the last revision tested
    `svn log #{SVN_URI} -r #{last_tested + 1}:HEAD`
  end

  def self.log_lines_since(last_tested = DEFAULT_REVISION)
    log_since(last_tested).split("\n").reject(&:empty?)
  end

  def self.add_commit(commits, revision, author)
    commits << Commit.new
    commits.last.revision = revision.to_i
    commits.last.author = author
    commits.last.message = []
  end

  def self.process_line(commits, line)
    last = commits.last
    if line =~ /^-+$/
      # dashed lines separate commits
      # Done with last commit (if it exists), so clean up message
      last.message = last.message.join("\n") unless last.nil?
    elsif line =~ /^r(\d+) \| (\w+) \| .* \| \d+ lines?$/
      # first line of a commit, scrape data and make new commit
      add_commit(commits, $1, $2)
    else
      # add lines to the message (will concatenate later to single String)
      last.message << line.strip
    end
  end

  # all commits since the given version number
  def self.commits_since(last_tested = DEFAULT_REVISION)
    commits = []
    log_lines_since(last_tested).each { |line| process_line(commits, line) }
    commits.sort_by(&:revision).reverse
  end

  def self.last_non_paxton_revision(last_tested = DEFAULT_REVISION)
    commits_since(last_tested).each do |commit|
      return commit.revision unless commit.author == 'bill_paxton'
    end
    # give out garbage if no valid commit is found
    nil
  end

  def initialize(mesa_dir: ENV['MESA_DIR'], use_svn: true, using_sdk: false)
    # absolute_path ensures that it doesn't matter where commands are executed
    # from
    @mesa_dir = File.absolute_path(mesa_dir)
    @use_svn = use_svn
    @using_sdk = using_sdk
    @update_checksums = false

    # these get populated by calling #load_test_data
    @test_data = {}
    @test_names = {}
    @test_cases = {}

    # way to output colored text
    @shell = Thor::Shell::Color.new

    # these can be populated by calling load_svn_data
    @svn_version = nil
    @svn_author = nil
    @svn_log = nil
    load_svn_data if use_svn?
  end

  def use_svn?
    @use_svn
  end

  def version_number
    version = @svn_version || 0
    # fall back to MESA_DIR/data's version number svn didn't work
    version = data_version_number unless version > 0
    version
  end

  def log_entry
    `svn log #{mesa_dir} -r #{version_number}`
  end

  def load_svn_data
    # if this number is bad, #version_number will use fallback method
    @svn_version = svn_version_number
    lines = log_entry.split("\n").reject { |line| line =~ /^-+$/ or line.empty?}
    data_line = lines.shift
    revision, author, date, length = data_line.split('|')
    @svn_author = author.strip
    @svn_log = lines.join("\n").strip
  end

  # get version number from svn (preferred method)
  def svn_version_number
    # match output of svn info to a line with the revision, capturing the
    # number, and defaulting to 0 if none is found.
    return (/Revision\:\s+(\d+)/.match(`svn info #{mesa_dir}`)[1] || 0).to_i
  rescue Errno::ENOENT
    return 0
  end

  # read version number from $MESA_DIR/data/version_number
  def data_version_number
    contents = ''
    File.open(File.join(mesa_dir, 'data', 'version_number'), 'r') do |f|
      contents = f.read
    end
    contents.strip.to_i
  end

  def clean
    with_mesa_dir do
      visit_and_check mesa_dir, MesaDirError, 'E\countered a problem in ' \
                                "running `clean` in #{mesa_dir}." do
        puts 'MESA_DIR = ' + ENV['MESA_DIR']
        puts './clean'
        bash_execute('./clean')
      end
    end
    self
  end

  def install
    with_mesa_dir do
      visit_and_check mesa_dir, MesaDirError, 'Encountered a problem in ' \
                                "running `install` in #{mesa_dir}." do
        puts 'MESA_DIR = ' + ENV['MESA_DIR']
        puts './install'
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
      raise MesaDirError, 'Installation check failed (no .mod files found ' \
                          'in the last compiled module).'
    end
  end    

  def destroy
    FileUtils.rm_rf mesa_dir
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
      # load data from the source file
      source_lines = IO.readlines(
        File.join(test_suite_dir(mod: mod), 'do1_test_source')
      )

      # initialize data hash to empty hash and name array to empty array
      @test_data[mod] = {}
      @test_names[mod] = []
      @test_cases[mod] = {}

      # read through each line and find four data, name, success string, final
      # model name, and photo. Either of model name and photo can be "skip"
      source_lines.each do |line|
        no_skip = /^do_one (.+)\s+"([^"]*)"\s+"([^"]+)"\s+(x?\d+)/
        one_skip = /^do_one (.+)\s+"([^"]*)"\s+"([^"]+)"\s+skip/
        two_skip = /^do_one (.+)\s+"([^"]*)"\s+skip\s+skip/
        found_test = false
        if line =~ no_skip
          found_test = true
          @test_data[mod][$1] = { success_string: $2, final_model: $3,
                                  photo: $4}
        elsif line =~ one_skip
          found_test = true
          @test_data[mod][$1] = { success_string: $2, final_model: $3,
                                  photo: nil }
        elsif line =~ two_skip
          found_test = true
          @test_data[mod][$1] = { success_string: $2, final_model: nil,
                                  photo: nil }
        end

        if found_test
          @test_names[mod] << $1 unless @test_names[mod].include? $1
        end
      end

      # make MesaTestCase objects accessible by name
      @test_names[mod].each do |test_name|
        data = @test_data[mod][test_name]
        @test_cases[mod][test_name] = MesaTestCase.new(
          test: test_name, mesa: self, success_string: data[:success_string],
          mod: mod, final_model: data[:final_model], photo: data[:photo]
        )
      end
    end
  end

  # can accept a number (in string form) as a name for indexed access
  def find_test_case(test_case_name: nil, mod: :all)
    if /\A[0-9]+\z/ =~ test_case_name
      find_test_case_by_number(test_number: test_case_name.to_i, mod: mod)
    else
      find_test_case_by_name(test_case_name: test_case_name, mod: mod)
    end
  end

  # based off of `$MESA_DIR/star/test_suite/each_test_run_and_diff` from
  # revision 10000
  def each_test_clean(mod: :all)
    if mod == :all
      MesaTestCase.modules.each { |this_mod| each_test_clean mod: this_mod }
    else
      check_mod mod
      test_names[mod].each do |test_name|
        test_cases[mod][test_name].clean
      end
    end
  end

  def each_test_run_and_diff(mod: :all, log_results: false)
    check_installation
    each_test_clean(mod: mod)

    if mod == :all
      MesaTestCase.modules.each do |this_mod|
        each_test_run_and_diff(mod: this_mod, log_results: log_results)
      end
    else
      test_names[mod].each do |test_name|
        test_cases[mod][test_name].do_one
        test_cases[mod][test_name].log_results if log_results
      end
      log_summary(mod: mod) if log_results
    end
  end

  def each_test_load_results(mod: :all)
    if mod == :all
      MesaTestCase.modules.each do |this_mod|
        each_test_load_results(mod: this_mod)
      end
    else
      test_names[mod].each do |test_name|
        test_cases[mod][test_name].load_results
      end
    end
  end

  def downloaded?
    check_mesa_dir
  end

  def installed?
    # look for output files in the last-installed module
    # this isn't perfect, but it's a pretty good indicator of completing
    # installation
    install_file = File.join(mesa_dir, 'install')
    # match last line of things like "do_one SOME_MODULE" or "do_one_parallel 
    # SOME_MODULE", after which the "SOME_MODULE" will be stored in $1
    # that is the last module to be compiled by ./install.
    IO.readlines(install_file).select do |line|
      line =~ /^\s*do_one\w*\s+\w+/
    end.last =~ /^\s*do_one\w*\s+(\w+)/
    # module is "installed" if there is a nonzero number of files in the
    # module's make directory of the form SOMETHING.mod
    !Dir.entries(File.join(mesa_dir, $1, 'make')).select do |file|
      File.extname(file) == '.mod'
    end.empty?
  end


  private

  # verify that mesa_dir is valid by checking for version number and test_suite
  # directory
  def check_mesa_dir
    res = File.exist?(File.join(mesa_dir, 'data', 'version_number'))
    MesaTestCase.modules.each do |mod|
      res &&= File.directory?(test_suite_dir(mod: mod))
    end
    res
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

  def log_summary(mod: :all)
    if mod == :all
      MesaTestCase.modules.each do |this_mod|
        log_summary(mod: this_mod)
      end
    else
      check_mod mod
      res = []
      test_names[mod].each do |test_name|
        test_case = test_cases[mod][test_name]
        res << {
          'test_name' => test_case.test_name,
          'outcome' => test_case.outcome,
          'failure_type' => test_case.failure_type,
          'success_type' => test_case.success_type,
          'runtime_seconds' => test_case.runtime_seconds,
          'omp_num_threads' => test_case.test_omp_num_threads,
          'mesa_version' => test_case.mesa_version
        }
      end
      summary_file = File.join(test_suite_dir(mod: mod), 'test_summary.yml')
      File.open(summary_file, 'w') do |f|
        f.write(YAML.dump(res))
      end
    end
  end

  def find_test_case_by_name(test_case_name: nil, mod: :all)
    if mod == :all
      # look through all loaded modules for desired test case name, return
      # FIRST found (assuming no name duplication across modules)
      @test_names.each do |this_mod, mod_names|
        if mod_names.include? test_case_name
          return @test_cases[this_mod][test_case_name]
        end
      end
      # didn't find any matches, return nil
      nil
    else
      # module specified; check it and return the proper test case (may be nil
      # if the test case doesn't exist)
      check_mod mod
      @test_cases[mod][test_case_name]
    end
  end

  def find_test_case_by_number(test_number: nil, mod: :all)
    # this will be the index in the name array of the proper module of
    # the desired test case
    # input numbers are 1-indexed, but we'll fix that later
    return nil if test_number < 1
    i = test_number

    if mod == :all
      # search through each module in order
      MesaTestCase.modules.each do |this_mod|
        # if i is a valid index for names of this module, extract the proper
        # test case taking into account that the given i is 1-indexed
        if i <= @test_names[this_mod].length
          # puts "i = #{i} <= #{@test_names[this_mod].length}"
          # @test_names[this_mod].each_with_index do |test_name, i|
          #   puts sprintf("%-4d", i + 1) + test_name
          # end
          return find_test_case_by_name(
            test_case_name: @test_names[this_mod][i - 1],
            mod: this_mod
          )
        end
        # index lies outside possible range for this module, move on to
        # next module and decrement index by the number of test cases in this
        # module
        i -= @test_names[this_mod].length
      end
      # return nil if we never broke out of the loop
      nil
    else
      # module was specified, so just hope things work out for the number
      # should probably add a check that the index is actually in the array,
      # but if you're using this feature, you probably know what you're doing,
      # right? Right?
      return find_test_case_by_name(
        test_case_name: @test_names[mod][i - 1],
        mod: mod
      )
    end
  end
end

class MesaTestCase
  attr_reader :test_name, :mesa_dir, :mesa, :success_string, :final_model,
              :failure_msg, :success_msg, :photo, :runtime_seconds,
              :test_omp_num_threads, :mesa_version, :shell, :mod, :retries,
              :backups, :steps, :runtime_minutes, :summary_text, :compiler,
              :compiler_version
  attr_accessor :data_names, :data_types, :failure_type, :success_type,
                :outcome

  def self.modules
    %i[star binary]
  end

  def initialize(test: nil, mesa: nil, success_string: '',
                 final_model: 'final.mod', photo: nil, mod: nil)
    @test_name = test
    @mesa_dir = mesa.mesa_dir
    @mesa = mesa
    @mesa_version = mesa.version_number
    @success_string = success_string
    @final_model = final_model
    @photo = photo
    @failure_type = nil
    @success_type = nil
    @outcome = :not_tested
    @runtime_seconds = 0
    @test_omp_num_threads = 1
    @runtime_minutes = 0
    @retries = 0
    @backups = 0
    @steps = 0
    @summary_text = ''

    # this overrides the submitters choice if it is non-nil
    @compiler = mesa.using_sdk ? 'SDK' : nil
    # only relevant if @compiler is SDK. Gets set during do_one
    @compiler_version = nil

    unless MesaTestCase.modules.include? mod
      raise TestCaseDirError, "Invalid module: #{mod}. Must be one of: " +
                              MesaTestCase.modules.join(', ')
    end
    @mod = mod
    @failure_msg = {
      run_test_string: "#{test_name} run failed: does not match test string",
      run_checksum: "#{test_name} run failed: checksum for #{final_model} " \
        'does not match after ./rn',
      run_diff: "#{test_name} run failed: diff #{final_model} " \
        'final_check.mod after ./rn',
      photo_file: "#{test_name} restart failed: #{photo} does not exist",
      photo_checksum: "#{test_name} restart failed: checksum for " \
        "#{final_model} does not match after ./re",
      photo_diff: "#{test_name} restart failed: diff #{final_model} " \
        'final_check.mod after ./re',
      compilation: "#{test_name} compilation failed"

    }
    @success_msg = {
      run_test_string: "#{test_name} run: found test string: " \
        "'#{success_string}'",
      run_checksum: "#{test_name} run: checksum for #{final_model} matches " \
        'after ./rn',
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
    if @outcome == :pass
      true
    elsif @outcome == :fail
      false
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

  def add_datum(datum_name, datum_type)
    unless data_types.include? datum_type.to_sym
      raise InvalidDataType, "Invalid data type: #{datum_type}. Must be one "\
        'of ' + data_types.join(', ') + '.'
    end
    @data[datum_name] = datum_type
    @data_names << datum_name
  end

  def omp_num_threads
    ENV['OMP_NUM_THREADS'].to_i || 1
  end

  # based on $MESA_DIR/star/test_suite/each_test_clean, revision 10000
  def clean
    shell.say("cleaning #{test_name}", color = :blue)
    puts ''
    check_mesa_dir
    check_test_case
    in_dir do
      puts './clean'
      unless bash_execute('./clean')
        raise TestCaseDirError, 'Encountered an error while running ./clean ' \
        "in #{Dir.getwd}."
      end
      shell.say 'Removing all files from LOGS, LOGS1, LOGS2, photos, ' \
        'photos1, and photos2', color = :blue
      FileUtils.rm_f Dir.glob('LOGS/*')
      FileUtils.rm_f Dir.glob('LOGS1/*')
      FileUtils.rm_f Dir.glob('LOGS2/*')
      FileUtils.rm_f Dir.glob('photos/*')
      FileUtils.rm_f Dir.glob('photos1/*')
      FileUtils.rm_f Dir.glob('photos2/*')

      shell.say 'Removing files binary_history.data, out.txt, and ' \
        'test_results.yml', color = :blue
      FileUtils.rm_f 'binary_history.data'
      FileUtils.rm_f 'out.txt'
      FileUtils.rm_f 'test_results.yml'
      if File.directory? File.join('star_history', 'history_out')
        shell.say 'Removing all files of the form history_out* from ' \
          'star_history', :blue
        FileUtils.rm_f Dir.glob(File.join('star_history', 'history_out', '*'))
      end
      if File.directory? File.join('star_profile', 'profiles_out')
        shell.say 'Removing all files of the form profiles_out* from ' \
          'star_profile', color = :blue
        FileUtils.rm_f Dir.glob(File.join('star_profile', 'profiles_out', '*'))
      end
      shell.say 'Removing .running', color = :blue
      FileUtils.rm_f '.running'
    end
  end

  # based on $MESA_DIR/star/test_suite/each_test_run_and_diff, revision 10000
  def do_one
    @test_omp_num_threads = omp_num_threads
    if mesa.using_sdk
      version_bin = File.join(ENV['MESASDK_ROOT'], 'bin', 'mesasdk_version.sh')
      # can't use bash_execute because the return value of bash_execute is the
      # exit status of the commmand (true or false), whereas backticks give the
      # output (the version string) as the output
      @compiler_version = `bash -c #{version_bin}`.strip
      shell.say("Using version #{@compiler_version} of the SDK.", :blue)
    end
    in_dir do
      FileUtils.touch '.running'
      shell.say("building and running #{test_name}", :blue)
      puts ''
      build_and_run
      FileUtils.rm '.running'
      puts ''
    end
  end

  def log_results
    # gets all parameters that would be submitted as well as computer
    # information and dumps to a yml file in the test case directory
    save_file = File.join(test_case_dir, 'test_results.yml')
    shell.say "Logging test results to #{save_file}...", :blue
    res = {
      'test_case' => test_name,
      'module' => mod,
      'runtime_seconds' => runtime_seconds,
      'mesa_version' => mesa_version,
      'outcome' => outcome,
      'omp_num_threads' => test_omp_num_threads,
      'success_type' => success_type,
      'failure_type' => failure_type,
      'runtime_minutes' => runtime_minutes,
      'retries' => retries,
      'backups' => backups,
      'steps' => steps,
      'summary_text' => summary_text
    }
    if compiler == 'SDK'
      res['compiler'] = 'SDK'
      res['compiler_version'] = compiler_version
    end
    File.open(save_file, 'w') { |f| f.write(YAML.dump(res)) }
    shell.say "Successfully saved results to file #{save_file}.\n", :green
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
    @mod = data['module'] || @mod
    @mesa_version = data['mesa_version'] || @mesa_version
    @outcome = data['outcome'] || @outcome
    @test_omp_num_threads = data['omp_num_threads'] || @test_omp_num_threads
    @success_type = data['success_type'] || @success_type
    @failure_type = data['failure_type'] || @failure_type
    @runtime_minutes = data['runtime_minutes'] || @runtime_minutes
    @retries = data['retries'] || @retries
    @backups = data['backups'] || @backups
    @steps = data['steps'] || @steps
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
      out_data = parse_out
      @summary_text = get_summary_text
    rescue Errno::ENOENT
      shell.say "\nError loading data from #{out_file}. No summary data "\
                'loaded. Proceeding anyway.', :red
    else
      @runtime_minutes = out_data[:runtime_minutes]
      @retries = out_data[:retries]
      @backups = out_data[:backups]
      @steps = out_data[:steps]
    end
  end

  def parse_out
    runtime_minutes = 0
    retries = 0
    backups = 0
    steps = 0
    run_summaries.each do |summary|
      summary =~ /^\s*runtime\s*\(minutes\),\s+retries,\s+backups,\ssteps\s+(\d+\.?\d*)\s+(\d+)\s+(\d+)\s+(\d+)\s*$/
      runtime_minutes += $1.to_f
      retries += $2.to_i
      backups += $3.to_i
      steps += $4.to_i
    end
    {runtime_minutes: runtime_minutes, retries: retries, backups: backups,
     steps: steps}
  end

  private

  def data_types
    %i[float integer string boolean]
  end

  # cd into the test case directory, do something in a block, then cd back
  # to original directory
  def in_dir(&block)
    visit_dir(test_case_dir, &block)
  end

  # make sure that we can get to the test case directory. Throw an exception
  # if we cannot
  def check_test_case
    return if File.directory? test_case_dir
    raise TestCaseDirError, "No such test case: #{test_case_dir}."
  end

  # verify that mesa_dir is valid by checking for version number and test_suite
  # directory
  def check_mesa_dir
    is_valid = File.exist?(File.join(mesa_dir, 'data', 'version_number')) &&
               File.directory?(test_suite_dir)
    raise MesaDirError, "Invalid MESA dir: #{mesa_dir}" unless is_valid
  end

  # append message to log file
  def log_message(msg, color = nil, log_file = 'out.txt')
    if color.nil?
      shell.say(msg)
    else
      shell.say(msg, color)
    end
    File.open(log_file, 'a') { |f| f.puts(msg) }
  end

  # write failure message to log file
  def write_failure_message
    msg = "******************** #{failure_msg[@failure_type]} " \
      '********************'
    log_message(msg, :red)
  end

  # write success message to log file
  def write_success_msg(success_type)
    msg = 'PASS ' + success_msg[success_type]
    log_message(msg, :green)
  end

  # used as return value for run or photo test. Logs failure to text file, and
  # sets internal status to failing
  def fail_test(failure_type)
    @failure_type = failure_type
    @outcome = :fail
    write_failure_message
    false
  end

  # used as return value for run or photo test. Logs data to text file, and
  # sets internal status to passing
  def succeed(success_type)
    @success_type = success_type
    @outcome = :pass
    write_success_msg(success_type)
    true
  end

  def check_run
    # assumes we are in the directory already, called from something else
    run_start = Time.now

    # do the run
    puts './rn >> out.txt 2> err.txt'
    bash_execute('./rn >> out.txt 2> err.txt')

    # report runtime and clean up
    run_finish = Time.now
    @runtime_seconds = (run_finish - run_start).to_i
    shell.say("Finished with ./rn; runtime = #{@runtime_seconds} seconds.",
              :blue)
    append_and_rm_err

    # look for success text
    success = true
    File.open('out.txt', 'r') do |f|
      success = !f.read.downcase.scan(success_string.downcase).empty?
    end
    # bail if there was no test string found
    return fail_test(:run_test_string) unless success

    # no final model to check, and we already found the test string, so pass
    return succeed(:run_test_string) unless final_model

    # display runtime message
    puts IO.readlines('out.txt').select { |line| line.scan(/runtime/i) }[-1]

    # update checksums
    #
    # if this is true, behave like each_test_run.  update the checksum
    # after rn and then check it matches after re
    #
    # if this is false, behave like each_test_run_and_diff.  assume
    # the checksum is up-to-date and check it matches after rn and re.
    if @mesa.update_checksums
      puts "md5sum \"#{final_model}\" > checks.md5"
      bash_execute("md5sum \"#{final_model}\" > checks.md5")
      FileUtils.cp final_model, 'final_check.mod'

      # if there's no photo, we won't check the checksum, so we've succeeded
      return succeed(:run_test_string) unless photo
      # if there is a photo, we'll have to wait and see
      return true
    end

    # check that final model matches
    puts './ck >& final_check_diff.txt'
    return fail_test(:run_checksum) unless
      bash_execute('./ck >& final_check_diff.txt')
    return fail_test(:run_diff) if File.exist?('final_check_diff.txt') &&
                                   !File.read('final_check_diff.txt').empty?
    return succeed(:run_checksum) if File.exist? final_model
  end

  # prepare for and do restart, check results, and return pass/fail status
  def check_restart
    # abort if there is not photo specified
    return unless photo

    # check that photo file actually exists
    unless File.exist?(File.join('photos', photo)) ||
           File.exist?(File.join('photos1', photo))
      return fail_test(:photo_file)
    end

    # remove final model since it will be remade by restart
    FileUtils.rm_f final_model

    # do restart and consolidate output
    puts "./re #{photo} >> out.txt 2> err.txt"
    bash_execute("./re #{photo} >> out.txt 2> err.txt")
    append_and_rm_err

    # check that final model matches
    puts './ck >& final_check_diff.txt'
    return fail_test(:photo_checksum) unless
      bash_execute('./ck >& final_check_diff.txt')
    return fail_test(:photo_diff) if
      File.exist?('final_check_diff.txt') &&
      !File.read('final_check_diff.txt').empty?
    succeed(:photo_checksum)
  end

  def build_and_run
    # assumes we are in the test case directory. Should only be called
    # in the context of an `in_dir` block.

    # first clean and make... Should be compatible with any shell since
    # redirection is always wrapped in 'bash -c "{STUFF}"'
    simple_clean
    begin
      mk
    rescue TestCaseDirError
      return fail_test(:compilation)
    end

    # remove old final model if it exists
    remove_final_model

    # only check restart/photo if we get through run successfully
    check_restart if check_run

    # get reported runtime, retries, backups, and steps
    load_summary_data if File.exist?(out_file)
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
    puts err_contents
    shell.say('END OF ERRORS', :red)
  end

  def log_errors(err_contents, outfile)
    return if err_contents.strip.empty?
    File.open(outfile, 'a') { |f_out| f_out.write(err_contents) }
    shell.say("appended to #{outfile}\n", :red)
  end

  def simple_clean
    puts './clean'
    return if bash_execute('./clean')
    raise TestCaseDirError, 'Encountered an error when running `clean` in ' \
      "#{Dir.getwd} for test case #{test_name}."
  end

  def mk
    puts './mk > mk.txt'
    unless bash_execute('./mk > mk.txt')
      raise TestCaseDirError, 'Encountered an error when running `mk` in ' \
        "#{Dir.getwd} for test case #{test_name}."
    end
    FileUtils.rm 'mk.txt'
  end

  def remove_final_model
    # remove final model if it already exists
    return unless final_model
    return unless File.exist?(final_model)
    FileUtils.rm(final_model)
  end

  def out_file
    File.join(test_case_dir, 'out.txt')
  end

  # helpers for getting run summaries
  def run_summaries
    # look at all lines in out.txt
    lines = IO.readlines(out_file)

    # find lines with summary information
    summary_line_numbers = []
    lines.each_with_index do |line, i|
      if line =~ /^\s*runtime \(minutes\),\s+retries,\s+backups,\ssteps/
        summary_line_numbers << i
      end
    end

    # find lines indicating passage or failure of runs and restarts
    run_finish_line_numbers = []
    restart_finish_line_numbers = []
    lines.each_with_index do |line, i|
      if line =~ /^\s*((?:PASS)|(?:FAIL))\s+#{test_name}\s+restart/
        restart_finish_line_numbers << i
      elsif line =~ /^\s*((?:PASS)|(?:FAIL))\s+#{test_name}\s+run/
        run_finish_line_numbers << i
      end
    end

    # only keep summaries that correspond to runs rather than restart
    summary_line_numbers.select do |i|
      run_summary?(i, run_finish_line_numbers, restart_finish_line_numbers)
    end.map { |line_number| lines[line_number] }
  end

  def get_summary_text
    IO.readlines(out_file).select do |line|
      line =~ /^\s*runtime/ 
    end.join
  end

  def run_summary?(i, run_finish_line_numbers, restart_finish_line_numbers)
    # iterate from starting line (a summary line) up to largest PASS/FAIL
    # line, bail out if summary line is beyond any PASS/FAIL line
    max_line = run_finish_line_numbers.max || 0
    max_line = [max_line, (restart_finish_line_numbers.max || 0)].max
    return false if i > max_line
    # return true if next PASS/FAIL line is for a run and fail if it is for a
    # restart
    i.upto(max_line) do |j|
      return true if run_finish_line_numbers.include?(j)
      return false if restart_finish_line_numbers.include?(j)
    end
    false
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
  puts ''
  shell.say "Entering #{new_dir}.", :blue
  Dir.chdir(new_dir)
  success = yield if block_given?
  shell.say "Leaving  #{new_dir}", :blue
  puts ''
  shell.say "Entering #{cwd}.", :blue
  Dir.chdir(cwd)
  return if success
  raise exception, message
end

# cd into a new directory, execute a block, then cd back into original
# directory
def visit_dir(new_dir)
  cwd = Dir.getwd
  shell.say "Leaving  #{cwd}\n", :blue
  shell.say "Entering #{new_dir}.", :blue
  Dir.chdir(new_dir)
  yield if block_given?
  shell.say "Leaving  #{new_dir}\n", :blue
  shell.say "Entering #{cwd}.", :blue
  Dir.chdir(cwd)
end

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
      f.puts "      version_added: #{m.version_number},"
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

# force the execution to happen with bash
def bash_execute(command)
  system('bash -c "' + command + '"')
end
