require "test_helper"

# Authoring answers: docs/test-audits/handy-2348.md.
class WorkMap::SourceTest < ActiveSupport::TestCase
  include WorkMapTestHelper

  URL = "https://dedalo.example.test/work-map/v1"

  setup do
    @token_file = Tempfile.new("work-map-token").tap { |file| file.write("secreto-de-prueba\n"); file.close }
    @cache = ActiveSupport::Cache::MemoryStore.new
  end

  test "without an address and a token the source is not configured and asks nothing" do
    assert_equal "not_configured", WorkMap::Source.new.read.status
    assert_equal "not_configured", WorkMap::Source.new(url: URL).read.status
    assert_equal "not_configured", WorkMap::Source.new(token_file: @token_file.path).read.status
  end

  test "one authenticated GET reads every product" do
    request = stub_request(:get, URL).with(headers: { "Authorization" => "Bearer secreto-de-prueba", "Accept" => "application/json" })
      .to_return(status: 200, body: work_map_answer(products: [ work_map_product("alpha", boards(:writebook)) ]).to_json)

    result = source.read

    assert result.ok?
    assert_equal [ "alpha" ], result.snapshot.products.map { |product| product["id"] }
    assert_requested request, times: 1
  end

  test "the answer is shared for 30 seconds, then read again" do
    request = stub_request(:get, URL).to_return(status: 200, body: work_map_answer.to_json)

    3.times { source.read }
    assert_requested request, times: 1

    travel 31.seconds do
      source.read
    end
    assert_requested request, times: 2
  end

  test "a failure is a status with a short code, never an exception" do
    {
      "http_401" => -> { stub_request(:get, URL).to_return(status: 401) },
      "http_500" => -> { stub_request(:get, URL).to_return(status: 500, body: "boom") },
      "timeout" => -> { stub_request(:get, URL).to_timeout },
      "unreachable" => -> { stub_request(:get, URL).to_raise(Errno::ECONNREFUSED) },
      "invalid_json" => -> { stub_request(:get, URL).to_return(status: 200, body: "{") },
      "invalid_response" => -> { stub_request(:get, URL).to_return(status: 200, body: { "schema" => 9 }.to_json) },
      "too_large" => -> { stub_request(:get, URL).to_return(status: 200, body: " " * (WorkMap::Source::MAX_BYTES + 1)) }
    }.each do |code, stub|
      WebMock.reset!
      stub.call
      result = WorkMap::Source.new(url: URL, token_file: @token_file.path, cache: ActiveSupport::Cache::NullStore.new).read

      assert_equal [ "failed", code, nil ], [ result.status, result.error, result.snapshot ], code
    end
  end

  test "a missing token file fails without a request" do
    request = stub_request(:get, URL)

    result = WorkMap::Source.new(url: URL, token_file: "/nonexistent/token", cache: @cache).read

    assert_equal [ "failed", "missing_token" ], [ result.status, result.error ]
    assert_not_requested request
  end

  test "a failure is kept for 10 seconds so a broken source is not asked on every page" do
    request = stub_request(:get, URL).to_return(status: 503)

    2.times { source.read }
    assert_requested request, times: 1

    travel 11.seconds do
      source.read
    end
    assert_requested request, times: 2
  end

  test "the sample file source is for development and tests only" do
    path = work_map_file(work_map_answer)

    with_env("WORK_MAP_SOURCE_FILE" => path) do
      assert WorkMap::Source.default.read.ok?

      Rails.env.stubs(:local?).returns(false)
      assert_equal "not_configured", WorkMap::Source.default.read.status
    end
  end

  private
    def source
      WorkMap::Source.new(url: URL, token_file: @token_file.path, cache: @cache)
    end

    def with_env(values)
      previous = values.keys.to_h { |key| [ key, ENV[key] ] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| ENV[key] = value }
    end
end
