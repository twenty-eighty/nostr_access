defmodule NostrAccessTest do
  use ExUnit.Case
  doctest NostrAccess

  test "version/0 returns the version" do
    version = NostrAccess.version()
    # Application version is returned as a charlist
    assert is_list(version)
  end
end
