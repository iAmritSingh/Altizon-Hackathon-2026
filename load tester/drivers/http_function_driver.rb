# frozen_string_literal: true

# GENERIC driver — load-test ANY deployed MInt function over HTTP. Write once,
# reuse for every function by changing env vars; no per-function driver needed.
#
# It drives the platform's function-execute endpoint:
#     POST {MINT_BASE}/api/v1/functions/{MINT_FN}/execute
# with a JSON body of the function args, under the tester's concurrency/pacing,
# and reports the real end-to-end latency (network + Mongo + Ruby) — which is what
# actually matters for Mongo-heavy functions like bqi_index_report.
#
# Required env:
#   MINT_BASE    Base URL of the MInt server, e.g. https://staging-1.datonis.io
#   MINT_FN      Function name, e.g. bqi_index_report
# Optional env:
#   MINT_ARGS    JSON object of the function args (default: {})
#                e.g. '{"from":"2026-05-01","to":"2026-05-28"}'
#   MINT_AUTH    Value for the Authorization header, e.g. "Bearer eyJ..."
#   MINT_HEADERS JSON object of extra headers, e.g. '{"X-License-Key":"abc"}'
#   MINT_URL     Full execute URL — overrides MINT_BASE/MINT_FN if set
#   MINT_OK      Comma list of status codes treated as success (default 200,201)
#
# Example (HTTP is I/O-bound, so --mode thread is correct here; see README):
#   cd load_tester
#   MINT_BASE=https://staging-1.datonis.io MINT_FN=bqi_index_report \
#   MINT_ARGS='{"from":"2026-05-01","to":"2026-05-28"}' MINT_AUTH="Bearer $TOKEN" \
#     ruby load_test.rb --driver drivers/http_function_driver.rb \
#       -c 8 -n 200 --warmup 5 --title bqi_index_report

require "net/http"
require "json"
require "uri"

def _mint_execute_uri
  return URI(ENV.fetch("MINT_URL")) if ENV["MINT_URL"] && !ENV["MINT_URL"].empty?

  base = ENV["MINT_BASE"]
  fn   = ENV["MINT_FN"]
  abort "set MINT_BASE and MINT_FN (or MINT_URL)" if base.to_s.empty? || fn.to_s.empty?
  URI.join("#{base.chomp('/')}/", "api/v1/functions/#{fn}/execute")
end

def build_target(_worker_id)
  uri  = _mint_execute_uri
  body = (ENV["MINT_ARGS"].to_s.empty? ? {} : JSON.parse(ENV["MINT_ARGS"]))
  ok   = (ENV["MINT_OK"] || "200,201").split(",").map(&:strip)

  headers = { "Content-Type" => "application/json", "Accept" => "application/json" }
  headers["Authorization"] = ENV["MINT_AUTH"] unless ENV["MINT_AUTH"].to_s.empty?
  headers.merge!(JSON.parse(ENV["MINT_HEADERS"])) unless ENV["MINT_HEADERS"].to_s.empty?

  # One keep-alive connection per worker (build_target runs once per worker).
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")
  http.keep_alive_timeout = 30
  http.open_timeout = 10
  http.read_timeout = 120
  http.start

  payload = JSON.generate(body)

  lambda do
    req = Net::HTTP::Post.new(uri.request_uri, headers)
    req.body = payload
    res = http.request(req)
    # Raise on unexpected status so the tester counts it as an error.
    raise "HTTP #{res.code} from #{uri}: #{res.body.to_s[0, 200]}" unless ok.include?(res.code)

    res.body
  end
end