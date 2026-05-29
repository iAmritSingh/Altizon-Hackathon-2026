# frozen_string_literal: true

module LoadTester
  # Loads a "driver" file and exposes its target factory.
  #
  # A driver is a plain Ruby file that defines a top-level method:
  #
  #     def build_target(worker_id)
  #       # ...set up stubs/fixtures once per worker...
  #       -> { TheFunctionClass.new(...).main(args) }   # the callable under load
  #     end
  #
  # build_target is invoked once per worker (thread or forked process), so it is
  # the right place for per-worker setup (fresh fixtures, connections, etc.).
  # The returned callable is what gets timed on every iteration.
  module TargetLoader
    module_function

    def load_driver(driver_path)
      abs = File.expand_path(driver_path)
      raise "driver not found: #{abs}" unless File.file?(abs)

      Kernel.load(abs)
      unless Object.private_method_defined?(:build_target) || Object.method_defined?(:build_target)
        raise "driver #{abs} must define a top-level `build_target(worker_id)` method"
      end

      ->(worker_id) { build_target(worker_id) }
    end
  end
end
