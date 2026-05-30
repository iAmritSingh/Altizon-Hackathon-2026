# frozen_string_literal: true

require "json"
require "tempfile"

module LoadTester
  # Drives a callable `target` (anything responding to #call) under load and
  # collects per-call latency + success/failure.
  #
  # Two execution modes:
  #   :thread  - N threads, closed-loop. True parallelism only for I/O-bound
  #              targets (Ruby's GIL serialises CPU-bound work).
  #   :process - N forked workers. Real parallelism for CPU-bound targets
  #              (e.g. a local function .main() doing pure Ruby/aggregation math).
  #
  # Stop condition is EITHER a fixed number of iterations OR a duration.
  class Engine
    MONO = Process::CLOCK_MONOTONIC

    def initialize(target_factory:, concurrency:, iterations: nil, duration: nil,
                   warmup: 0, target_rps: nil, mode: :thread, on_progress: nil)
      raise ArgumentError, "set iterations or duration" if iterations.nil? && duration.nil?

      @target_factory = target_factory # ->(worker_id) { callable }
      @concurrency = concurrency
      @iterations = iterations
      @duration = duration
      @warmup = warmup
      @target_rps = target_rps
      @mode = mode
      @on_progress = on_progress
    end

    def run
      run_warmup if @warmup.positive?
      started = now
      latencies, errors = @mode == :process ? run_processes : run_threads
      { latencies_ms: latencies, errors: errors, wall_seconds: now - started }
    end

    private

    def now
      Process.clock_gettime(MONO)
    end

    def run_warmup
      target = @target_factory.call(-1)
      @warmup.times { safe_call(target) }
    end

    # One timed invocation. Returns [latency_ms, ok?].
    def safe_call(target)
      t0 = now
      target.call
      [(now - t0) * 1000.0, true]
    rescue StandardError, ScriptError => e
      @last_error = "#{e.class}: #{e.message}"
      [(now - t0) * 1000.0, false]
    end

    # --- shared work dispenser (thread mode) ---------------------------------
    # Closed-loop: each worker pulls the next unit of work until exhausted.
    def make_dispenser
      if @iterations
        remaining = @iterations
        mutex = Mutex.new
        -> { mutex.synchronize { remaining > 0 ? (remaining -= 1; true) : false } }
      else
        deadline = now + @duration
        -> { now < deadline }
      end
    end

    # Global rate limiter shared across workers (approximate open-loop pacing).
    def make_pacer
      return ->{} unless @target_rps

      interval = 1.0 / @target_rps
      mutex = Mutex.new
      next_slot = now
      lambda do
        wait = nil
        mutex.synchronize do
          next_slot = now if next_slot < now
          wait = next_slot - now
          next_slot += interval
        end
        sleep(wait) if wait && wait > 0
      end
    end

    def run_threads
      dispense = make_dispenser
      pace = make_pacer
      buckets = Array.new(@concurrency) { { lat: [], err: 0 } }
      completed = 0
      completed_mutex = Mutex.new

      threads = Array.new(@concurrency) do |wid|
        Thread.new do
          target = @target_factory.call(wid)
          local = buckets[wid]
          while dispense.call
            pace.call
            ms, ok = safe_call(target)
            if ok then local[:lat] << ms else local[:err] += 1 end
            if @on_progress
              c = completed_mutex.synchronize { completed += 1 }
              @on_progress.call(c) if (c % 50).zero?
            end
          end
        end
      end
      threads.each(&:join)

      [buckets.flat_map { |b| b[:lat] }, buckets.sum { |b| b[:err] }]
    end

    # --- process mode (fork) -------------------------------------------------
    def run_processes
      # Split work across workers. Duration mode: every worker runs the full
      # duration. Iteration mode: divide iterations as evenly as possible.
      per_worker =
        if @iterations
          base, extra = @iterations.divmod(@concurrency)
          Array.new(@concurrency) { |i| base + (i < extra ? 1 : 0) }
        else
          Array.new(@concurrency) { nil }
        end

      tmpfiles = Array.new(@concurrency) { Tempfile.new("loadtest") }
      pids = []

      @concurrency.times do |wid|
        pids << fork do
          tmpfiles.each_with_index { |f, i| f.close unless i == wid }
          target = @target_factory.call(wid)
          lat = []
          err = 0
          pace = make_pacer # per-process pacer (approximate; rps is per-worker here)
          if (n = per_worker[wid])
            n.times { pace.call; ms, ok = safe_call(target); ok ? lat << ms : err += 1 }
          else
            deadline = now + @duration
            while now < deadline
              pace.call
              ms, ok = safe_call(target)
              ok ? lat << ms : err += 1
            end
          end
          f = tmpfiles[wid]
          f.write(JSON.generate("lat" => lat, "err" => err))
          f.flush
          exit!(0)
        end
      end

      pids.each { |pid| Process.waitpid(pid) }

      all_lat = []
      total_err = 0
      tmpfiles.each do |f|
        f.rewind
        data = JSON.parse(f.read) rescue { "lat" => [], "err" => 0 }
        all_lat.concat(data["lat"])
        total_err += data["err"]
        f.close!
      end
      [all_lat, total_err]
    end
  end
end
