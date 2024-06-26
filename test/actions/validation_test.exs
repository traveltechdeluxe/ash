defmodule Ash.Test.Actions.ValidationTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Ash.Test.Domain, as: Domain

  defmodule Profile do
    @moduledoc false
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    actions do
      default_accept :*
      defaults [:read, :destroy, create: :*, update: :*]
    end

    validations do
      validate absent([:bio, :date]), on: :create
      validate present(:bio), on: :update
      validate absent(:date), on: :destroy

      validate one_of(:status, ["foo", "bar"])

      validate attribute_equals(:status, "foo") do
        where([attribute_equals(:foo, true)])
      end

      validate attribute_does_not_equal(:status, "foo"),
        where: attribute_equals(:foo, false)
    end

    attributes do
      uuid_primary_key :id

      attribute :bio, :string do
        public?(true)
      end

      attribute :date, :date do
        public?(true)
      end

      attribute :status, :string do
        public?(true)
      end

      attribute :foo, :boolean do
        public?(true)
      end
    end
  end

  test "validations run on create" do
    assert_raise(Ash.Error.Invalid, ~r/bio, date: must be absent/, fn ->
      Profile
      |> Ash.Changeset.for_create(:create, %{bio: "foobar"})
      |> Ash.create!()
    end)
  end

  test "validations only run when their when conditions validate properly" do
    Profile
    |> Ash.Changeset.for_create(:create, %{foo: false, status: "bar"})
    |> Ash.create!()

    Profile
    |> Ash.Changeset.for_create(:create, %{foo: true, status: "foo"})
    |> Ash.create!()

    assert_raise(Ash.Error.Invalid, ~r/status: must not equal foo/, fn ->
      Profile
      |> Ash.Changeset.for_create(:create, %{foo: false, status: "foo"})
      |> Ash.create!()
    end)

    assert_raise(Ash.Error.Invalid, ~r/status: must equal foo/, fn ->
      Profile
      |> Ash.Changeset.for_create(:create, %{foo: true, status: "bar"})
      |> Ash.create!()
    end)
  end

  test "validations run on update" do
    assert_raise(Ash.Error.Invalid, ~r/bio: must be present/, fn ->
      Profile
      |> Ash.Changeset.for_create(:create, %{})
      |> Ash.create!()
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.update!()
    end)
  end

  test "validations run on destroy" do
    assert_raise(Ash.Error.Invalid, ~r/date: must be absent/, fn ->
      Profile
      |> Ash.Changeset.for_create(:create, %{})
      |> Ash.create!()
      |> Ash.Changeset.for_update(:update, %{bio: "foo", date: Date.utc_today()})
      |> Ash.update!()
      |> Ash.destroy!()
    end)
  end

  describe "custom validations" do
    test "they can return exceptions" do
      assert {:error, _} =
               Profile
               |> Ash.Changeset.for_create(:create, %{status: "baz"})
               |> Ash.create()
    end

    test "they can return exceptions inside of embedded resources" do
      assert {:error, _} =
               Profile
               |> Ash.Changeset.for_create(:create, %{embedded: %{name: "thing"}})
               |> Ash.create()
    end

    test "they can return exceptions inside of embedded lists" do
      assert {:error, _error} =
               Profile
               |> Ash.Changeset.for_create(:create, %{embedded_list: [%{name: "thing"}]})
               |> Ash.create()
    end
  end

  describe "one_of" do
    test "it succeeds if the value is in the list" do
      Profile
      |> Ash.Changeset.for_create(:create, %{status: "foo"})
      |> Ash.create!()
    end

    test "it fails if the value is not in the list" do
      assert_raise(Ash.Error.Invalid, ~r/expected one of foo, bar/, fn ->
        Profile
        |> Ash.Changeset.for_create(:create, %{status: "blart"})
        |> Ash.create!()
      end)
    end
  end
end
