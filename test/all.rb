#!/usr/bin/env ruby
# Runs every test file. Usage: ruby test/all.rb
Dir[File.join(__dir__, "test_*.rb")].sort.each { |file| require file }
