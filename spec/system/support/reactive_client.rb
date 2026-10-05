# frozen_string_literal: true

# Which client entry the dummy app's layouts load (issue #275):
#
#   default  phlex/reactive/reactive_controller — ONE file, the core and every
#            feature bundled. What every app gets; what this suite runs on.
#   split    phlex/reactive/core — the opt-in controller without its features,
#            which it imports on demand. Run with REACTIVE_CLIENT=split
#            (`rake spec:system_split` runs the specs that matter there).
#
# An example about the import window, a feature being fetched, or anything
# else only the split client does is tagged `split_client: true`; one about
# the default client's guarantees is tagged `default_client: true`. Each is
# excluded under the other entry — everything untagged must pass under both.
module ReactiveClient
  def self.split? = ENV["REACTIVE_CLIENT"] == "split"
end

RSpec.configure do
  it.filter_run_excluding(ReactiveClient.split? ? { default_client: true } : { split_client: true })
end
