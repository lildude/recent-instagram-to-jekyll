#!/usr/bin/env ruby
# frozen_string_literal: true

# Quick hacky script to get all my instagram images and create posts from them.
require 'colorize'
require 'date'
require 'erb'
require 'httparty'
require 'json'
require 'octokit'
require 'tempfile'

TEMPLATE = <<~TEMPLATE
  ---
  layout: photo
  date: <%= pub_date.strftime("%F %T %z") %>
  title: "<%= title.gsub(/[".]/, '') %>"
  type: post
  tags:
  - instagram
  <% unless image['tags'].empty? -%>
  <% image['tags'].each do |tag| -%>
  <% unless %w[run tech].include?(tag) -%>
  - <%= tag %>
  <% end -%>
  <% end -%>
  <% end -%>
  instagram_url: <%= image['link'] %>
  ---

  ![Instagram - <%= short_code %>](https://<%= dest_repo.split('/').last %>/img/<%= short_code %>.jpg){:loading="lazy"}{: .u-photo}

  <%= image['caption']['text'].gsub(/\\B#\\w+/, '') %>
TEMPLATE

def client
  @client ||= Octokit::Client.new(access_token: ENV['GITHUB_TOKEN'])
end

def tokens?
  raise 'Missing auth env vars for tokens' unless ENV['INSTAGRAM_TOKEN'] && ENV['GITHUB_TOKEN']

  true
end

def repo(tags = [])
  return 'lildude/gonefora.run' if tags.include?('run')
  return 'lildude/lildude.co.uk' if tags.include?('tech')
  return 'lildude/lildude.github.io' if ENV['RACK_ENV'] == 'development'

  'lildude/colinseymour.co.uk'
end

def repo_has_post?(repo, short_code)
  res = client.search_code("filename:#{short_code} repo:#{repo} path:_posts")
  return false if res.total_count.zero?

  true
end

def instagram_images
  res = HTTParty.get("https://api.instagram.com/v1/users/self/media/recent/?access_token=#{ENV['INSTAGRAM_TOKEN']}")
  res.parsed_response['data']
rescue HTTParty::ResponseError
  puts 'Instagram not reachable right now'.yellow
  exit
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

def render_template(locals = {})
  render_binding = binding
  locals.each { |k, v| render_binding.local_variable_set(k, v) }
  ERB.new(TEMPLATE, trim_mode: '-').result(render_binding)
end

def nice_title(image, short_code)
  title =
    if image['caption']['text']
      if image['caption']['text'].split.size > 8
        "#{image['caption']['text'].split[0...8].join(' ')}…"
      else
        image['caption']['text']
      end
    else
      "Instagram - #{short_code}"
    end
  title
end

# The full size URL has been known to change without warning. See https://stackoverflow.com/questions/31302811/1080x1080-photos-via-instagram-api
# This grabs the URL from the new graphql results using a URL hack
# Takes the shortcode URL as an argument
def get_full_img_url(link)
  p link
  res = HTTParty.get("#{link}?__a=1")
  p res
  res.parsed_response['graphql']['shortcode_media']['display_url']
end

def image_vars(image)
  short_code = File.basename(image['link'])
  pub_date = DateTime.strptime(image['created_time'].to_s, '%s')
  vars = {
    short_code: short_code,
    pub_date: pub_date,
    dest_repo: repo(image['tags']),
    img_url: get_full_img_url(image['link']),
    title: nice_title(image, short_code),
    img_filename: "img/#{short_code}.jpg",
    post_filename: "_posts/#{pub_date.strftime('%F')}-#{short_code}.md"
  }

  vars.values
end

# New image in the last hour?
def new_image?(pub_date)
  return false if pub_date < DateTime.now - (2 / 24.0)

  true
end

def encode_image(url)
  tmpfile = Tempfile.new('photo')
  File.open(tmpfile, 'wb') do |f|
    resp = HTTParty.get(url, stream_body: true, follow_redirects: true)
    raise unless resp.success?

    f.write resp.body
  end
  Base64.encode64(tmpfile.read)
end

# :nocov:
#### All the action starts ####
if $PROGRAM_NAME == __FILE__
  begin
    tokens?

    instagram_images.each do |image|
      short_code,
      pub_date,
      dest_repo,
      img_url,
      title,
      img_filename,
      post_filename = image_vars(image)

      # Exit early if the image was posted over an hour ago
      unless new_image?(pub_date)
        puts 'Nothing new'.blue
        exit
      end

      print "#{short_code} => ".yellow + "#{dest_repo} => ".magenta
      # Skip if repo already has the photo - this is just a precaution
      if repo_has_post? dest_repo, short_code
        puts 'Skipped'.blue
        next
      end

      # Create the post
      rendered = render_template(
        pub_date: pub_date,
        title: title,
        short_code: short_code,
        image: image,
        dest_repo: dest_repo
      )
      post_content = Base64.encode64(rendered)

      add_files_to_repo dest_repo,
                        "#{post_filename}": post_content,
                        "#{img_filename}": encode_image(img_url)
      puts 'DONE'.green
    end
  rescue RuntimeError => e
    warn "Error: #{e}".red
    exit 1
  end
end
# :nocov:
