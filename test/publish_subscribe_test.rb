# frozen_string_literal: true

require_relative "helper"

class TestPublishSubscribe < Minitest::Test
  include Helper::Client

  class TestError < StandardError
  end

  def test_subscribe_and_unsubscribe
    @subscribed = false
    @unsubscribed = false

    wire = Wire.new do
      r.subscribe("foo") do |on|
        on.subscribe do |_channel, total|
          @subscribed = true
          @t1 = total
        end

        on.message do |_channel, message|
          if message == "s1"
            r.unsubscribe
            @message = message
          end
        end

        on.unsubscribe do |_channel, total|
          @unsubscribed = true
          @t2 = total
        end
      end
    end

    # Wait until the subscription is active before publishing
    Wire.pass until @subscribed

    Redis.new(OPTIONS).publish("foo", "s1")

    wire.join

    assert @subscribed
    assert_equal 1, @t1
    assert @unsubscribed
    assert_equal 0, @t2
    assert_equal "s1", @message
  end

  def test_psubscribe_and_punsubscribe
    @subscribed = false
    @unsubscribed = false

    wire = Wire.new do
      r.psubscribe("f*") do |on|
        on.psubscribe do |_pattern, total|
          @subscribed = true
          @t1 = total
        end

        on.pmessage do |_pattern, _channel, message|
          if message == "s1"
            r.punsubscribe
            @message = message
          end
        end

        on.punsubscribe do |_pattern, total|
          @unsubscribed = true
          @t2 = total
        end
      end
    end

    # Wait until the subscription is active before publishing
    Wire.pass until @subscribed

    Redis.new(OPTIONS).publish("foo", "s1")

    wire.join

    assert @subscribed
    assert_equal 1, @t1
    assert @unsubscribed
    assert_equal 0, @t2
    assert_equal "s1", @message
  end

  def test_pubsub_with_numpat_subcommand
    target_version("2.8.0") do
      @subscribed = false
      wire = Wire.new do
        r.psubscribe("f*") do |on|
          on.psubscribe { |_channel, _total| @subscribed = true }
          on.pmessage   { |_pattern, _channel, _message| r.punsubscribe }
        end
      end
      Wire.pass until @subscribed
      redis = Redis.new(OPTIONS)
      numpat_result = redis.pubsub(:numpat)

      redis.publish("foo", "s1")
      wire.join

      assert_equal redis.pubsub(:numpat), 0
      assert_equal numpat_result, 1
    end
  end

  def test_pubsub_with_channels_and_numsub_subcommnads
    target_version("2.8.0") do
      @subscribed = false
      wire = Wire.new do
        r.subscribe("foo") do |on|
          on.subscribe { |_channel, _total| @subscribed = true }
          on.message   { |_channel, _message| r.unsubscribe }
        end
      end
      Wire.pass until @subscribed
      redis = Redis.new(OPTIONS)
      channels_result = redis.pubsub(:channels)
      channels_result.delete('__sentinel__:hello')
      numsub_result = redis.pubsub(:numsub, 'foo', 'boo')

      redis.publish("foo", "s1")
      wire.join

      assert_equal channels_result, ['foo']
      assert_equal numsub_result, ['foo', 1, 'boo', 0]
    end
  end

  def test_subscribe_connection_usable_after_raise
    @subscribed = false

    wire = Wire.new do
      begin
        r.subscribe("foo") do |on|
          on.subscribe do |_channel, _total|
            @subscribed = true
          end

          on.message do |_channel, _message|
            raise TestError
          end
        end
      rescue TestError
      end
    end

    # Wait until the subscription is active before publishing
    Wire.pass until @subscribed

    Redis.new(OPTIONS).publish("foo", "s1")

    wire.join

    assert_equal "PONG", r.ping
  end

  def test_psubscribe_connection_usable_after_raise
    @subscribed = false

    wire = Wire.new do
      begin
        r.psubscribe("f*") do |on|
          on.psubscribe do |_pattern, _total|
            @subscribed = true
          end

          on.pmessage do |_pattern, _channel, _message|
            raise TestError
          end
        end
      rescue TestError
      end
    end

    # Wait until the subscription is active before publishing
    Wire.pass until @subscribed

    Redis.new(OPTIONS).publish("foo", "s1")

    wire.join

    assert_equal "PONG", r.ping
  end

  def test_subscribe_within_subscribe
    @channels = []

    wire = Wire.new do
      r.subscribe("foo") do |on|
        on.subscribe do |channel, _total|
          @channels << channel

          r.subscribe("bar") if channel == "foo"
          r.unsubscribe if channel == "bar"
        end
      end
    end

    wire.join

    assert_equal ["foo", "bar"], @channels
  end

  def test_return_within_subscribe
    @channels = []
    @subscribed_foo = false
    @subscribed_bar = false
    
    wire = Wire.new do
      def subscribe
        r.subscribe("foo") do |on|
          on.subscribe do |_channel, total|
            @subscribed_foo = true

            return
          end
        end
      end

      subscribe
      
      r.subscribe("bar") do |on|
        on.subscribe do |_channel, total|
          @subscribed_bar = true
        end

        on.message do |channel, message|
          @channels << channel

          r.unsubscribe if message == "s2"
        end
      end
    end
    
    # Wait until the subscription is active before publishing
    Wire.pass until (@subscribed_foo && @subscribed_bar)

    Redis.new(OPTIONS).publish("foo", "s1")
    Redis.new(OPTIONS).publish("bar", "s2")

    wire.join

    assert @subscribed_foo
    assert @subscribed_bar
    assert !@channels.include?("foo")
  end

  def test_other_commands_within_a_subscribe
    assert_raises Redis::CommandError do
      r.subscribe("foo") do |on|
        on.subscribe do |_channel, _total|
          r.set("bar", "s2")
        end
      end
    end
  end

  def test_subscribe_without_a_block
    assert_raises LocalJumpError do
      r.subscribe("foo")
    end
  end

  def test_unsubscribe_without_a_subscribe
    assert_raises RuntimeError do
      r.unsubscribe
    end

    assert_raises RuntimeError do
      r.punsubscribe
    end
  end

  def test_subscribe_past_a_timeout
    # For some reason, a thread here doesn't reproduce the issue.
    sleep = %(sleep 0.05)
    publish = %{ruby -rsocket -e 't=TCPSocket.new("127.0.0.1",#{OPTIONS[:port]});t.write("publish foo bar\\r\\n");t.read(4);t.close'}
    cmd = [sleep, publish].join('; ')

    IO.popen(cmd, 'r+') do |_pipe|
      received = false

      r.subscribe 'foo' do |on|
        on.message do |_channel, _message|
          received = true
          r.unsubscribe
        end
      end

      assert received
    end
  end

  def test_subscribe_with_timeout
    received = false

    assert_raises Redis::TimeoutError do
      r.subscribe_with_timeout(LOW_TIMEOUT, "foo") do |on|
        on.message do |_channel, _message|
          received = true
        end
      end
    end

    assert !received
  end

  def test_psubscribe_with_timeout
    received = false

    assert_raises Redis::TimeoutError do
      r.psubscribe_with_timeout(LOW_TIMEOUT, "f*") do |on|
        on.message do |_channel, _message|
          received = true
        end
      end
    end

    assert !received
  end
end
