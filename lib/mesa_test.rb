require 'fileutils'
require 'socket'
require 'os'
require 'yaml'
require 'uri'
require 'net/http'
require 'net/https'
require 'thor'
require 'json'

class MesaDirError < StandardError; end
class TestCaseDirError < StandardError; end
class InvalidDataType < StandardError; end

class MesaTestSubmitter
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
      response = shell.ask("What is the name of this computer (required)? "+
        "(#{s.computer_name}):", color = :blue)
      s.computer_name = response unless response.empty?

      # Get user name
      response = shell.ask "What is the name of the operator of this " +
        "computer? (#{s.user_name}):", color = :blue
      s.user_name = response unless response.empty?

      # Get user e-mail
      response = shell.ask "What is the email you can be reached " +
        "at (required)? (#{s.email}):", color = :blue
      s.email = response unless response.empty?

      # Get user password
      response = shell.ask "What is the password associated with the email " +
        "#{s.email} (required)? (#{s.password})", color = :blue
      s.password = response unless response.empty?

      # Get platform information
      response = shell.ask "What is the platform of this computer (eg. " +
        "macOS, Ubuntu)? (#{s.platform}):", color = :blue
      s.platform = response unless response.empty?
      response = shell.ask "What is the version of the platform (eg. 10.13, "+
        "16.04)? (#{s.platform_version}):", color = :blue
      s.platform_version = response unless response.empty?

      # Get processor information
      response = shell.ask "What type of processor does this computer have " +
        "(eg. 3.1 GHz Intel i7)? (#{s.processor}):", color = :blue
      s.processor = response unless response.empty?

      # Get ram information
      response = shell.ask "How much RAM (in integer GB) does this computer " +
        "have (eg. 8)? (#{s.ram_gb}) ", color = :blue
      s.ram_gb = response.to_i unless response.empty?

      # Get compiler information
      response = shell.ask "Which compiler are you using? (#{s.compiler}):", 
        color = :blue, limited_to: ['', 'SDK', 'gfortran', 'ifort']
      s.compiler = response unless response.empty? 

      # Get compiler version
      response = shell.ask "What version of the compiler (eg. 20170921 or " +
        "7.2.0)? (#{s.compiler_version}): ", color = :blue
      s.compiler_version = response unless response.empty?

      # Confirm save location
      response = shell.ask "This will be saved in #{s.config_file}. Press " +
        "enter to accept or enter a new location:", color = :blue, path: true
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
    base_uri: 'https://mesa-test-hub.herokuapp.com')
    new_submitter = self.new(config_file: config_file, base_uri: base_uri)
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
    :platform_version, :processor, :ram_gb, :compiler, :compiler_version,
    :config_file, :base_uri

  attr_reader :shell

  # many defaults are set in body
  def initialize(computer_name: nil, user_name: nil, email: nil, platform: nil,
      platform_version: nil, processor: nil, ram_gb: nil, compiler: nil,
      compiler_version: nil, config_file: nil, base_uri: nil)
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
    puts "Ready to submit the following data:"
    puts "-------------------------------------------------------"
    puts "Computer Name           #{computer_name}"
    puts "User Name               #{user_name}"
    puts "User email              #{email}"
    puts "Password                ***********"
    puts "Platform                #{platform} #{platform_version}"
    puts "Processor               #{processor}"
    puts "RAM                     #{ram_gb} GB"
    puts "Compiler                #{compiler} #{compiler_version}"
    puts "Config location         #{config_file}"
    puts "-------------------------------------------------------"
    puts ""
    shell = Thor.new
    response = shell.ask "Is this correct? (y/Y = Yes, anything else = No):"
    if response.strip.downcase == 'y'
      return true
    else
      return false
    end
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
      computer_name: computer_name,
      user_name: user_name,
      email: email,
      password: password,
      platform: platform,
      processor: processor,
      ram_gb: ram_gb,
      platform_version: platform_version,
      compiler: compiler,
      compiler_version: compiler_version      
    }
    File.open(config_file, 'w') { |f| f.write(YAML.dump(data_hash))}
  end

  def load_computer_data
    data_hash = YAML::load(File.read(config_file))
    @computer_name = data_hash[:computer_name]
    @user_name = data_hash[:user_name]
    @email = data_hash[:email]
    @password = data_hash[:password]
    @platform = data_hash[:platform]
    @processor = data_hash[:processor]
    @ram_gb = data_hash[:ram_gb]
    @platform_version = data_hash[:platform_version]
    @compiler = data_hash[:compiler]
    @compiler_version = data_hash[:compiler_version]
  end

  # create and return hash of parameters for a TestInstance submission
  def submit_params(test_case)
    res = {
      test_case: test_case.test_name,
      computer: computer_name,
      email: email,
      password: password,
      runtime_seconds: test_case.runtime_seconds,
      mesa_version: test_case.mesa_version,
      passed: test_case.passed?,
      compiler: compiler,
      compiler_version: compiler_version,
      platform_version: platform_version,
      omp_num_threads: test_case.test_omp_num_threads,
      success_type: test_case.success_type,
      failure_type: test_case.failure_type
    }

    # enter in test-specific data
    test_case.data_names.each do |data_name|
      unless test_case.data[data_name].nil?
        res[data_name] = test_case.data[data_name]
      end
    end
    res
  end

  def confirm_computer
    uri = URI.parse(base_uri + '/check_computer.json')
    https = Net::HTTP.new(uri.hostname, uri.port)
    https.use_ssl = true if base_uri.include? 'https'

    request = Net::HTTP::Post.new(uri, 
      initheader = { 'Content-Type' => 'application/json' })
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
  def submit(test_case, verbose = false)
    uri = URI.parse(base_uri + '/test_instances/submit.json')
    https = Net::HTTP.new(uri.hostname, uri.port)
    https.use_ssl = true if base_uri.include? 'https'

    request = Net::HTTP::Post.new(
      uri,
      initheader = { 'Content-Type' => 'application/json' }
    )
    request.body = submit_params(test_case).to_json

    # puts "\n" if verbose
    # puts JSON.parse(request.body).to_hash if verbose

    response = https.request request
    # puts JSON.parse(response.body).to_hash if verbose
    !response.is_a? Net::HTTPUnprocessableEntity
  end

  def submit_all(mesa)
    submitted_cases = []
    unsubmitted_cases = []
    mesa.test_names.each do |mod, test_names|
      test_names.each do |test_name|
        # get at test case
        test_case = mesa.test_cases[mod][test_name]
        # try to submit and note if it does or doesn't successfully submit
        submitted = false
        unless test_case.outcome == :not_tested
          submitted = submit(test_case)
        end

        if submitted
          submitted_cases << test_name
        else
          unsubmitted_cases << test_name
        end
      end
    end
    puts ''
    if submitted_cases.length > 0
      shell.say "Submitted the following cases:", color = :green
      puts submitted_cases.join("\n")
    else
      shell.say "Did not successfully submit any cases.", color = :red
    end
    if unsubmitted_cases.length > 0
      puts "\n\n\n"    
      shell.say "Failed to submit the following cases:", color = :red
      puts unsubmitted_cases.join("\n")
    end
    # return true if all cases were submitted
    submitted_cases.length == mesa.test_names.length
  end
