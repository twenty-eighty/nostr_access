defmodule NostrAccessTest do
  use ExUnit.Case
  doctest NostrAccess

  test "version/0 returns the version" do
    version = NostrAccess.version()
    assert is_list(version)  # Application version is returned as a charlist
  end
end
