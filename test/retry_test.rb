# frozen_string_literal: true

require_relative "test_helper"

class RetryTest < Minitest::Test
  UUID = /\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/

  def teardown
    @server&.stop
  end

  def client_for(responses, **options)
    @server = FakeServer.new(responses)
    Jobcelis::Client.new(api_key: "key", base_url: @server.url, retry_base_delay: 0.001, **options)
  end

  def ok(body = { "ok" => true })
    { status: 200, body: body }
  end

  def test_get_retries_503_until_success
    client = client_for([{ status: 503 }, { status: 503 }, ok("id" => "evt_1")])

    assert_equal({ "id" => "evt_1" }, client.get_event("evt_1"))
    assert_equal 3, @server.requests.size
  end

  def test_429_with_retry_after_is_retried
    client = client_for([{ status: 429, headers: { "Retry-After" => "0" } }, ok])

    assert_equal({ "ok" => true }, client.list_webhooks)
    assert_equal 2, @server.requests.size
  end

  def test_send_event_reuses_generated_idempotency_key
    client = client_for([{ status: 502 }, :drop, ok])

    client.send_event("order.created", { id: 1 })

    keys = @server.requests.map { |r| r.headers["x-idempotency-key"] }
    assert_equal 3, keys.size
    assert_match UUID, keys.first
    assert_equal [keys.first], keys.uniq
  end

  def test_send_event_keeps_caller_idempotency_key
    client = client_for([{ status: 503 }, ok])

    client.send_event("order.created", { id: 1 }, idempotency_key: "order-1")

    assert_equal %w[order-1 order-1], @server.requests.map { |r| r.headers["x-idempotency-key"] }
  end

  def test_batch_adds_missing_idempotency_keys_and_keeps_existing
    client = client_for([{ status: 503 }, ok])
    events = [{ topic: "a", payload: {} }, { topic: "b", payload: {}, idempotency_key: "mine" }]

    client.send_events(events)

    bodies = @server.requests.map { |r| JSON.parse(r.body)["events"] }
    assert_equal 2, bodies.size
    assert_equal bodies.first, bodies.last
    assert_match UUID, bodies.first[0]["idempotency_key"]
    assert_equal "mine", bodies.first[1]["idempotency_key"]
    refute events.first.key?(:idempotency_key), "caller's hash must not be modified"
  end

  def test_post_without_idempotency_key_is_not_retried_on_network_error
    client = client_for([:drop, ok])

    assert_raises(*Jobcelis::Client::NETWORK_ERRORS) { client.create_webhook(url: "https://example.com") }
    assert_equal 1, @server.requests.size
  end

  def test_post_without_idempotency_key_is_retried_on_503
    client = client_for([{ status: 503 }, ok])

    client.create_webhook(url: "https://example.com")
    assert_equal 2, @server.requests.size
  end

  def test_get_is_retried_on_network_error
    client = client_for([:drop, ok])

    client.get_event("evt_1")
    assert_equal 2, @server.requests.size
  end

  def test_max_retries_zero_makes_one_request
    client = client_for([{ status: 503 }, ok], max_retries: 0)

    error = assert_raises(Jobcelis::Error) { client.get_event("evt_1") }
    assert_equal 503, error.status
    assert_equal 1, @server.requests.size
  end

  def test_gives_up_after_max_retries_with_the_usual_error
    client = client_for(Array.new(4) { { status: 503, body: { error: "down" } } }, max_retries: 3)

    error = assert_raises(Jobcelis::Error) { client.get_event("evt_1") }
    assert_equal 503, error.status
    assert_equal "down", error.detail
    assert_equal 4, @server.requests.size
  end

  def test_non_retryable_statuses_are_not_retried
    [400, 500].each do |status|
      client = client_for([{ status: status, body: { error: "nope" } }, ok])

      error = assert_raises(Jobcelis::Error) { client.get_event("evt_1") }
      assert_equal status, error.status
      assert_equal 1, @server.requests.size
      @server.stop
    end
    @server = nil
  end

  def test_backoff_doubles_with_jitter_and_caps_at_30_seconds
    client = Jobcelis::Client.new(api_key: "key")

    assert_in_delta 1.0, client.send(:backoff_delay, 1), 0.2
    assert_in_delta 4.0, client.send(:backoff_delay, 3), 0.8
    assert_in_delta 30.0, client.send(:backoff_delay, 10), 6.0
  end
end
