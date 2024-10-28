defmodule NervesSSH.UserPasswords do
  @moduledoc """
  Default module used for checking User/Password combinations

  This will allow 3 attempts to login with a username and password
  and then send SSH_MSG_DISCONNECT
  """

  require Logger

  @spec check(
          name :: GenServer.name(),
          :erlang.string(),
          :erlang.string(),
          :ssh.ip_port(),
          :undefined | non_neg_integer()
        ) ::
          boolean() | :disconnect | {boolean, non_neg_integer()}
  def check(name, user, password, ip, :undefined), do: check(name, user, password, ip, 0)

  def check(name, user, pwd, ip_port, attempt) do
    attempt = attempt + 1

    authorized?(name, user, pwd) || maybe_disconnect(attempt, user, ip_port)
  end

  defp authorized?(name, user, pwd) do
    NervesSSH.configuration(name).user_passwords
    |> Enum.find_value(false, fn {u, p} ->
      "#{u}" == "#{user}" and "#{p}" == "#{pwd}"
    end)
  catch
    :exit, _ ->
      false
  end

  defp maybe_disconnect(attempt, user, {ip, port}) when attempt >= 3 do
    Logger.info("[NervesSSH] Rejected #{user}@#{:inet.ntoa(ip)}:#{port} after 3 failed attempts")
    :disconnect
  end

  defp maybe_disconnect(attempt, _, _), do: {false, attempt}
end