end

class Mesa
  attr_reader :mesa_dir, :test_data, :test_names, :test_cases, :shell

  def self.download(version_number: nil, new_mesa_dir: nil)
    new_mesa_dir ||= File.join(ENV['HOME'], 'mesa-test-r' + version_number.to_s)
    success = system("svn co -r #{version_number} "+
                     "svn://svn.code.sf.net/p/mesa/code/trunk #{new_mesa_dir}")
    unless success
      raise MesaDirError, "Encountered a problem in download mesa " +
                          "revision #{version_number}."
    end
    Mesa.new(mesa_dir: new_mesa_dir)
  end

  def initialize(mesa_dir: ENV['MESA_DIR'])
    @mesa_dir = mesa_dir

    # these get populated by calling #load_test_data
    @test_data = {}
    @test_names = {}
    @test_cases = {}

    # way to output colored text
    @shell = Thor::Shell::Color.new
  end

  # read version number from $MESA_DIR/data/version_number
  def version_number
    contents = ''
    File.open(File.join(mesa_dir, 'data', 'version_number'), 'r') do |f|
      contents = f.read
    end
    contents.strip.to_i
  end

  def clean
    visit_and_check mesa_dir, MesaDirError, "Encountered a problem in " +
      "running `clean` in #{mesa_dir}." do
      puts './clean'
      system('./clean')
    end
    self
  end

  def install
    visit_and_check mesa_dir, MesaDirError, "Encountered a problem in " +
      "running `install` in #{mesa_dir}." do
      puts './install'
      system('./install')
    end
    self
  end

  def destroy
    FileUtils.rm_rf mesa_dir
  end

  ## TEST SUITE METHODS

  def check_mod(mod)
    unless MesaTestCase.modules.include? mod
      raise TestCaseDirError, "Invalid module: #{mod}. Must be one of: " +
        MesaTestCase.modules.join(', ')
    end
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
      source_lines = IO.readlines(File.join(test_suite_dir(mod: mod),
        'do1_test_source'))

      # initialize data hash to empty hash and name array to empty array
      @test_data[mod] = {}
      @test_names[mod] = []
      @test_cases[mod] = {}

      # read through each line and find four data, name, success string, final
      # model name, and photo. Either of model name and photo can be "skip"
      source_lines.each do |line|
        no_skip = /^do_one (.+) "([^"]*)" "([^"]+)" (x?\d+)/
        one_skip = /^do_one (.+) "([^"]*)" "([^"]+)" skip/
        two_skip = /^do_one (.+) "([^"]*)" skip skip/
        found_test = false
        if line =~ no_skip
          found_test = true
          @test_data[mod][$1] = {success_string: $2, final_model: $3,
            photo: $4}
        elsif line =~ one_skip
          found_test = true
          @test_data[mod][$1] = {success_string: $2, final_model: $3,
            photo: nil}
        elsif line =~ two_skip
          found_test = true
          @test_data[mod][$1] = {success_string: $2, final_model: nil,
            photo: nil}
        end

        if found_test
          @test_names[mod] << $1 unless @test_names.include? $1
        end
      end

      # make MesaTestCase objects accessible by name
      @test_names[mod].each do |test_name|
        data = @test_data[mod][test_name]
        @test_cases[mod][test_name] = MesaTestCase.new(test: test_name,
          mesa: self, success_string: data[:success_string], mod: mod,
          final_model: data[:final_model], photo: data[:photo])
      end
    end
  end

  def find_test_case(test_case_name: nil, mod: :all)
    if mod == :all
      # look through all loaded modules for desired test case name, return
      # FIRST found (assuming no name duplication across modules)
      @test_names.each do |this_mod, mod_names|
        if mod_names.include? test_case_name
          return @test_cases[this_mod][test_case_name]
        end
      end
      # didn't find any matches, return nil
      return nil
    else
      # module specified; check it and return the proper test case (may be nil
      # if the test case doesn't exist)
      check_mod mod
      @test_cases[mod][test_case_name]
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
      log_summary if log_results
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

  # note that this only changes MESA_DIR for subprocesses launched from ruby
  # the old value of MESA_DIR will persist after the ruby process ends
  def set_mesa_dir
    ENV['MESA_DIR'] = mesa_dir
  end

  def installed?
    check_mesa_dir
  end

  private

  # verify that mesa_dir is valid by checking for version number and test_suite
  # directory
  def check_mesa_dir
    res = File.exist?(File.join(mesa_dir, 'data', 'version_number'))
    MesaTestCase.modules.each do |mod|
      res = res and File.directory? test_suite_dir(mod: mod)
    end 
    res
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
          test_name: test_case.test_name,
          outcome: test_case.outcome,
          failure_type: test_case.failure_type,
          success_type: test_case.success_type,
          runtime_seconds: test_case.runtime_seconds,
          omp_num_threads: test_case.test_omp_num_threads,
          mesa_version: test_case.mesa_version
        }
      end
      summary_file = File.join(test_suite_dir(mod: mod), 'test_summary.yml')
      File.open(summary_file, 'w') do |f|
        f.write(YAML::dump(res))
      end
    end
  end
