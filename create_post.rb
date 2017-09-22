#!/usr/bin/env ruby
# frozen_string_literal: true

# Quick hacky script to get all my instagram images and create posts from them.
require 'colorize'
require 'date'
require 'erb'
require 'json'
require 'octokit'
require 'open-uri'

TEMPLATE = ERB.new <<~TEMPLATE
  ---
  layout: post
  date: <%= @pub_date.strftime("%F %T %z") %>
  title: "<%= @title.gsub(/[".]/, '') %>"
  type: post
  tags:
  - instagram
  instagram_url: <%= @image['link'] %>
  ---

  ![Instagram - <%= @short_code %>](/img/<%= @short_code %>.jpg){:class="instagram"}

  <%= @image['caption']['text'] %>
TEMPLATE

def client
  @client ||= Octokit::Client.new(access_token: ENV['GITHUB_TOKEN'])
end

def tokens?
  return false unless ENV['INSTAGRAM_TOKEN']
  return false unless ENV['GITHUB_TOKEN']
  true
end

def repo(tags = [])
  return 'lildude/gonefora.run' if tags.include?('run')
  return 'lildude/lildude.co.uk' if tags.include?('tech')
  return 'lildude/lildude.github.io' if ENV['RACK_ENV'] == 'development' || ENV['RACK_ENV'] == 'test'
  'lildude/colinseymour.co.uk'
end

def repo_has_post?(repo, short_code)
  res = client.search_code("filename:#{short_code} repo:#{repo} path:_posts")
  return false if res.total_count.zero?
  true
end

def instagram_images
  uri = URI("https://api.instagram.com/v1/users/self/media/recent/?access_token=#{ENV['INSTAGRAM_TOKEN']}")
  res = JSON.parse(uri.open.read)
  res['data']
end

def add_files_to_repo(repo, files = {})
  sha_latest_commit = client.ref(repo, 'heads/master').object.sha
  sha_base_tree = client.commit(repo, sha_latest_commit).commit.tree.sha

  new_tree = files.map do |path, content|
    Hash(
      path: path,
      mode: '100644',
      type: 'blob',
      sha: client.create_blob(repo, content, 'base64')
    )
  end

  sha_new_tree = client.create_tree(repo, new_tree, base_tree: sha_base_tree).sha
  sha_new_commit = client.create_commit(repo, 'New Instagram photo', sha_new_tree, sha_latest_commit).sha
  client.update_ref(repo, 'heads/master', sha_new_commit)
end

#### All the action starts ####
if $PROGRAM_NAME == __FILE__
  begin
    raise 'Missing auth env vars for tokens' unless tokens?

    instagram_images.each do |image|
      @image = image
      @short_code = File.basename(image['link'])
      print "#{@short_code} => ".yellow

      # Exit early if the image was posted over an hour ago
      @pub_date = DateTime.strptime(image['created_time'].to_s, '%s')
      if @pub_date < DateTime.now - (1 / 24.0)
        puts 'Nothing new'.blue
        exit
      end

      dest_repo = repo(image['tags'])
      print "#{dest_repo} => ".magenta
      # Skip if repo already has the photo - this is just a precaution
      if repo_has_post? dest_repo, @short_code
        puts 'Skipped'.blue
        next
      end

      # Download the image
      img_filename = "img/#{@short_code}.jpg"
      img_url = image['images']['standard_resolution']['url'].gsub(%r{s640x640/sh0.08/e35/}, '')
      img_content = Base64.encode64(open(img_url).read)

      # Determine the title
      @title =
        if image['caption']['text']
          if image['caption']['text'].split.size > 8
            "#{image['caption']['text'].split[0...8].join(' ')}…"
          else
            image['caption']['text']
          end
        else
          "Instagram - #{@short_code}"
        end

      # Create the post
      post_filename = "_posts/#{@pub_date.strftime('%F')}-#{@short_code}.md"
      post_content = Base64.encode64(TEMPLATE.result)

      add_files_to_repo dest_repo, "#{post_filename}": post_content, "#{img_filename}": img_content
      puts 'DONE'.green
    end
  rescue RuntimeError => e
    $stderr.puts "Error: #{e}".red
    exit 1
  end
end
