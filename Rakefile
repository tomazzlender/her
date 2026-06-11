# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = true
end

desc "Regenerate derived grammar files from editors/her.tmLanguage.json"
task :grammar do
  require_relative "tools/grammar_build"
  GrammarBuild.run(__dir__)
  puts "wrote editors/her.tmLanguage and editors/vscode/her/syntaxes/her.tmLanguage.json"
end

task default: :test
