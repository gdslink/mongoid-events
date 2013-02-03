require 'rubygems'
require 'bundler'
begin
  Bundler.setup(:default, :development)
rescue Bundler::BundlerError => e
  $stderr.puts e.message
  $stderr.puts "Run `bundle install` to install missing gems"
  exit e.status_code
end
require 'rake'

require 'jeweler'
Jeweler::Tasks.new do |gem|
  # gem is a Gem::Specification... see http://docs.rubygems.org/read/chapter/20 for more options
  gem.name = "mongoid-events"
  gem.homepage = "http://github.com/gdslink/mongoid-events"
  gem.license = "MIT"
  gem.summary = %Q{ cube, reporting, time series, event tracking, auditing, undo, redo for mongoid}
  gem.description = %Q{This gem will capture CRUD events from a Mongoid model and keep track of them in its own collection [model_name]_events. It's compatible with Square Cube for time series reporting."}
  gem.email = ["aq1018@gmail.com", "justin.mgrimes@gmail.com", "jdmorani@gdslink.com"]
  gem.authors = ["Aaron Qian", "Justin Grimes", "Jean-Dominique Morani"]
end
Jeweler::RubygemsDotOrgTasks.new

require 'rspec/core'
require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new(:spec) do |spec|
  spec.pattern = FileList['spec/**/*_spec.rb']
  spec.rspec_opts = "--color --format progress"
end

task :default => :spec

require 'yard'
YARD::Rake::YardocTask.new
