# PERF_GATE_BOOTSTRAP for running REAL mint-content functions under the gate.
# Boots the factory Rails app (loads Mongoid + models like GenericEvent), then repoints the
# default Mongoid client at the local SEEDED Mongo so the gate never touches prod/staging.
#
# Env:
#   FACTORY_DIR          path to the factory checkout (has config/environment.rb)
#   PERF_GATE_MONGO_URL  the seeded local Mongo, e.g. mongodb://127.0.0.1:27018/perf_gate
#
# Prereqs on your machine: `cd $FACTORY_DIR && bundle install` once, ruby 3.2.3.

factory_dir = ENV.fetch('FACTORY_DIR')
ENV['RAILS_ENV'] ||= 'test'           # any env; we override the DB below regardless

require File.join(factory_dir, 'config', 'environment')

if (url = ENV['PERF_GATE_MONGO_URL'])
  Mongoid.disconnect_clients rescue nil
  Mongoid.configure { |c| c.clients = { 'default' => { 'uri' => url } } }
  warn "[bootstrap_factory] Mongoid default client -> #{url}"
end
