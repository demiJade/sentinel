defmodule Html.UserControllerTest do
  use Sentinel.ConnCase

  alias Mix.Config
  alias Sentinel.Changeset.AccountUpdater
  alias Sentinel.Changeset.Confirmator
  alias Sentinel.Changeset.PasswordResetter
  alias Sentinel.Changeset.Registrator
  alias GuardianDb.Token

  @password "secret"

  setup do
    on_exit fn ->
      Application.delete_env :sentinel, :user_model_validator
      Config.persist([sentinel: [confirmable: :optional]])
      Config.persist([sentinel: [invitable: true]])
    end

    user = Factory.build(:user)
    params = %{user: %{email: user.email, password: @password, password_confirmation: @password}}
    invite_params = %{user: %{email: user.email}}

    mocked_token = SecureRandom.urlsafe_base64()
    mocked_confirmation_token = SecureRandom.urlsafe_base64()
    mocked_password_reset_token = SecureRandom.urlsafe_base64()

    welcome_email = Sentinel.Mailer.send_welcome_email(
      %Sentinel.User{
        unconfirmed_email: params.user.email,
        email: params.user.email,
        id: 1
      }, mocked_token)
    invite_email = Sentinel.Mailer.send_invite_email(
      %Sentinel.User{
        email: params.user.email,
        id: 1
      }, {mocked_confirmation_token, mocked_password_reset_token})

    {
      :ok,
      %{
        conn: build_conn(),
        params: params,
        invite_params: invite_params,
        mocked_token: mocked_token,
        welcome_email: welcome_email,
        invite_email: invite_email
      }
    }
  end

  test "default sign up", %{conn: conn, params: params, welcome_email: mocked_mail} do # green
    Config.persist([sentinel: [confirmable: :optional]])
    Config.persist([sentinel: [invitable: false]])

    with_mock Sentinel.Mailer, [:passthrough], [send_welcome_email: fn(_, _) -> mocked_mail end] do
      conn = post conn, auth_path(conn, :callback, "identity"), params
      response(conn, 302)
      user = TestRepo.get_by!(User, email: params.user.email)

      refute is_nil(user.hashed_confirmation_token)
      assert_delivered_email mocked_mail
      assert String.contains?(conn.private.phoenix_flash["info"], "Signed up")
      assert String.contains?(conn.resp_body, "/auth/account")
    end
  end

  test "confirmable :required sign up", %{conn: conn, params: params, welcome_email: mocked_mail} do # green
    Config.persist([sentinel: [confirmable: :required]])
    Config.persist([sentinel: [invitable: false]])


    with_mock Sentinel.Mailer, [:passthrough], [send_welcome_email: fn(_, _) -> mocked_mail end] do
      conn = post conn, auth_path(conn, :callback, "identity"), params
      response(conn, 302)
      user = TestRepo.get_by!(User, email: params.user.email)

      refute is_nil(user.hashed_confirmation_token)
      assert_delivered_email mocked_mail
      assert String.contains?(conn.private.phoenix_flash["info"], "Signed up")
      assert String.contains?(conn.resp_body, "/auth/account")
    end
  end

  test "confirmable :false sign up", %{conn: conn, params: params} do # green
    Config.persist([sentinel: [confirmable: false]])
    Config.persist([sentinel: [invitable: false]])

    conn = post conn, auth_path(conn, :callback, "identity"), params
    response(conn, 302)
    user = TestRepo.get_by!(User, email: params.user.email)

    refute is_nil(user.hashed_confirmation_token)
    refute_delivered_email Sentinel.Mailer.NewEmailAddress.build(user, "token")
    assert String.contains?(conn.private.phoenix_flash["info"], "Signed up")
    assert String.contains?(conn.resp_body, "/auth/account")
  end

  test "inviting a user via the invitable sign up", %{conn: conn, invite_params: params, invite_email: mocked_mail} do # green
    Config.persist([sentinel: [invitable: true]])
    Config.persist([sentinel: [confirmable: false]])

    with_mock Sentinel.Mailer, [:passthrough], [send_invite_email: fn(_, _) -> mocked_mail end] do
      token_count = length(TestRepo.all(Token))
      conn = post conn, auth_path(conn, :callback, "identity"), params
      response(conn, 302)

      refute token_count + 1 == length(TestRepo.all(Token))
      assert_delivered_email mocked_mail
      assert String.contains?(conn.resp_body, "/auth/users/new")
    end
  end

  test "invitable and confirmable sign up", %{conn: conn, invite_params: params, invite_email: mocked_mail} do # green
    Config.persist([sentinel: [invitable: true]])
    Config.persist([sentinel: [confirmable: :optional]])

    with_mock Sentinel.Mailer, [:passthrough], [send_invite_email: fn(_, _) -> mocked_mail end] do
      token_count = length(TestRepo.all(Token))
      conn = post conn, auth_path(conn, :callback, "identity"), params
      response(conn, 302)

      refute token_count + 1 == length(TestRepo.all(Token))
      assert_delivered_email mocked_mail
      assert String.contains?(conn.resp_body, "/auth/users/new")
    end
  end

  test "invitable setup password", %{conn: conn, params: params} do
    Config.persist([sentinel: [confirmable: :optional]])
    Config.persist([sentinel: [invitable: true]])

    auth = %{
      provider: "identity",
      uid: params.user.email,
      info: %Ueberauth.Auth.Info{email: "user0@example.com"}
    }

    {:ok, %{user: user, confirmation_token: confirmation_token}} =
      TestRepo.transaction(fn ->
        {confirmation_token, changeset} =
          auth.info
          |> Map.from_struct
          |> Registrator.changeset
          |> Confirmator.confirmation_needed_changeset

        user = TestRepo.insert!(changeset)

        %Sentinel.Ueberauth{uid: user.id, user_id: user.id}
        |> Sentinel.Ueberauth.changeset(auth)
        |> TestRepo.insert!

        %{user: user, confirmation_token: confirmation_token}
      end)

    db_auth = TestRepo.get_by(Sentinel.Ueberauth, user_id: user.id, provider: "identity")
    {password_reset_token, changeset} = PasswordResetter.create_changeset(db_auth)
    updated_db_auth = TestRepo.update!(changeset)

    token_count = length(TestRepo.all(Token))
    conn = post conn, user_path(conn, :invited, user.id), %{confirmation_token: confirmation_token, password_reset_token: password_reset_token, password: params.user.password, password_confirmation: params.user.password}
    response = response(conn, 302)

    assert String.contains?(conn.resp_body, "/auth/users/new")
    updated_user = TestRepo.get!(User, user.id)
    updated_auth = TestRepo.get!(Sentinel.Ueberauth, db_auth.id)

    assert updated_user.hashed_confirmation_token == nil
    assert updated_auth.hashed_password_reset_token == nil
    assert updated_user.unconfirmed_email == nil
    refute token_count + 1 == length(TestRepo.all(Token))
  end

  test "sign up with missing password without the invitable module enabled", %{conn: conn, invite_params: params}  do # green
    Config.persist([sentinel: [invitable: false]])

    conn = post conn, auth_path(conn, :callback, "identity"), params
    response(conn, 401) #FIXME or 422?

    IO.inspect conn.resp_body
    assert String.contains?(conn.private.phoenix_flash["error"], "Failed to create user")
  end

  test "sign up with missing email", %{conn: conn} do
    conn = post conn, auth_path(conn, :callback, "identity"), %{"user" => %{"password" => @password}}
    response(conn, 422) #FIXME or 401?

    assert String.contains?(conn.private.phoenix_flash["error"], "Failed to create user")
  end

  test "sign up with custom validations", %{conn: conn, params: params} do
    Config.persist([sentinel: [confirmable: :optional]])
    Config.persist([sentinel: [invitable: false]])

    Application.put_env(:sentinel, :user_model_validator, fn changeset ->
      Ecto.Changeset.add_error(changeset, :password, "too short")
    end)

    conn = post conn, auth_path(conn, :callback, "identity"), params
    response(conn, 401) #FIXME or 422

    assert String.contains?(conn.private.phoenix_flash["error"], "Failed to create user")
  end

  ##FIXME working on the confirmable thing
  #test "confirm user with a bad token", %{conn: conn, params: %{user: params}} do
  #  {_, changeset} =
  #    params
  #    |> Registrator.changeset
  #    |> Confirmator.confirmation_needed_changeset
  #  TestRepo.insert!(changeset)

  #  conn = post conn, user_path(conn, :confirm), %{email: params.email, confirmation_token: "bad_token"}
  #  response = json_response(conn, 422)
  #  assert response == %{"errors" => [%{"confirmation_token" => "invalid"}]}
  #end

  #test "confirm a user", %{conn: conn, params: %{user: params}} do
  #  {token, changeset} =
  #    params
  #    |> Registrator.changeset
  #    |> Confirmator.confirmation_needed_changeset
  #  user = TestRepo.insert!(changeset)

  #  conn = post conn, user_path(conn, :confirm), %{email: params.email, confirmation_token: token}
  #  assert json_response(conn, 200)

  #  updated_user = TestRepo.get! User, user.id
  #  assert updated_user.hashed_confirmation_token == nil
  #  assert updated_user.confirmed_at != nil
  #end

  #test "confirm a user's new email", %{conn: conn, params: %{user: user}} do
  #  {token, registrator_changeset} =
  #    user
  #    |> Registrator.changeset
  #    |> Confirmator.confirmation_needed_changeset

  #  user =
  #    registrator_changeset
  #    |> TestRepo.insert!
  #    |> Confirmator.confirmation_changeset(%{"confirmation_token" => token})
  #    |> TestRepo.update!

  #  {token, updater_changeset} = AccountUpdater.changeset(user, %{"email" => "new@example.com"})
  #  updated_user = TestRepo.update!(updater_changeset)

  #  conn = post conn, user_path(conn, :confirm), %{email: updated_user.email, confirmation_token: token}
  #  assert json_response(conn, 200)

  #  updated_user = TestRepo.get! User, user.id
  #  assert updated_user.hashed_confirmation_token == nil
  #  assert updated_user.unconfirmed_email == nil
  #  assert updated_user.email == "new@example.com"
  #end
end