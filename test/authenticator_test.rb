require_relative "test_helper"

# The base class, the factory protocol and the request-local current
# authenticator the wrappers read.
class AuthenticatorTest < Minitest::Test
  include Rack::Test::Methods

  def setup
    @repository = Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)
  end

  def test_the_base_class_lets_everyone_read_and_nobody_write
    anonymous = Paquette::Authenticator.new(nil)
    assert_nil anonymous.token
    assert anonymous.read_permitted?
    refute anonymous.write_permitted?
    assert_raises(Paquette::OtpRejected) { anonymous.check_otp!("123456") }
    refute anonymous.respond_to?(:entitled?)
    refute anonymous.respond_to?(:identity)
    refute anonymous.respond_to?(:personalization)
  end

  def test_the_class_is_its_own_factory
    instance = Paquette::Authenticator.call("tok")
    assert_kind_of Paquette::Authenticator, instance
    assert_equal "tok", instance.token
  end

  def test_open_writes_and_takes_any_code
    open = Paquette::Authentication::Open.new("x")
    assert open.read_permitted?
    assert open.write_permitted?
    assert_nil open.check_otp!("000000")
  end

  def test_with_makes_an_authenticator_current_for_the_block_and_restores_the_previous_one
    outer = Paquette::Authenticator.new("outer")
    inner = Paquette::Authenticator.new("inner")

    assert_nil Paquette::Authenticator.current
    Paquette::Authenticator.with(outer) do
      assert_same outer, Paquette::Authenticator.current
      Paquette::Authenticator.with(inner) { assert_same inner, Paquette::Authenticator.current }
      assert_same outer, Paquette::Authenticator.current
    end
    assert_nil Paquette::Authenticator.current
  end

  def test_with_restores_the_previous_one_when_the_block_raises
    assert_raises(RuntimeError) do
      Paquette::Authenticator.with(Paquette::Authenticator.new("x")) { raise "boom" }
    end
    assert_nil Paquette::Authenticator.current
  end

  def test_the_current_authenticator_is_fiber_local
    Paquette::Authenticator.with(Paquette::Authenticator.new("here")) do
      assert_nil Fiber.new { Paquette::Authenticator.current }.resume
      assert_nil Thread.new { Paquette::Authenticator.current }.value
    end
  end

  def test_the_server_builds_one_instance_per_request_leaves_it_in_the_env_and_makes_it_current
    seen = []
    factory = Class.new(Paquette::Authenticator) do
      define_method(:read_permitted?) do
        seen << [:read, token, Paquette::Authenticator.current]
        true
      end
    end
    server = Paquette::GemServer.new(@repository, authenticator: factory)

    env = Rack::MockRequest.env_for("/names", "HTTP_AUTHORIZATION" => "tok-1")
    status, = server.call(env)

    assert_equal 200, status
    assert_kind_of factory, env["paquette.authenticator"]
    assert_equal "tok-1", env["paquette.authenticator"].token
    # Not current while the authenticator itself is asked, only while the handler runs
    assert_equal [[:read, "tok-1", nil]], seen
    assert_nil Paquette::Authenticator.current
  end

  def test_the_server_keeps_an_authenticator_already_in_the_env
    mine = Paquette::Authenticator.new("mine")
    env = Rack::MockRequest.env_for("/names", "HTTP_AUTHORIZATION" => "other")
    env["paquette.authenticator"] = mine
    Paquette::GemServer.new(@repository, authenticator: Paquette::Authenticator).call(env)

    assert_same mine, env["paquette.authenticator"]
  end

  def test_a_lambda_is_a_factory_too
    tokens = []
    server = Paquette::GemServer.new(@repository, authenticator: ->(token) {
      tokens << token
      Paquette::Authenticator.new(token)
    })
    server.call(Rack::MockRequest.env_for("/names"))
    server.call(Rack::MockRequest.env_for("/names", "HTTP_AUTHORIZATION" => "Bearer t"))

    assert_equal [nil, "t"], tokens
  end

  def test_an_instance_instead_of_a_factory_is_refused_when_the_server_is_built
    error = assert_raises(ArgumentError) do
      Paquette::GemServer.new(@repository, authenticator: Paquette::Authentication::Open.new(nil))
    end
    assert_includes error.message, "call(token)"
  end

  def test_the_current_authenticator_is_the_requests_while_the_repository_is_read
    currents = []
    repository = Class.new(SimpleDelegator) do
      define_method(:gem_names) do
        currents << Paquette::Authenticator.current&.token
        super()
      end
    end.new(@repository)
    server = Paquette::GemServer.new(repository, authenticator: Paquette::Authenticator)

    server.call(Rack::MockRequest.env_for("/names", "HTTP_AUTHORIZATION" => "Bearer abc"))

    assert_equal ["abc"], currents
    assert_nil Paquette::Authenticator.current
  end

  def test_a_gate_goes_on_only_when_the_authenticator_answers_entitled
    plain = Paquette::GemServer.new(@repository, authenticator: Paquette::Authenticator)
    gated = Paquette::GemServer.new(@repository, authenticator: EntitlingAuthenticator.gating { |name:, version: nil| name == "zip_kit" })

    assert_equal "---\nminuscule_test\nzip_kit\n", Rack::MockRequest.new(plain).get("/names").body
    assert_equal "---\nzip_kit\n", Rack::MockRequest.new(gated).get("/names").body
  end
end
