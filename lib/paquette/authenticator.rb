# Who is asking, for the one request: built from the token by the server, kept
# in the Rack env, and asked by everything in the stack that cares who the
# caller is - the server for reads, writes and the one-time password, the gate
# for what the caller may see, the personalizer for what gets written into
# their packages, the response cache for whose entries these are.
#
# Subclass it and answer the questions out of the token. The instance lives for
# one request, so whatever the token resolves to can be remembered on it:
#
#   class AcmeAuthenticator < Paquette::Authenticator
#     def license = @license ||= License.find_by(token: token)
#
#     def read_permitted? = !license.nil?
#     def write_permitted? = !!license&.publisher?
#     def check_otp!(code) = Paquette::Totp.verify!(license.totp_secret, code)
#     def entitled?(name:, version: nil) = license.gem_names.include?(name)
#     def identity = license.cache_key
#     def personalization = {"licensee" => license.holder_name}
#   end
#
#   Paquette::GemServer.new(repo, authenticator: AcmeAuthenticator)
#
# The server takes the class - anything answering `call(token)` with an
# instance will do, a lambda included - and calls it once per request with
# the token Paquette::AuthToken read, or nil when the caller sent no
# credentials. The three questions below are always asked. Three more are
# optional, and asked only when the instance answers to them:
#
#   entitled?(name:, version: nil)  # the gate: may this caller see this package, or
#                                   # this version of it? Absent, they see everything
#   identity                        # for Paquette::ResponseCache: a String or Integer
#                                   # naming who the token belongs to, so entries
#                                   # survive a rotation. Absent or nil, nothing is cached
#   personalization                 # a Hash of String values written into every
#                                   # package that carries a marker for one - see the
#                                   # Personalizers. Absent or nil, vanilla bytes
#
# A gate goes on the server's repository for every request whose authenticator
# answers `entitled?`, so there is nothing to wire for one.
class Paquette::Authenticator
  # Where the server leaves the instance for the application's own code - an
  # `on_publish:` hook, a log line - to find.
  #
  # @return [String]
  ENV_KEY = "paquette.authenticator"

  # @return [Symbol]
  CURRENT_KEY = :paquette_authenticator

  # The factory protocol: the class is its own factory.
  #
  # @param token [String, nil]
  # @return [Paquette::Authenticator]
  def self.call(token)
    new(token)
  end

  # The authenticator of the request being served, for the repository
  # wrappers, which have no env to read it out of. Set by the server for the
  # duration of its handler, and by {with} anywhere else.
  #
  # @return [Paquette::Authenticator, nil]
  def self.current
    Thread.current[CURRENT_KEY]
  end

  # Makes `authenticator` current for the block - how a repository stack is
  # asked about one caller outside a request, a download link on a license
  # page say. Fiber-local, so two requests on one thread cannot see each other.
  #
  # @param authenticator [Paquette::Authenticator, nil]
  # @yield
  # @return [Object] what the block returned
  def self.with(authenticator)
    previous = Thread.current[CURRENT_KEY]
    Thread.current[CURRENT_KEY] = authenticator
    yield
  ensure
    Thread.current[CURRENT_KEY] = previous
  end

  # @return [String, nil] the token the request carried, nil for none
  attr_reader :token

  # @param token [String, nil]
  def initialize(token)
    @token = token
  end

  # Everyone reads: the default for a server built without an authenticator.
  #
  # @return [Boolean]
  def read_permitted?
    true
  end

  # Nobody writes.
  #
  # @return [Boolean]
  def write_permitted?
    false
  end

  # No secret to check against, so no code is good.
  #
  # @param code [String] the one-time password the write carried, never empty
  # @raise [Paquette::OtpRejected]
  # @return [void]
  def check_otp!(code)
    raise Paquette::OtpRejected
  end
end
