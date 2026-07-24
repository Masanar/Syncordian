defmodule Syncordian.BoundarySecretTest do
  @moduledoc """
  Tests for the per-run random boundary secret {κ⊥, κ⊤} (`def:adversary`,
  `theo:outsider`): the supervisor draws it at launch and distributes it out-of-band
  (`:persistent_term`); honest peers bake it into their boundary sentinel signatures, and
  it keys every admission authenticator. An outsider that does not hold the installed
  secret — even one that knows the public default pair — cannot mint an admissible
  message.

  These tests mutate the process-global `:persistent_term`, so they run `async: false`
  and restore the default pair afterwards.
  """
  use ExUnit.Case, async: false

  import Syncordian.Line_Object
  alias Syncordian.Byzantine

  @default_pair {"Infimum", "Supremum"}

  setup do
    on_exit(fn -> Byzantine.install_boundary_secret!(@default_pair) end)
    :ok
  end

  test "generate_boundary_secret/0 draws distinct, non-trivial halves each time" do
    {k_bot, k_top} = Byzantine.generate_boundary_secret()
    {k_bot2, k_top2} = Byzantine.generate_boundary_secret()

    assert k_bot != k_top
    assert {k_bot, k_top} != {k_bot2, k_top2}
    assert byte_size(k_bot) == 64 and byte_size(k_top) == 64
  end

  test "sentinel lines carry the installed secret as their stored signatures" do
    secret = {k_bot, k_top} = Byzantine.generate_boundary_secret()
    Byzantine.install_boundary_secret!(secret)

    assert get_signature(create_infimum_line(0, 3)) == k_bot
    assert get_signature(create_supremum_line(0, 3)) == k_top
  end

  test "an outsider without the installed secret cannot mint an admissible message" do
    secret = Byzantine.generate_boundary_secret()
    Byzantine.install_boundary_secret!(secret)

    payload = {{:path, [{1, 3}]}, "content", 3, "tag", [0, 0, 0], {3, 1}}

    # The attacker's best guesses: the public default pair (what the constants used to
    # be, i.e. the pre-fix vacuous case) and a random pair of its own.
    forged_with_default = Byzantine.create_admission(@default_pair, :ins, payload)

    forged_with_random =
      Byzantine.create_admission(Byzantine.generate_boundary_secret(), :ins, payload)

    refute Byzantine.check_admission(forged_with_default, secret, :ins, payload)
    refute Byzantine.check_admission(forged_with_random, secret, :ins, payload)

    # An admitted peer holding the installed secret still authenticates as usual.
    genuine = Byzantine.create_admission(secret, :ins, payload)
    assert Byzantine.check_admission(genuine, secret, :ins, payload)
  end
end
