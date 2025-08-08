defmodule Nostr.FilterTest do
  use ExUnit.Case

  describe "validate!/1" do
    test "validates and canonicalizes a basic filter" do
      filter = %{kinds: [2, 1], authors: ["pubkey2", "pubkey1"]}
      result = Nostr.Filter.validate!(filter)

      assert result == %{authors: ["pubkey1", "pubkey2"], kinds: [1, 2]}
    end

    test "validates time fields" do
      filter = %{since: 1234567890, until: 1234567899}
      result = Nostr.Filter.validate!(filter)

      assert result == %{since: 1234567890, until: 1234567899}
    end

    test "validates limit field" do
      filter = %{limit: 100}
      result = Nostr.Filter.validate!(filter)

      assert result == %{limit: 100}
    end

    test "validates custom tag filters" do
      filter = %{"#e" => ["event1", "event2"]}
      result = Nostr.Filter.validate!(filter)

      assert result == %{"#e" => ["event1", "event2"]}
    end

    test "raises error for invalid filter type" do
      assert_raise ArgumentError, "Filter must be a map, got: \"not a map\"", fn ->
        Nostr.Filter.validate!("not a map")
      end
    end

    test "raises error for invalid ids field" do
      assert_raise ArgumentError, "Filter :ids must be a list of strings", fn ->
        Nostr.Filter.validate!(%{ids: [1, 2, 3]})
      end
    end

    test "raises error for invalid authors field" do
      assert_raise ArgumentError, "Filter :authors must be a list of strings", fn ->
        Nostr.Filter.validate!(%{authors: [1, 2, 3]})
      end
    end

    test "accepts string kinds by coercing to integers" do
      result = Nostr.Filter.validate!(%{kinds: ["2", "1"]})
      assert result == %{kinds: [1, 2]}
    end

    test "raises error for invalid kinds items" do
      assert_raise ArgumentError, "Filter :kinds must be a list of integers", fn ->
        Nostr.Filter.validate!(%{kinds: ["a", 1.2]})
      end
    end

    test "raises error for invalid limit field" do
      assert_raise ArgumentError, "Filter :limit must be a positive integer, got: 0", fn ->
        Nostr.Filter.validate!(%{limit: 0})
      end
    end

    test "raises error for invalid limit field type" do
      assert_raise ArgumentError, "Filter :limit must be a positive integer, got: \"100\"", fn ->
        Nostr.Filter.validate!(%{limit: "100"})
      end
    end
  end

  test "canonicalization is idempotent" do
    filter = %{kinds: [2, 1], authors: ["pubkey2", "pubkey1"]}
    result1 = Nostr.Filter.validate!(filter)
    result2 = Nostr.Filter.validate!(result1)
    assert result1 == result2
  end
end