end

class MesaTestCase
  attr_reader :test_name, :mesa_dir, :mesa, :success_string, :final_model,
    :failure_msg, :success_msg, :photo, :runtime_seconds,
    :test_omp_num_threads, :mesa_version, :shell
  attr_accessor :data_names, :data_types, :failure_type, :success_type,
  :outcome

  def self.modules
    [:star, :binary]
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
    unless MesaTestCase.modules.include? mod
      raise TestCaseDirError, "Invalid module: #{mod}. Must be one of: " +
        MesaTestCase.modules.join(', ')
    end    
    @mod = mod
    @failure_msg = {
      run_test_string: "#{test_name} failed: does not match test string",
      run_checksum: "#{test_name} run failed: checksum for #{final_model} " +
        "does not match after ./rn",
      run_diff: "#{test_name} run failed: diff #{final_model} " +
        "final_check.mod after ./rn",
      photo_file: "#{test_name} restart failed: #{photo} does not exist",
      photo_checksum: "#{test_name} restart failed: checksum for " +
        "#{final_model} does not match after ./re",
      photo_diff: "#{test_name} restart failed: diff #{final_model} " +
        "final_check.mod after ./re"
    }
    @success_msg = {
      run_test_string: "#{test_name} run: found test string: " + 
        "'#{success_string}'",
      run_checksum: "#{test_name} run: checksum for #{final_model} matches " +
        "after ./rn",
      photo_checksum: "#{test_name} restart: checksum for #{final_model} " +
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
      raise TestCaseDirError, "Cannot determine pass/fail status of " +
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
    return ENV['OMP_NUM_THREADS'].to_i || 1
  end

  # based on $MESA_DIR/star/test_suite/each_test_clean, revision 10000
  def clean
    shell.say("cleaning #{test_name}", color = :blue)
    puts ''
    check_mesa_dir
    check_test_case
    in_dir do
      puts "./clean"
      unless system('./clean')
        raise TestCaseDirError, "Encountered an error while running ./clean " +
        "in #{Dir.getwd}."
      end
      shell.say "Removing all files from LOGS, LOGS1, LOGS2, photos, " +
        "photos1, and photos2", color = :blue
      FileUtils.rm_f Dir.glob('LOGS/*')
      FileUtils.rm_f Dir.glob('LOGS1/*')
      FileUtils.rm_f Dir.glob('LOGS2/*')
      FileUtils.rm_f Dir.glob('photos/*')
      FileUtils.rm_f Dir.glob('photos1/*')
      FileUtils.rm_f Dir.glob('photos2/*')

      shell.say "Removing files binary_history.data, out.txt, and " +
        "test_results.yml", color = :blue
      FileUtils.rm_f 'binary_history.data'
      FileUtils.rm_f 'out.txt'
      if File.directory? File.join('star_history','history_out')
        shell.say 'Removing all files of the form history_out* from ' \
          'star_history', :blue
        FileUtils.rm_f Dir.glob(File.join('star_history', 'history_out', '*'))
      end
      if File.directory? File.join('star_profile', 'profiles_out')
        shell.say "Removing all files of the form profiles_out* from " +
          "star_profile", color = :blue
        FileUtils.rm_f Dir.glob(File.join('star_profile', 'profiles_out', '*'))
      end
      shell.say "Removing .running", color = :blue
      FileUtils.rm_f '.running'
    end
  end

  # based on $MESA_DIR/star/test_suite/each_test_run_and_diff, revision 10000
  def do_one
    @test_omp_num_threads = omp_num_threads
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
    shell.say "Logging test results to #{save_file}...", color = :blue
    res = {
      test_case: test_name,
      runtime_seconds: runtime_seconds,
      mesa_version: mesa_version,
      outcome: outcome,
      omp_num_threads: test_omp_num_threads,
      success_type: success_type,
      failure_type: failure_type
    }
    File.open(save_file, 'w') { |f| f.write(YAML::dump(res)) }
    shell.say "Successfully saved results to file #{save_file}.",
      color = :green
    puts ''
  end

  def load_results
    # loads all parameters from a previous test run, likely for submission
    # purposes
    load_file = File.join(test_case_dir, 'test_results.yml')
    shell.say "Loading data from #{load_file}...", color = :blue
    data = YAML::load(File.read(load_file))
    @runtime_seconds = data[:runtime_seconds]
    @mesa_version = data[:mesa_version]
    @outcome = data[:outcome].to_sym
    @test_omp_num_threads = data[:omp_num_threads]
    @success_type = data[:success_type]
    @failure_type = data[:failure_type]
    shell.say "Done loading data from #{load_file}.", color = :green
    puts ''
  end

  private

  def data_types
    return [:float, :integer, :string, :boolean]
  end

  # cd into the test case directory, do something in a block, then cd back
  # to original directory
  def in_dir(&block)
    visit_dir(test_case_dir, &block)
  end

  # make sure that we can get to the test case directory. Throw an exception
  # if we cannot
  def check_test_case
    unless File.directory? test_case_dir
      raise TestCaseDirError, "No such test case: #{test_case_dir}."
    end
  end

  # verify that mesa_dir is valid by checking for version number and test_suite
  # directory
  def check_mesa_dir
    is_valid = File.exist?(File.join(mesa_dir, 'data', 'version_number')) and
      File.directory?(test_suite_dir)
    raise MesaDirError, "Invalid MESA dir: #{mesa_dir}" unless is_valid
  end

  # append message to log file
  def log_message(msg, color = nil, log_file = 'out.txt')
    if color.nil?
      shell.say msg
    else
      shell.say msg, color = color
    end
    File.open('out.txt', 'a') { |f| f.puts(msg) }
  end

  # write failure message to log file
  def write_failure_message
    msg = "******************** #{failure_msg[@failure_type]} " +
      "********************" 
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
    return false
  end

  # used as return value for run or photo test. Logs data to text file, and
  # sets internal status to passing
  def succeed(success_type)
    @success_type = success_type
    @outcome = :pass
    write_success_msg(success_type)
    return true
  end

  def check_run
    # assumes we are in the directory already, called from something else
    run_start = Time.now

    # do the run
    puts './rn >> out.txt 2> err.txt'
    system('./rn >> out.txt 2> err.txt')

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
    unless success
      return fail_test(:run_test_string)
    end

    # additional checks for final model, if it is specified
    if final_model
      # update checks after new run (Bill W. doesn't know what this does)
      # (is this supposed to mark things as passed? The original function
      # just has a standard "return" statement, which I interpret as passing)
      if ENV.include? 'UPDATE_CHECKS'
        system("md5sum \"#{final_model}\" > checks.md5")
        puts "md5sum \"#{final_model}\" > checks.md5"
        FileUtils.cp final_model 'final_check.mod'
        return true
      end

      # display runtime message
      puts IO.readlines('out.txt').select { |line| line.scan(/runtime/i) }[-1]

      # check that final model matches
      puts './ck >& final_check_diff.txt'
      if not system('./ck >& final_check_diff.txt')
        return fail_test(:run_checksum)
      elsif File.exist? 'final_check_diff.txt' and 
        not File.read('final_check_diff.txt').empty?
        return fail_test(:run_diff)
      elsif File.exist? final_model
        return succeed(:run_checksum)
      end

    # no final model to check, and we already found the test string, so pass
    else
      return succeed(:run_test_string)
    end
  end

  # prepare for and do restart, check results, and return pass/fail status
  def check_restart
    # abort if there is not photo specified
    return unless photo

    # check that photo file actually exists
    unless File.exist?(File.join('photos', photo)) or 
      File.exist?(File.join('photos1', photo))
      return fail_test(:photo_file)
    end

    # remove final model since it will be remade by restart
    FileUtils.rm_f final_model

    # do restart and consolidate output
    puts "./re #{photo} >> out.txt 2> err.txt"
    system("./re #{photo} >> out.txt 2> err.txt")
    append_and_rm_err

    # check that final model matches
    puts "./ck >& final_check_diff.txt"
    if not system("./ck >& final_check_diff.txt")
      return fail_test(:photo_checksum)
    elsif File.exist?('final_check_diff.txt') and not 
      File.read('final_check_diff.txt').empty?
      return fail_test(:photo_diff)
    else
      return succeed(:photo_checksum)
    end
  end

  def build_and_run
    # assumes we are in the test case directory. Should only be called
    # in the context of an `in_dir` block.

    # first clean and make... worried about shell compatibility since we
    # aren't forcing bash. Hopefully '>' for redirecting output is pretty
    # universal
    simple_clean
    mk

    # remove old final model if it exists
    remove_final_model

    # only check restart/photo if we get through run successfully
    check_restart if check_run
  end

  # append contents of err.txt to end of out.txt, then delete err.txt
  def append_and_rm_err(outfile = 'out.txt', errfile = 'err.txt')
    err_contents = File.read(errfile)
    display_errors(err_contents)
    log_errors(err_contents, outfile)
    FileUtils.rm errfile
  end

  def display_errors(err_contents)
    return unless err_contents.strip.empty?
    shell.say("\nERRORS", :red)
    puts err_contents
    shell.say("END OF ERRORS", :red)
  end

  def log_errors(err_contents, outfile)
    File.open(outfile, 'a') { |f_out| f_out.write(err_contents) }
    shell.say("appended to #{outfile})\n", :red)
  end

  def simple_clean
    puts './clean'
    unless system('./clean')
      raise TestCaseDirError, 'Encountered an error when running `clean` in ' +
        "#{Dir.getwd} for test case #{test_name}."
    end
  end

  def mk
    puts './mk > mk.txt'
    unless system('./mk > mk.txt')
      raise TestCaseDirError, 'Encountered an error when running `mk` in ' +
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
  return unless success
  raise exception, message
end

# cd into a new directory, execute a block, then cd back into original
# directory
def visit_dir(new_dir)
  cwd = Dir.getwd
  shell.say "Leaving  #{cwd}", :blue
  puts ""
  shell.say "Entering #{new_dir}.", :blue
  Dir.chdir(new_dir)
  yield if block_given?
  shell.say "Leaving  #{new_dir}", :blue
  puts ""
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
      f.puts "    {"
      f.puts "      name: '#{test_case_name}',"
      f.puts "      version_added: #{m.version_number},"
      # no comma on last one
      if test_case_name == m.test_names[-1]
        f.puts('    }')
      else
        f.puts('    }')
      end
    end
    f.puts '  ]'
    f.puts ')'
  end
end

