Gem::Specification.new do |s|
  s.name = 'mesa_test'
  s.version = '1.1.11'
  s.author = 'William Wolf'
  s.date = '2024-11-14'
  s.description = 'mesa_test is a command-line interface for running the ' \
    'test suites in MESA and submitting them to the companion website ' \
    'MESATestHub.'
  s.summary = 'Command line tool for running and reporting the MESA test ' \
    'suites.'
  s.email = 'wolfwm@uwec.edu'
  s.files = 'lib/mesa_test.rb'
  s.homepage = 'https://github.com/MESAHub/mesa_test'
  s.add_dependency('json', '~> 2.0')
  s.add_dependency('os', '~> 1.0')
  s.add_dependency('thor', '~> 1.3.0')
  s.bindir = 'bin'
  s.executables = ['mesa_test']
  s.license = 'MIT'
  s.required_ruby_version = '>= 2.0.0'
end
