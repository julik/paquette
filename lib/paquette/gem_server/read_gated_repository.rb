require "delegate"
require "measurometer"

# Wraps a gem repository and filters every read through an entitler block.
# The block receives `name:` (and optionally `version:`) and returns truthy
# when the caller is allowed to see that gem/version. Non-entitled gems
# disappear from listings, return nil paths, and report as non-existent.
#
# Writes (add_gem, yank_gem) always raise WriteNotAllowed. Gating a read
# path implies the caller is not the right party to mutate the corpus —
# if you want a more nuanced story (e.g. read-gated but write-allowed
# for authenticated admins), write a different wrapper with its own
# policy. This one is deliberately opinionated: gating reads blocks
# writes, full stop.
class Paquette::GemServer::ReadGatedRepository < Paquette::GemServer::ReadonlyRepository
  # `gate_key:` is what this gate is called, for HTTP caching, and it is
  # the caller's to supply because nothing here can work it out.
  #
  # The gate is a block. Two blocks that select different gems are two
  # different views of the corpus, and nothing about a Proc — not its
  # source location, not its identity, which is fresh on every request
  # when the stack is built per-request as the README recommends — tells
  # you which view it produces. It closes over a licensee, and only the
  # caller knows who.
  #
  # So: pass the identity of whoever the entitler will consult, and pass
  # everything about them the answers depend on. A licensee id is usually
  # it; if entitlements can change without the id changing, the key has
  # to move when they do (append the licensee's updated_at, or a version
  # counter on their entitlement set), or a client keeps a 304 for a gem
  # it is no longer allowed to have.
  #
  # Leave it out and this repository reports no validator at all, which
  # makes the whole stack above it report none, which makes the server
  # emit no ETag and serve every request in full. That is the intended
  # default: an absent key is indistinguishable from "every licensee is
  # the same licensee", and a wrong ETag on a gated index hands one
  # customer another customer's entitlements. Slow is recoverable.
  def initialize(repository, gate_key: nil, &entitler)
    super(repository)
    @entitler = entitler
    @gate_key = gate_key
  end

  # nil without a gate_key — see above. derive_validator does the
  # refusing, so this reads the same as any other layer.
  def cache_validator
    inner = Paquette::GemServer::GemRepository.cache_validator_of(__getobj__)
    Paquette::GemServer::GemRepository.derive_validator(inner, "read-gate", @gate_key)
  end

  # A gate is a block, and it may decide by something Paquette never sees
  # - an IP, a header, the time of day - so even two anonymous callers can
  # be handed different views. Never `public`, whatever it wraps.
  def varies_by_caller?
    true
  end

  # Asked through the class method rather than with `super` so that an
  # inner repository predating this protocol answers nil instead of
  # raising NoMethodError out of Delegator#method_missing.
  def gem_checksum(gem_name, version)
    return nil unless entitled?(name: gem_name, version: version)

    Paquette::GemServer::GemRepository.gem_checksum_of(__getobj__, gem_name, version)
  end

  def gem_names
    super.select { |name| entitled?(name: name) }
  end

  def gem_versions
    super.select do |gem_name, version|
      entitled?(name: gem_name, version: version)
    end
  end

  def versions_for_gem(gem_name)
    return [] unless entitled?(name: gem_name)
    super.select do |version|
      entitled?(name: gem_name, version: version)
    end
  end

  def gem_file_path(gem_name, version)
    if entitled?(name: gem_name, version: version)
      super
    end
  end

  def compact_info(gem_name)
    return [] unless entitled?(name: gem_name)

    all_info = super
    return all_info unless all_info.is_a?(Array)

    all_info.select do |line|
      version = line.split(" ")[0]
      entitled?(name: gem_name, version: version)
    end
  end

  def gem_exists?(gem_name, version)
    if entitled?(name: gem_name, version: version)
      super
    else
      false
    end
  end

  # The entitler is the caller's, and a listing calls it once per gem in
  # the corpus — an entitler that reaches for a database on every call is
  # the usual reason a gated index is slower than an ungated one, and this
  # is where that shows up.
  def entitled?(**criteria)
    Measurometer.instrument("paquette.gem_read_gate.entitled") { @entitler.call(**criteria) }
  end
end
