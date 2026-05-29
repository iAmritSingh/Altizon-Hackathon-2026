# frozen_string_literal: true

# Self-contained example driver — runs without the MInt platform.
#
# It defines a synthetic "function" that does some CPU work (a small aggregation)
# plus a tiny simulated I/O wait, so you can see the load tester working and
# compare --mode thread vs --mode process. Use this as a template for shape;
# see mint_function_driver.rb.example for wiring a REAL MInt function.
#
#   ruby load_test.rb --driver drivers/example_driver.rb -c 8 -n 3000
#   ruby load_test.rb --driver drivers/example_driver.rb -c 8 -n 3000 --mode process

require_relative "../stubs/mint_platform"

class ExampleFunction
  def initialize(license_key, logger, context)
    @license_key = license_key
    @logger = logger
    @context = context
  end

  def main(args)
    rows = args["rows"] || 5_000
    # CPU work: build + reduce a synthetic dataset (stands in for a pipeline).
    total = 0.0
    rows.times do |i|
      total += Math.sqrt((i * 31 % 997) + 1) * ((i % 7) + 1)
    end
    { "license_key" => @license_key, "rows" => rows, "checksum" => total.round(2), "errors" => [] }
  end
end

# Required by the load tester. Called once per worker.
def build_target(_worker_id)
  context = MintPlatform.context # no eval_function stubs needed here
  logger = MintPlatform.logger
  license_key = "demo-license"
  args = { "rows" => 5_000 }

  -> { ExampleFunction.new(license_key, logger, context).main(args) }
end
