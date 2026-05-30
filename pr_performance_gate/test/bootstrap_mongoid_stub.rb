# PERF_GATE_BOOTSTRAP — real Mongoid query layer, NO factory app.
#
# Boots the standalone Mongoid gem against the local SEEDED Mongo and auto-defines a lightweight
# model for every model constant a function references (GenericEvent, Workorder, Quality, ...),
# so the REAL function code runs unchanged — its `.where`, `.collection.aggregate`, symbol
# operators, etc. all work — without loading the factory Rails app.
#
# Collection naming follows Mongoid's default (model name underscored + pluralized):
#   GenericEvent -> generic_events,  Workorder -> workorders,  Quality -> qualities.
# That matches what seed_dummy_data.rb seeds. The known fidelity gap vs full factory is custom
# `store_in`, field ALIASES, declared types, and scopes defined on the real models — if a function
# needs one, add an explicit class below (copy the `store_in` / `field :x, as: :y` line from the
# real model) and it takes precedence over the auto-stub.
#
# Env: PERF_GATE_MONGO_URL — the local seeded Mongo (mongodb://127.0.0.1:27018/perf_gate)

require 'mongoid'

Mongoid.load_configuration(clients: { default: { uri: ENV.fetch('PERF_GATE_MONGO_URL') } })
Mongoid.logger = Logger.new(IO::NULL) rescue nil
Mongo::Logger.logger.level = Logger::FATAL if defined?(Mongo::Logger)

# Auto-stub any undefined CamelCase model the function references. Each gets a dynamic-field
# Mongoid document on its default collection. We record which were stubbed so the probe/run can
# report the shim boundary (a stubbed model with no real schema = a place factory would differ).
$PERF_STUBBED_MODELS = []

module PerfModelAutostub
  MODEL_RE = /\A[A-Z][A-Za-z0-9]*\z/  # single-segment CamelCase, e.g. GenericEvent

  def const_missing(name)
    sname = name.to_s
    return super unless sname.match?(MODEL_RE)
    klass = Class.new do
      include Mongoid::Document
      include Mongoid::Attributes::Dynamic   # accept any field present in seeded docs
    end
    const_set(name, klass)                   # Mongoid derives collection: name.underscore.pluralize
    $PERF_STUBBED_MODELS << "#{sname} -> #{klass.collection.name}"
    warn "[mongoid_stub] auto-stubbed #{sname} -> #{klass.collection.name}"
    klass
  end
end
Object.extend(PerfModelAutostub)

# ── Explicit overrides (take precedence over the auto-stub) ───────────────────────
# Add real models here when the default collection/alias guess is wrong. Examples:
#   class GenericEvent
#     include Mongoid::Document; include Mongoid::Attributes::Dynamic
#     store_in collection: 'generic_events'
#   end
