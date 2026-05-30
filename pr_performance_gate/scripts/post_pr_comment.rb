#!/usr/bin/env ruby
# Track 1 — Post a gate comment to a GitHub PR (what CI's `gh pr comment` does, without gh).
#
# The repo remote is usually SSH (git@github.com:owner/repo) which authenticates `git fetch` but
# NOT the REST API, so posting a comment needs a Personal Access Token (repo scope).
#
#   ruby post_pr_comment.rb --repo-slug Altizon/mint-content --pr 20898 \
#       --token "$GH_TOKEN" --files pipeline_shape.md,load_test.md [--marker perfiq-gate]
#
# With --marker, an existing bot comment carrying that hidden marker is UPDATED in place instead of
# posting a duplicate on every run (same idempotent behaviour as CI bots).

require 'optparse'
require 'json'
require 'net/http'
require 'uri'

opts = { files: [], marker: 'perfiq-gate' }
OptionParser.new do |o|
  o.on('--repo-slug S') { |v| opts[:slug] = v }       # owner/repo
  o.on('--pr N')        { |v| opts[:pr] = v }
  o.on('--token T')     { |v| opts[:token] = v }
  o.on('--files F')     { |v| opts[:files] = v.split(',') }
  o.on('--marker M')    { |v| opts[:marker] = v }
end.parse!

abort 'need --repo-slug, --pr, --token' unless opts[:slug] && opts[:pr] && opts[:token]
body_parts = opts[:files].select { |f| File.exist?(f) }.map { |f| File.read(f) }
abort 'no comment files found to post' if body_parts.empty?

marker = "<!-- #{opts[:marker]} -->"
body   = ([marker] + body_parts).join("\n\n---\n\n")

def gh(method, path, token, payload = nil)
  uri = URI("https://api.github.com#{path}")
  klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch }[method]
  req = klass.new(uri)
  req['Authorization'] = "Bearer #{token}"
  req['Accept'] = 'application/vnd.github+json'
  req['User-Agent'] = 'performanceiq-gate'
  req.body = JSON.generate(payload) if payload
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  abort "GitHub API #{method.upcase} #{path} -> #{res.code}: #{res.body}" unless res.code.to_i.between?(200, 299)
  res.body.empty? ? {} : JSON.parse(res.body)
end

# Reuse our own marked comment if present (idempotent), else create a new one.
existing = gh(:get, "/repos/#{opts[:slug]}/issues/#{opts[:pr]}/comments?per_page=100", opts[:token])
mine = existing.find { |c| c['body'].to_s.include?(marker) }

if mine
  gh(:patch, "/repos/#{opts[:slug]}/issues/comments/#{mine['id']}", opts[:token], { body: body })
  puts "Updated existing comment: #{mine['html_url']}"
else
  created = gh(:post, "/repos/#{opts[:slug]}/issues/#{opts[:pr]}/comments", opts[:token], { body: body })
  puts "Posted new comment: #{created['html_url']}"
end
