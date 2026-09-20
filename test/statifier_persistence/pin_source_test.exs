defmodule StatifierPersistence.PinSourceTest do
  use ExUnit.Case, async: true

  alias StatifierPersistence.PinSource

  alias StatifierPersistence.Test.{
    AddressPinSource,
    MalformedPinSource,
    RefusingPinSource,
    TimerQueuePinSource
  }

  @hash AddressPinSource.addressed_hash()
  @context %{execution_ids: ["exec_impression_01J2", "exec_impression_01J3"]}

  # sabotage: made collect/3 seed its reduction with the first source's counts
  # instead of %{} -> red (an empty list raised instead of answering {:ok, %{}})
  test "an empty source list answers an empty map" do
    assert PinSource.collect([], @hash, @context) == {:ok, %{}}
  end

  # sabotage: made collect/3 merge each source's counts into one flat map
  # instead of keying them by module -> red (the two sources' counts collapsed
  # into a single map and both module keys disappeared)
  test "two sources are reported under their own module names" do
    assert {:ok, collected} =
             PinSource.collect([TimerQueuePinSource, AddressPinSource], @hash, @context)

    assert collected == %{
             TimerQueuePinSource => %{pending_timers: 2},
             AddressPinSource => %{addresses: 1}
           }
  end

  # sabotage: dropped the context match in TimerQueuePinSource.pins/2 and
  # returned a constant -> red (the count stopped following the ids handed in)
  test "a source answers from the execution ids it is handed, not the hash" do
    assert {:ok, %{TimerQueuePinSource => %{pending_timers: 0}}} =
             PinSource.collect([TimerQueuePinSource], @hash, %{execution_ids: []})
  end

  # sabotage: removed the `rescue` clause from collect/3's ask -> red (the
  # raise escaped instead of being reported as a refusal)
  test "a raising source is an error naming the module, never a zero" do
    assert {:error, {RefusingPinSource, {:raised, exception}}} =
             PinSource.collect([RefusingPinSource], @hash, @context)

    assert Exception.message(exception) =~ "unreachable"
  end

  # sabotage: made ask/3 accept any return value -> red (the keyword list came
  # back as {:ok, ...} where it must be an error)
  test "a malformed return is an error naming the module, never a zero" do
    assert PinSource.collect([MalformedPinSource], @hash, @context) ==
             {:error, {MalformedPinSource, {:invalid_return, [pending_timers: 3]}}}
  end

  # sabotage: replaced reduce_while with reduce so the walk continued past a
  # failure -> red (the refusal was overwritten by the later source's counts)
  test "the first failing source stops the walk and no later count is reported" do
    assert PinSource.collect(
             [RefusingPinSource, TimerQueuePinSource],
             @hash,
             @context
           ) ==
             {:error,
              {RefusingPinSource,
               {:raised, %RuntimeError{message: "the timer queue is unreachable"}}}}
  end

  # sabotage: dropped the `count >= 0` clause from valid_counts?/1 -> red (a
  # negative count was reported as a pin count instead of a refusal)
  test "a negative count is a malformed return" do
    defmodule NegativePinSource do
      @moduledoc false
      def pins(_content_hash, _context), do: %{pending_timers: -1}
    end

    assert PinSource.collect([NegativePinSource], @hash, @context) ==
             {:error, {NegativePinSource, {:invalid_return, %{pending_timers: -1}}}}
  end

  # sabotage: removed the `@callback pins/2` declaration -> red (the double no
  # longer had a behaviour to be conformant against)
  test "the behaviour declares exactly the pins/2 callback" do
    assert PinSource.behaviour_info(:callbacks) == [pins: 2]
  end
end
