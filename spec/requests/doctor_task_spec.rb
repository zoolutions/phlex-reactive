# frozen_string_literal: true

require "rails_helper"
require "rake"

# The `phlex_reactive:doctor` rake task ships in lib/tasks and is auto-loaded by
# the Rails engine in a host app (issue #106). Here we load the .rake file
# directly against the booted dummy app and drive the task, asserting it prints
# the report and runs cleanly on a correctly-wired install.
RSpec.describe "phlex_reactive:doctor rake task" do
  let(:rake) do
    app = Rake::Application.new
    Rake.application = app
    Rake::Task.define_task(:environment) # already booted; the task just depends on it
    load File.expand_path("../../lib/tasks/phlex_reactive.rake", __dir__)
    app
  end

  after { Rake.application = Rake::Application.new }

  it "defines the doctor task" do
    rake # trigger the load
    expect(Rake::Task.task_defined?("phlex_reactive:doctor")).to be(true)
  end

  it "prints the ✓ report and does not abort on the correctly-wired dummy app" do
    Rails.application.eager_load!
    # The dummy's subscribe demo (TodoStatusComponent, issue #474) is pgbus-
    # only and wired in the pgbus cells; this suite runs on Action Cable, where
    # the doctor rightly fails it (spec/phlex/reactive/doctor_spec.rb).
    allow(Phlex::Reactive::Subscribe).to receive(:capable?).and_return(true)
    expect { rake["phlex_reactive:doctor"].invoke }
      .to output(/phlex-reactive doctor.*✓.*passed/m).to_stdout
  end
end
