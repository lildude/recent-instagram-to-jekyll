# frozen_string_literal: true

require 'simplecov'
require 'coveralls'
SimpleCov.formatters = [
  SimpleCov::Formatter::HTMLFormatter,
  Coveralls::SimpleCov::Formatter
]
SimpleCov.start do
  add_filter 'vendor'
end

require 'minitest/autorun'
require 'webmock/minitest'
require 'date'
require 'open3'
require_relative '../create_post'

ENV['RACK_ENV'] ||= 'test'

# rubocop:disable Metrics/ClassLength
# rubocop:disable Metrics/MethodLength
class TestRelease < Minitest::Test
  def test_tokens
    exception = assert_raises(RuntimeError) { tokens? }
    assert_match 'Missing auth env vars for tokens', exception.message

    ENV['INSTAGRAM_TOKEN'] = '1234567890'
    ENV['GITHUB_TOKEN'] = '0987654321'
    assert tokens?
  end

  def test_client
    ENV['GITHUB_TOKEN'] = '0987654321'
    assert_kind_of Octokit::Client, client
    assert_kind_of Octokit::Client, @client
    assert_equal '0987654321', client.access_token
  end

  def test_repo
    assert_equal 'lildude/gonefora.run', repo(%w[tag1 run])
    assert_equal 'lildude/lildude.co.uk', repo(%w[tag1 tech])
    assert_equal 'lildude/colinseymour.co.uk', repo(%w[tag1 tag2])
    assert_equal 'lildude/colinseymour.co.uk', repo([])
  end

  def test_repo_has_post
    stub_request(:get, /api.github.com/)
      .to_return(
        { status: 200, headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate(total_count: 1) },
        status: 200, headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate(total_count: 0)
      )
    assert repo_has_post?('lildude/lildude.github.io', 'BAARFOOO')
    refute repo_has_post?('lildude/lildude.github.io', 'FOOOBAAR')
  end

  def test_instagram_images
    stub_request(:get, /api.instagram.com/)
      .to_return(
        status: 200, headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate(
          data: [{
            images: {
              standard_resolution: { url: 'https://scontent.cdninstagram.com/pretend_url.jpg' }
            },
            created_time: '1504218288',
            caption: { text: 'Image text is here' }
          }]
        )
      )
    res = instagram_images
    assert_equal res.length, 1
    assert_equal res[0]['images']['standard_resolution']['url'], 'https://scontent.cdninstagram.com/pretend_url.jpg'
    assert_equal res[0]['created_time'], '1504218288'
    assert_equal res[0]['caption']['text'], 'Image text is here'
  end

  def test_add_files_to_repox
    stub_request(:any, /api.github.com/)
      .to_return(
        { status: 200, headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate(object: { sha: 'abc1234567890xyz' }) },
        { status: 200, headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate(commit: { tree: { sha: 'abc1234567890xyz' } }) },
        { status: 200, headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate(sha: 'abc1234567890xyz') },
        { status: 200, headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate(sha: 'abc1234567890xyz') },
        status: 200, headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate(
          url: 'https://api.github.com/repos/lildude.github.io/git/refs/heads/master',
          object: { sha: 'abc1234567890xyz' }
        )
      )

    files = {
      '_posts/2010-01-14-FOOOBAAR.md': 'TVkgU0VDUkVUIEhBUyBCRUVOIFJFVkVBTEVEIPCfmJw=',
      'img/FOOOBAAR.jpg': '8J+YnCBTVE9QIFNURUFMSU5HIE1ZIFNFQ1JFVFM='
    }
    assert res = add_files_to_repo('lildude/lildude.github.io', files)
    assert_equal res['object']['sha'], 'abc1234567890xyz'
  end

  def test_render_template
    locals = {
      pub_date: DateTime.strptime('1504218288', '%s'),
      title: 'This is the title',
      image: {
        'caption' => {
          'text' => 'Image text is here #anotag #tag1 #tag2'
        },
        'link' => 'https://www.instagram.com/p/BYeY7yClLbk/',
        'tags' => %w[tag1 tag2 run]
      },
      short_code: 'FOOOBAAR',
      dest_repo: 'lildude/lildude.github.io'
    }

    rendered = render_template(locals)
    assert_match 'date: 2017-08-31 22:24:48 +0000', rendered
    assert_match 'title: "This is the title"', rendered
    assert_match '- instagram', rendered
    assert_match 'instagram_url: https://www.instagram.com/p/BYeY7yClLbk/', rendered
    assert_match '![Instagram - FOOOBAAR](https://lildude.github.io/img/FOOOBAAR.jpg){:loading="lazy"}{: .u-photo}', rendered
    assert_match 'Image text is here', rendered
    refute_match 'Image text is here #anotag', rendered
    refute_match 'notag', rendered
    refute_match '#tag1 #tag2', rendered
    refute_match 'tag1 tag2', rendered
  end

  def test_nice_title
    image = { 'caption' => { 'text': '' } }
    assert_equal 'Instagram - FOOOBAAR', nice_title(image, 'FOOOBAAR')
    image['caption']['text'] = 'Image text is here'
    assert_equal 'Image text is here', nice_title(image, 'FOOOBAAR')
    image['caption']['text'] = 'Image text is here and is very very very very long'
    assert_equal 'Image text is here and is very very…', nice_title(image, 'FOOOBAAR')
  end

  def test_image_vars
    # Only stub the info we need
    body = {
      "graphql": {
        "shortcode_media": {
          "display_url": 'https://scontent.cdninstagram.com/pretend_url.jpg'
        }
      }
    }.to_json

    stub_request(:get, 'https://www.instagram.com/p/BYeY7yClLbk/?__a=1')
      .with(
        headers: {
          'Accept' => '*/*',
          'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
          'User-Agent' => 'Ruby'
        }
      )
      .to_return(status: 200, body: body, headers: { 'Content-Type' => 'application/json' })

    image = { 'link' => 'https://www.instagram.com/p/BYeY7yClLbk/',
              'caption' => { 'text' => 'Image text is here' },
              'created_time' => '1504218288',
              'tags' => %w[tag1 tag2],
              'images' => {
                'standard_resolution' => {
                  'url' => 'https://scontent.cdninstagram.com/pretend_url.jpg'
                }
              } }

    res = image_vars(image)
    assert_kind_of Array, res
    # Order is important
    assert_equal [
      'BYeY7yClLbk',
      DateTime.strptime('1504218288', '%s'),
      'lildude/colinseymour.co.uk',
      'https://scontent.cdninstagram.com/pretend_url.jpg',
      'Image text is here',
      'img/BYeY7yClLbk.jpg',
      '_posts/2017-08-31-BYeY7yClLbk.md'
    ], res
  end

  def test_new_image
    assert new_image?(DateTime.now - (0.5 / 24.0))
    refute new_image?(DateTime.now - (2.5 / 24.0))
  end

  def test_encode_image
    stub_request(:get, 'https://scontent.cdninstagram.com/pretend_url.jpg')
      .to_return(status: 200, body: File.open("#{File.dirname(__FILE__)}/fixtures/test.jpg"))

    expected = File.open("#{File.dirname(__FILE__)}/fixtures/test.jpg.base64").read
    assert_equal expected, encode_image('https://scontent.cdninstagram.com/pretend_url.jpg')
  end
end
# rubocop:enable Metrics/ClassLength
# rubocop:enable Metrics/MethodLength
