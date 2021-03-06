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

  # lazy mocking
  def encode_tokens(_key, _token, _expiry_date)
    { 'INSTAGRAM_TOKEN' => '654321', 'INSTAGRAM_TOKEN_EXPIRY' => '111111' }
  end

  def test_renew_insta_token
    # Unexpired token
    ENV['INSTAGRAM_TOKEN_EXPIRY'] = (Time.now + 360).to_i.to_s
    assert_equal 'Instragram token still valid.'.green, renew_insta_token('lildude/lildude.github.io')

    # Expired token
    ENV['INSTAGRAM_TOKEN_EXPIRY'] = (Time.now - 360).to_i.to_s
    stub_request(:get, /graph.instagram.com/)
      .to_return(
        status: 200, headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate({
                              access_token: '123456',
                              expires_in: '999999'
                            })
      )
    stub_request(:get, /api.github.com/)
      .to_return(
        body: JSON.generate({
                              key: 'c2VjcmV0LWtleQ==', # Base64.strict_encode64("secret-key")
                              key_id: '123-456'
                            })
      )

    stub_request(:put, /api.github.com/)
      .to_return(status: 204, headers: { 'Content-Type' => 'application/json', 'status' => '204' }, body: nil)
    assert renew_insta_token('lildude/lildude.github.io')
  end

  def test_instagram_images
    stub_request(:get, /graph.instagram.com/)
      .to_return(
        status: 200, headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate(
          data: [{
            caption: 'Image text is here',
            media_url: 'https://scontent.cdninstagram.com/pretend_url.jpg',
            timestamp: '2020-03-30T13:02:48+0000',
            permalink: 'https://www.instagram.com/p/B-W9b35JzZC/'
          }]
        )
      )
    res = instagram_images
    assert_equal res.length, 1
    assert_equal res[0]['media_url'], 'https://scontent.cdninstagram.com/pretend_url.jpg'
    assert_equal res[0]['timestamp'], '2020-03-30T13:02:48+0000'
    assert_equal res[0]['caption'], 'Image text is here'
    assert_equal res[0]['permalink'], 'https://www.instagram.com/p/B-W9b35JzZC/'
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
      tags: %w[tag1 tag2 run],
      pub_date: DateTime.parse('2017-08-31T22:24:48+00:00'),
      title: 'This is the title',
      image: {
        'caption' => 'Image text is here #anotag #tag1 #tag2',
        'permalink' => 'https://www.instagram.com/p/BYeY7yClLbk/'
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
    image = { 'caption' => '' }
    assert_equal 'Instagram - FOOOBAAR', nice_title(image, 'FOOOBAAR')
    image['caption'] = 'Image text is here'
    assert_equal 'Image text is here', nice_title(image, 'FOOOBAAR')
    image['caption'] = 'Image text is here and is very very very very long'
    assert_equal 'Image text is here and is very very…', nice_title(image, 'FOOOBAAR')
  end

  def test_image_vars
    image = { 'permalink' => 'https://www.instagram.com/p/BYeY7yClLbk/',
              'caption' => 'Image text is here #tag1 #tag2',
              'timestamp' => '2017-08-31T22:24:48+00:00',
              'tags' => %w[tag1 tag2],
              'media_url' => 'https://scontent.cdninstagram.com/pretend_url.jpg' }

    res = image_vars(image)
    assert_kind_of Array, res
    # Order is important
    assert_equal [
      %w[tag1 tag2],
      'BYeY7yClLbk',
      DateTime.parse('2017-08-31T22:24:48+00:00'),
      'lildude/colinseymour.co.uk',
      'https://scontent.cdninstagram.com/pretend_url.jpg',
      'Image text is here',
      'img/BYeY7yClLbk.jpg',
      '_posts/2017-08-31-image-text-is-here.md'
    ], res
  end

  def test_new_image
    assert new_image?(DateTime.now - (0.5 / 24.0))
    refute new_image?(DateTime.now - (2.5 / 24.0))
  end

  def test_slugify
    assert_equal 'this-is-text', slugify('This IS text')
    assert_equal 'this-is-text', slugify('this-is-text')
    assert_equal 'this-is-1234-no-emoji-or-punc', slugify('this is 🍎 1234 no Emoji ! or punc')
    assert_equal 'this-ends-in-emoji', slugify('tHis ends In emoji 🤡')
    assert_equal 'all-extra-spaces-removed', slugify('all  extra    spaces-removed')
    assert_equal 'no-dup-hyphens', slugify('no -🥵- dup hyphens')
    assert_equal 'no-triple-dots', slugify('no… triple … dots…')
    assert_equal 'no-hash-tags', slugify('no #hash tags')
  end

  def test_parse_hashtags
    assert_equal %w[tag1 tag2 tag3], parse_hashtags('This #tag1 this has #tag2 and ano #tag3')
  end

  def test_strip_hashtags
    assert_equal 'The EXTRA tags are Gone 👋', strip_hashtags('#tag1 The EXTRA #tag1 #tag2 tags are Gone 👋 #tag3')
  end

  def test_encode_image
    stub_request(:get, 'https://scontent.cdninstagram.com/pretend_url.jpg')
      .to_return(status: 200, body: File.open("#{File.dirname(__FILE__)}/fixtures/test.jpg"))

    expected = File.open("#{File.dirname(__FILE__)}/fixtures/test.jpg.base64").read
    assert_equal expected, encode_image('https://scontent.cdninstagram.com/pretend_url.jpg')
  end
end
