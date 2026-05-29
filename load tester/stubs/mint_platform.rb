# frozen_string_literal: true

require "date"
require "time"

# Minimal stand-ins for the MInt platform runtime so that a function file can be
# loaded and its .main() driven locally WITHOUT the real Rails/Mongoid platform.
#
# This covers the common surface: ActiveSupport-style helpers (present?/blank?/
# try/presence), a few Time conveniences, a no-op logger, and a configurable
# `context` that fakes eval_function. Anything a specific function touches beyond
# this (GenericObject, model queries, GenericObjectsCache, ...) you stub inside
# your driver — see drivers/mint_function_driver.rb.example.
#
# These shims are intentionally conservative: load-bearing enough for pure-Ruby
# business logic, not a reimplementation of ActiveSupport.

# --- ActiveSupport-ish core ext --------------------------------------------
module MintBlank
  def blank?
    respond_to?(:empty?) ? !!empty? : !self
  end

  def present?
    !blank?
  end

  def presence
    present? ? self : nil
  end
end

class Object
  include MintBlank unless method_defined?(:present?)

  unless method_defined?(:try)
    def try(method_name = nil, *args, &block)
      return nil if method_name && !respond_to?(method_name)
      if method_name
        public_send(method_name, *args, &block)
      elsif block
        instance_eval(&block)
      end
    end
  end

  unless method_defined?(:try!)
    def try!(method_name = nil, *args, &block)
      method_name ? public_send(method_name, *args, &block) : (block ? instance_eval(&block) : self)
    end
  end
end

class NilClass
  def blank?    = true
  def present?  = false
  def presence  = nil
  def try(*)    = nil
  def try!(*)   = nil
end

class String
  def blank? = strip.empty?
end

class Numeric
  def blank? = false
  # very small subset of ActiveSupport duration helpers used by some functions
  def seconds = self
  def minutes = self * 60
  def hours   = self * 3600
  def days    = self * 86_400
  def ago     = Time.now - self
  def from_now = Time.now + self
end

class Hash
  def symbolize_keys = each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
  def stringify_keys = each_with_object({}) { |(k, v), h| h[k.to_s] = v }
end

# --- Time conveniences ------------------------------------------------------
class Time
  def beginning_of_day = Time.new(year, month, day, 0, 0, 0, utc_offset)
  def end_of_day       = Time.new(year, month, day, 23, 59, 59, utc_offset)
end

# --- Platform globals / objects --------------------------------------------
# A logger that discards output (swap for $stderr if you want to see logs).
class MintNullLogger
  %i[debug info warn error fatal unknown].each do |lvl|
    define_method(lvl) { |*_a, &_b| nil }
  end
end

# Fake function-call context. Register canned responses per function name with
# `context.stub_function("name") { |params| [result, errors] }`.
class MintContext
  def initialize
    @stubs = {}
  end

  def stub_function(name, &block)
    @stubs[name.to_s] = block
    self
  end

  def eval_function(name, params = {})
    stub = @stubs[name.to_s]
    return stub.call(params) if stub
    [{}, []] # default: empty result, no errors
  end
end

module MintPlatform
  # Build the global bindings a function expects. Call this from your driver and
  # set the returned values as top-level locals/globals before eval'ing the fn.
  def self.context(&config)
    ctx = MintContext.new
    config&.call(ctx)
    ctx
  end

  def self.logger
    MintNullLogger.new
  end
end
