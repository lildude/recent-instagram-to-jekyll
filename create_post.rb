#!/usr/bin/env ruby
# frozen_string_literal: true

# Quick hacky script to get all my instagram images and create posts from them.
require 'base64'
require 'colorize'
require 'date'
require 'erb'
require 'httparty'
require 'json'
require 'octokit'
require 'rbnacl'
require 'tempfile'

TEMPLATE = <<~TEMPLATE
  ---
  layout: photo
  date: <%= pub_date.strftime("%F %T %z") %>
  title: "<%= title.gsub(/[".]/, '') %>"
  type: post
  tags:
  - instagram
  <% unless tags.empty? -%>
  <% tags.each do |tag| -%>
  <% unless %w[run tech].include?(tag) -%>
  - <%= tag %>
  <% end -%>
  <% end -%>
  <% end -%>
  instagram_url: <%= image['permalink'] %>
  ---

  ![Instagram - <%= short_code %>](https://<%= dest_repo.split('/').last %>/img/<%= short_code %>.jpg){:loading="lazy"}{: .u-photo}

  <%= image['caption'].gsub(/\\B#\\w+/, '') %>
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

# Instagram long-lived tokens are only valid for 60 days but are easily renewed.
# This renews the token ~7 days before expiring and updates the repo secrets with the
# new token and expiry date (now + 53 days)
def renew_insta_token(repo)
  expiry_date = ENV['INSTAGRAM_TOKEN_EXPIRY'].to_i
  now = Time.now
  # Return early if nothing to do
  return 'Instragram token still valid.'.green if expiry_date > now.to_i

  res = HTTParty.get("https://graph.instagram.com/refresh_access_token?grant_type=ig_refresh_token&access_token=#{ENV['INSTAGRAM_TOKEN']}")
  # Return early if we hit a problem
  return puts "Problem refreshing Instagram token: #{res.parsed_response['error']['message']}".red if res.parsed_response['error']

  new_instagram_token = res.parsed_response['access_token']
  new_expiry_date = (now + res.parsed_response['expires_in'].to_i - 604_800).to_s # new date = now + 'expire_in' - 7 days

  # Octokit doesn't have support for Action API yet, so we need to do this manually - https://github.com/octokit/octokit.rb/issues/1216
  res = HTTParty.get("https://api.github.com/repos/#{repo}/actions/secrets/public-key", headers: { 'Authorization': "token #{ENV['GITHUB_TOKEN']}" })
  key = Base64.decode64(res.parsed_response['key'])
  key_id = res.parsed_response['key_id']
  public_key = RbNaCl::PublicKey.new(key)
  box = RbNaCl::Boxes::Sealed.from_public_key(public_key)

  tokens = {}
  tokens['INSTAGRAM_TOKEN'] = Base64.strict_encode64(box.encrypt(new_instagram_token))
  tokens['INSTAGRAM_TOKEN_EXPIRY'] = Base64.strict_encode64(box.encrypt(new_expiry_date))

  tokens.each do |secret, value|
    res = HTTParty.put(
      "https://api.github.com/repos/#{repo}/actions/secrets/#{secret}",
      body: { encrypted_value: value, key_id: key_id }.to_json,
      headers: { 'Authorization': "token #{ENV['GITHUB_TOKEN']}" }
    )

    if res.response.header['status'] !~ /^20[14]/
      puts "Problem updating GitHub secret #{secret}: #{res.response.header['status']}".red
    else
      puts "Updated GitHub secret #{secret}".blue
    end
  end
end

def instagram_images
  res = HTTParty.get("https://graph.instagram.com/me/media?fields=caption,media_type,media_url,timestamp,permalink&access_token=#{ENV['INSTAGRAM_TOKEN']}")
  if res.parsed_response['error']
    puts "Whoops: #{res.parsed_response['error']['message']}".red
    exit 1
  end
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
  title = if image['caption'] && !image['caption'].empty?
            if image['caption'].split.size > 8
              "#{image['caption'].split[0...8].join(' ')}…"
            else
              image['caption']
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
  res = HTTParty.get("#{link}?__a=1")
  res.parsed_response['graphql']['shortcode_media']['display_url']
end

def image_vars(image)
  short_code = File.basename(image['permalink'])
  pub_date = DateTime.parse(image['timestamp'])
  tags = image['caption'].scan(/\B#(\w+)/).flatten
  vars = {
    tags: tags,
    short_code: short_code,
    pub_date: pub_date,
    dest_repo: repo(tags),
    img_url: image['media_url'],
    title: nice_title(image, short_code),
    img_filename: "img/#{short_code}.jpg",
    post_filename: "_posts/#{pub_date.strftime('%F')}-#{short_code}.md"
  }

  vars.values
end

# New image in the last two hours?
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
      tags,
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
        tags: tags,
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

      # Check the token before we're done
      renew_insta_token(dest_repo)

      puts 'DONE'.green
    end
  rescue RuntimeError => e
    warn "Error: #{e}".red
    exit 1
  end
end
# :nocov:
