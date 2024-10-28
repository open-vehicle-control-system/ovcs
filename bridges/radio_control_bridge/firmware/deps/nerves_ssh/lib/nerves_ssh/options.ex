defmodule NervesSSH.Options do
  @moduledoc """
  Defines option for running the SSH daemon.

  The following fields are available:

  * `:name` - a name used to reference the NervesSSH-managed SSH daemon. Defaults to `NervesSSH`.
  * `:authorized_keys` - a list of SSH authorized key file string
  * `:port` - the TCP port to use for the SSH daemon. Defaults to `22`.
  * `:subsystems` - a list of [SSH subsystems specs](https://erlang.org/doc/man/ssh.html#type-subsystem_spec) to start. Defaults to SFTP and `ssh_subsystem_fwup`
  * `:user_dir` - where to find authorized_keys file
  * `:system_dir` - where to find host keys
  * `:shell` - the language of the shell (`:elixir`, `:erlang`, `:lfe` or `:disabled`). Defaults to `:elixir`.
  * `:exec` - the language to use for commands sent over ssh (`:elixir`, `:erlang`, or `:disabled`). Defaults to `:elixir`.
  * `:iex_opts` - additional options to use when starting up IEx
  * `:user_passwords` - a list of username/password tuples (stored in the clear!)
  * `:daemon_option_overrides` - additional options to pass to `:ssh.daemon/2`. These take precedence and are unchecked. Be careful using this since it can break other options.
  """

  alias Nerves.Runtime.KV

  require Logger

  @otp System.otp_release() |> Integer.parse() |> elem(0)

  if @otp < 23, do: raise("NervesSSH requires OTP 23 or higher")

  @type language :: :elixir | :erlang | :lfe | :disabled

  @type t :: %__MODULE__{
          name: GenServer.name(),
          authorized_keys: [String.t()],
          decoded_authorized_keys: [:public_key.public_key()],
          user_passwords: [{String.t(), String.t()}],
          port: non_neg_integer(),
          subsystems: [:ssh.subsystem_spec()],
          system_dir: Path.t(),
          user_dir: Path.t(),
          shell: language(),
          exec: language(),
          iex_opts: keyword(),
          daemon_option_overrides: keyword()
        }

  defstruct name: NervesSSH,
            authorized_keys: [],
            decoded_authorized_keys: [],
            user_passwords: [],
            port: 22,
            subsystems: [:ssh_sftpd.subsystem_spec(cwd: ~c"/")],
            system_dir: "/data/nerves_ssh",
            user_dir: "/data/nerves_ssh/default_user",
            shell: :elixir,
            exec: :elixir,
            iex_opts: [dot_iex_path: Path.expand(".iex.exs")],
            daemon_option_overrides: []

  @doc """
  Convert keyword options to the NervesSSH.Options
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    # if a key is present with nil value, the default will
    # not be applied in the struct. So remove keys that
    # have a nil value so defaults get set appropriately
    opts = Enum.reject(opts, fn {_k, v} -> is_nil(v) end)

    struct(__MODULE__, opts)
    |> decode_authorized_keys()
  end

  @doc """
  Create a new NervesSSH.Options and fill in defaults
  """
  @spec with_defaults(keyword()) :: t()
  def with_defaults(opts \\ []) do
    opts
    |> new()
    |> maybe_add_fwup_subsystem()
    |> sanitize()
  end

  @doc """
  Return :ssh.daemon_options()
  """
  @spec daemon_options(t()) :: :ssh.daemon_options()
  def daemon_options(opts) do
    (base_opts() ++
       subsystem_opts(opts) ++
       shell_opts(opts) ++
       exec_opts(opts) ++
       authentication_daemon_opts(opts) ++
       key_cb_opts(opts) ++
       user_passwords_opts(opts))
    |> Keyword.merge(opts.daemon_option_overrides)
    |> load_or_create_host_keys()
  end

  @doc """
  Add an authorized key
  """
  @spec add_authorized_key(t(), String.t()) :: t()
  def add_authorized_key(opts, key) do
    update_in(opts.authorized_keys, &Enum.uniq(&1 ++ [key]))
    |> decode_authorized_keys()
  end

  @doc """
  Remove an authorized key
  """
  @spec remove_authorized_key(t(), String.t()) :: t()
  def remove_authorized_key(opts, key) do
    %{opts | decoded_authorized_keys: []}
    |> Map.update!(:authorized_keys, &for(k <- &1, k != key, do: k))
    |> decode_authorized_keys()
  end

  @doc """
  Load authorized keys from the authorized_keys file
  """
  @spec load_authorized_keys(t()) :: t()
  def load_authorized_keys(opts) when is_struct(opts) do
    case File.read(authorized_keys_path(opts)) do
      {:ok, str} ->
        from_file = String.split(str, "\n", trim: true)

        update_in(opts.authorized_keys, &Enum.uniq(&1 ++ from_file))
        |> decode_authorized_keys()

      {:error, err} ->
        # We only care about the error if the file actually exists
        if err != :enoent,
          do: Logger.error("[NervesSSH] Failed to read authorized_keys file: #{err}")

        opts
    end
  end

  @doc """
  Decode the authorized keys into Erlang public key format
  """
  @spec decode_authorized_keys(t()) :: t()
  def decode_authorized_keys(opts) do
    keys = for {key, _} <- Enum.flat_map(opts.authorized_keys, &decode_key/1), do: key
    update_in(opts.decoded_authorized_keys, &Enum.uniq(&1 ++ keys))
  end

  @doc """
  Save the authorized keys to authorized_keys file
  """
  @spec save_authorized_keys(t()) :: :ok | {:error, File.posix()}
  def save_authorized_keys(opts) do
    kpath = authorized_keys_path(opts)

    with :ok <- File.mkdir_p(Path.dirname(kpath)) do
      formatted = Enum.join(opts.authorized_keys, "\n")
      File.write(kpath, formatted)
    end
  end

  @doc """
  Add user credential to SSH options
  """
  @spec add_user(t(), String.t(), String.t() | nil) :: t()
  def add_user(opts, user, password)
      when is_binary(user) and (is_binary(password) or is_nil(password)) do
    update_in(opts.user_passwords, &Enum.uniq_by([{user, password} | &1], fn {u, _} -> u end))
  end

  @doc """
  Remove user credential from SSH options
  """
  @spec remove_user(t(), String.t()) :: t()
  def remove_user(opts, user) do
    update_in(opts.user_passwords, &for({u, _} = k <- &1, u != user, do: k))
  end

  defp base_opts() do
    [
      inet: :inet6,
      disconnectfun: fn _reason -> false end
    ] ++ hardening_opts()
  end

  defp hardening_opts() do
    [
      id_string: :random,
      modify_algorithms: [
        rm: [
          kex: [
            :"diffie-hellman-group-exchange-sha256",
            :"ecdh-sha2-nistp384",
            :"ecdh-sha2-nistp521",
            :"ecdh-sha2-nistp256"
          ],
          cipher: [
            client2server: [
              :"aes256-cbc",
              :"aes192-cbc",
              :"aes128-cbc",
              :"3des-cbc"
            ],
            server2client: [
              :"aes256-cbc",
              :"aes192-cbc",
              :"aes128-cbc",
              :"3des-cbc"
            ]
          ],
          mac: [
            client2server: [
              :"hmac-sha2-256",
              :"hmac-sha1-etm@openssh.com",
              :"hmac-sha1"
            ],
            server2client: [
              :"hmac-sha2-256",
              :"hmac-sha1-etm@openssh.com",
              :"hmac-sha1"
            ]
          ]
        ]
      ]
    ]
  end

  if Version.match?(System.version(), ">= 1.17.0") do
    defp shell_opts(%{shell: :elixir, iex_opts: iex_opts}),
      do: [{:shell, {:iex, :start, [iex_opts, {:elixir_utils, :noop, []}]}}]
  else
    defp shell_opts(%{shell: :elixir, iex_opts: iex_opts}),
      do: [{:shell, {Elixir.IEx, :start, [iex_opts]}}]
  end

  defp shell_opts(%{shell: :erlang}), do: []
  defp shell_opts(%{shell: :lfe}), do: [{:shell, {:lfe_shell, :start, []}}]
  defp shell_opts(%{shell: :disabled}), do: [shell: :disabled]

  defp exec_opts(%{exec: :elixir}), do: [exec: {:direct, &NervesSSH.Exec.run_elixir/1}]
  defp exec_opts(%{exec: :erlang}), do: []
  defp exec_opts(%{exec: :lfe}), do: [exec: {:direct, &NervesSSH.Exec.run_lfe/1}]
  defp exec_opts(%{exec: :disabled}), do: [exec: :disabled]

  defp key_cb_opts(opts), do: [key_cb: {NervesSSH.Keys, name: opts.name}]

  defp user_passwords_opts(opts) do
    [
      # https://www.erlang.org/doc/man/ssh.html#type-pwdfun_4
      pwdfun: fn user, password, peer_address, state ->
        NervesSSH.UserPasswords.check(opts.name, user, password, peer_address, state)
      end
    ]
  end

  defp authentication_daemon_opts(opts) do
    [system_dir: safe_dir(opts.system_dir), user_dir: safe_dir(opts.user_dir)]
  end

  defp safe_dir(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        to_charlist(dir)

      {:error, err} ->
        tmp = Path.join("/tmp/nerves_ssh", dir)
        _ = File.mkdir_p(tmp)
        Logger.warning("[NervesSSH] File error #{inspect(err)} for #{dir} - Using #{tmp}")
        to_charlist(tmp)
    end
  end

  defp subsystem_opts(opts) do
    [subsystems: opts.subsystems]
  end

  @doc """
  Go through the options and fix anything that might crash

  The goal is to make options "always work" since it is painful to
  debug typo's, etc. that cause the ssh daemon to not start.
  """
  @spec sanitize(t()) :: t()
  def sanitize(opts) do
    safe_subsystems = Enum.filter(opts.subsystems, &valid_subsystem?/1)
    safe_dot_iex_path = validate_dot_iex_path(opts.iex_opts[:dot_iex_path])
    iex_opts = Keyword.put(opts.iex_opts, :dot_iex_path, safe_dot_iex_path)

    %__MODULE__{opts | subsystems: safe_subsystems, iex_opts: iex_opts}
  end

  defp validate_dot_iex_path(dot_iex_path) do
    [dot_iex_path, ".iex.exs", "~/.iex.exs", "/etc/iex.exs"]
    |> Enum.filter(&is_bitstring/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.find("", &File.regular?/1)
  end

  defp valid_subsystem?({name, {mod, args}})
       when is_list(name) and is_atom(mod) and is_list(args) do
    List.ascii_printable?(name)
  end

  defp valid_subsystem?(_), do: false

  defp maybe_add_fwup_subsystem(opts) do
    found =
      Enum.find(opts.subsystems, fn
        {~c"fwup", _} -> true
        _ -> false
      end)

    if found do
      opts
    else
      devpath = KV.get("nerves_fw_devpath")
      new_subsystems = [SSHSubsystemFwup.subsystem_spec(devpath: devpath) | opts.subsystems]
      %{opts | subsystems: new_subsystems}
    end
  end

  # :public_key.ssh_decode/2 was deprecated in OTP 24 and will be removed in OTP 26.
  # :ssh_file.decode/2 was introduced in OTP 24
  if @otp >= 24 do
    defp decode_key(key), do: :ssh_file.decode(key, :auth_keys)
  else
    defp decode_key(key), do: :public_key.ssh_decode(key, :auth_keys)
  end

  defp load_or_create_host_keys(daemon_opts) do
    algs = available_and_supported_algorithms(daemon_opts)

    load_host_keys(algs, daemon_opts)
    |> maybe_create_host_key(algs, daemon_opts)
    |> maybe_set_host_keys(daemon_opts)
  end

  defp available_and_supported_algorithms(daemon_opts) do
    # For now, we just want the final scrubbed list of algorithms the server
    # can use based on ours and the users definitions, so we take those out of
    # our daemon options and run through the Erlang functions to resolve them
    # for us, ignoring all other options If the other options are "Bad", we
    # want :ssh to handle it later but not prevent our progress here
    filtered =
      Keyword.take(daemon_opts, [:modify_algorithms, :preferred_algorithms, :pref_public_key_algs])

    ssh_opts = :ssh_options.handle_options(:server, filtered)

    # This represents the logic in :ssh_connection_handler.available_hkey_algorithms/2.
    # It is replicated here to leave the result as atoms and to skip the file
    # read check that happens so we can do it later on.
    supported = :ssh_transport.supported_algorithms(:public_key)
    preferred = ssh_opts.preferred_algorithms[:public_key]
    not_supported = preferred -- supported
    preferred -- not_supported
  end

  defp load_host_keys(available_algorithms, daemon_opts) do
    for alg <- available_algorithms,
        r = :ssh_file.host_key(alg, daemon_opts),
        match?({:ok, _}, r),
        into: %{},
        do: {alg, elem(r, 1)}
  end

  defp maybe_create_host_key(keys, _, _) when map_size(keys) > 0, do: keys

  defp maybe_create_host_key(_, available_algs, daemon_opts) do
    {hkey_filename, alg} = preferred_host_key_algorithm(available_algs)
    key = generate_host_key(alg)

    # Just attempt to write. If it fails for some reason, we will
    # go through this host key create flow to try again.
    attempt_host_key_write(daemon_opts, hkey_filename, key)

    if is_list(alg), do: for(a <- alg, into: %{}, do: {a, key}), else: %{alg => key}
  end

  defp maybe_set_host_keys(host_keys, daemon_options) do
    case daemon_options[:key_cb] do
      nil ->
        daemon_options

      {mod, opts} ->
        Keyword.put(daemon_options, :key_cb, {mod, put_in(opts, [:host_keys], host_keys)})

      mod ->
        Keyword.put(daemon_options, :key_cb, {mod, [host_keys: host_keys]})
    end
  end

  defp preferred_host_key_algorithm(algs) do
    if Enum.member?(algs, :"ssh-ed25519") do
      {"ssh_host_ed25519_key", :"ssh-ed25519"}
    else
      {"ssh_host_rsa_key", [:"rsa-sha2-512", :"rsa-sha2-256", :"ssh-rsa"]}
    end
  end

  defp generate_host_key(:"ssh-ed25519") do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {:ed_pri, :ed25519, pub, priv}
  end

  defp generate_host_key(_alg) do
    :public_key.generate_key({:rsa, 2048, 65537})
  end

  defp attempt_host_key_write(daemon_opts, hkey_filename, key) do
    path = Path.join(daemon_opts[:system_dir], hkey_filename)

    with :ok <- File.mkdir_p(daemon_opts[:system_dir]),
         :ok <- File.write(path, encode_host_key(key)),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      err ->
        Logger.warning("""
        [NervesSSH] Failed to write generated SSH host key to #{path} - #{inspect(err)}

        The SSH daemon wil continue to run and use the generated key, but a new host key
        will be generated the next time the daemon is started.
        """)
    end
  end

  defp encode_host_key({:ed_pri, alg, pub, priv}) do
    # In future versions of Erlang, this might be supported.
    # But for now, manually create the expected format
    # See https://github.com/erlang/otp/pull/5520

    alg_str = "ssh-#{alg}"
    alg_l = byte_size(alg_str)
    pub_l = byte_size(pub)
    pubbuff = <<alg_l::32, alg_str::binary, pub_l::32, pub::binary>>
    pubbuff_l = byte_size(pubbuff)
    comment = "nerves_ssh-generated"
    comment_l = byte_size(comment)
    check = :crypto.strong_rand_bytes(4)

    encrypted =
      <<check::binary, check::binary, pubbuff::binary, 64::32, priv::binary, pub::binary,
        comment_l::32, comment::binary>>

    pad = for i <- 1..(8 - rem(byte_size(encrypted), 8)), into: <<>>, do: <<i>>
    encrypted_l = byte_size(encrypted <> pad)

    encoded =
      <<"openssh-key-v1", 0, 4::32, "none", 4::32, "none", 0::32, 1::32, pubbuff_l::32,
        pubbuff::binary, encrypted_l::32, encrypted::binary, pad::binary>>
      |> Base.encode64()
      |> String.codepoints()
      |> Enum.chunk_every(68)
      |> Enum.join("\n")

    """
    -----BEGIN OPENSSH PRIVATE KEY-----
    #{encoded}
    -----END OPENSSH PRIVATE KEY-----
    """
  end

  defp encode_host_key(rsa_key) do
    :public_key.pem_entry_encode(:RSAPrivateKey, rsa_key)
    |> List.wrap()
    |> :public_key.pem_encode()
  end

  defp authorized_keys_path(opts) do
    user_dir = opts.daemon_option_overrides[:user_dir] || opts.user_dir
    Path.join(user_dir, "authorized_keys")
  end
end
