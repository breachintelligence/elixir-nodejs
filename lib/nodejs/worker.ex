defmodule NodeJS.Worker do
  use GenServer
  require Logger

  # Port can't do more than this.
  @read_chunk_size 65_536

  # This random looking string makes sure that other things writing to
  # stdout do not interfere with the protocol that we rely on here.
  # All protocol messages start with this string.
  @prefix '__elixirnodejs__UOSBsDUP6bp9IF5__'

  @nodejs_env_white_list [
    "ALL_PROXY",
    "ASDF_DIR",
    "ASDF_INSTALL_PATH",
    "ASDF_INSTALL_TYPE",
    "ASDF_INSTALL_VERSION",
    "COLORTERM",
    "EDITOR",
    "FORCE_COLOR",
    "HOME",
    "HTTPS_PROXY",
    "HTTP_PROXY",
    "LANG",
    "LOGNAME",
    "NODE_DEBUG",
    "NODE_DEBUG_NATIVE",
    "NODE_DISABLE_COLORS",
    "NODE_ENV",
    "NODE_EXTRA_CA_CERTS",
    "NODE_ICU_DATA",
    "NODE_NO_WARNINGS",
    "NODE_OPTIONS",
    "NODE_PATH",
    "NODE_PENDING_DEPRECATION",
    "NODE_PENDING_PIPE_INSTANCES",
    "NODE_REDIRECT_WARNINGS",
    "NODE_REPL_EXTERNAL_MODULE",
    "NODE_REPL_HISTORY",
    "NODE_SKIP_PLATFORM_CHECK",
    "NODE_TLS_REJECT_UNAUTHORIZED",
    "NODE_V8_COVERAGE",
    "NO_COLOR",
    "NO_PROXY",
    "NVM_BIN",
    "NVM_CD_FLAGS",
    "NVM_DIR",
    "NVM_INC",
    "OPENSSL_CONF",
    "PATH",
    "PWD",
    "SENTRY_ENVIRONMENT",
    "SHELL",
    "SSH_AUTH_SOCK",
    "SSL_CERT_DIR",
    "SSL_CERT_FILE",
    "TEMP",
    "TERM",
    "TERM_PROGRAM",
    "TERM_PROGRAM_VERSION",
    "TERM_SESSION_ID",
    "TMP",
    "TMPDIR",
    "TZ",
    "USER",
    "UV_THREADPOOL_SIZE",
    "WRITE_CHUNK_SIZE",
    "all_proxy",
    "http_proxy",
    "https_proxy",
    "no_proxy"
  ]

  @moduledoc """
  A genserver that controls the starting of the node service
  """

  @doc """
  Starts the Supervisor and underlying node service.
  """
  @spec start_link([binary()], any()) :: {:ok, pid} | {:error, any()}
  def start_link(
        [module_path, unsecure_tls, https_proxy_settings, http_proxy_settings, no_proxy_settings],
        opts \\ []
      ) do
    GenServer.start_link(
      __MODULE__,
      [module_path, unsecure_tls, https_proxy_settings, http_proxy_settings, no_proxy_settings],
      name: Keyword.get(opts, :name)
    )
  end

  # Node.js REPL Service
  defp node_service_path() do
    Path.join(:code.priv_dir(:nodejs), "server.js")
  end

  # Specifies the NODE_PATH for the REPL service to require modules from. We specify
  # both the root path and `/node_modules` folder relative to the root path. This is
  # to specify the entry point that the REPL service runs code from.
  defp node_path(module_path) do
    [module_path, module_path <> "/node_modules"]
    |> Enum.join(node_path_separator())
    |> String.to_charlist()
  end

  defp node_path_separator do
    case :os.type() do
      {:win32, _} -> ";"
      _ -> ":"
    end
  end

  # --- GenServer Callbacks ---
  @doc false
  def init([
        module_path,
        unsecure_tls,
        https_proxy_settings,
        http_proxy_settings,
        no_proxy_settings
      ]) do
    node = System.find_executable("node")

    port =
      Port.open(
        {:spawn_executable, node},
        line: @read_chunk_size,
        env:
          build_env(
            module_path,
            unsecure_tls,
            https_proxy_settings,
            http_proxy_settings,
            no_proxy_settings
          ),
        args: [node_service_path()]
      )

    {:ok, [node_service_path(), port]}
  end

  defp get_response(data, timeout) do
    receive do
      {_, {:data, {flag, chunk}}} ->
        data = [chunk | data]

        case flag do
          :noeol ->
            get_response(data, timeout)

          :eol ->
            data = data |> Enum.reverse() |> List.flatten()

            case data do
              @prefix ++ protocol_data ->
                {:ok, protocol_data}

              _ ->
                get_response('', timeout)
            end
        end
    after
      timeout ->
        {:error, :timeout}
    end
  end

  defp decode_binary(data, binary) do
    if binary === true do
      :binary.list_to_bin(data)
    else
      data
    end
  end

  @doc false
  def handle_call({module, args, opts}, _from, [_, port] = state)
      when is_tuple(module) do
    timeout = Keyword.get(opts, :timeout)
    binary = Keyword.get(opts, :binary)

    body = :jiffy.encode([Tuple.to_list(module), args], [:use_nil])
    Port.command(port, "#{body}\n")

    case get_response('', timeout) do
      {:ok, response} ->
        decoded_response =
          response
          |> decode_binary(binary)
          |> decode()

        {:reply, decoded_response, state}

      {:error, :timeout} ->
        Logger.warning("#{__MODULE__}: call timed out, killing hung node process")
        kill_port(port)
        {:stop, {:shutdown, :timeout}, {:error, :timeout}, state}
    end
  end

  # Forcibly kills the OS process backing the port. Closing the port alone only
  # sends EOF to the node process's stdin, which it may never notice if it's
  # stuck in synchronous, CPU-bound work.
  defp kill_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", ["-9", to_string(os_pid)])
      nil -> :ok
    end
  catch
    _, _ -> :ok
  end

  # The handle_info/2 clause directly below only needs to be used when debugging.
  # Don't want to deploy since this line will get hit / logged often with an :eol message.
  # These messages don't point to any real problem.
  # The generic `handle_info(_msg, state)` clause will catch / handle all of these messages

  # def handle_info({_port, {:data, {flag, message}}}, state) when is_atom(flag) do
  #   # Logger.warning("#{__MODULE__}: worker caught message with flag: #{inspect(flag)}")
  #   {:noreply, state}
  # end

  def handle_info({_port, {:exit_status, _status}}, state), do: {:stop, :normal, state}

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp decode(data) do
    data
    |> to_string()
    |> :jiffy.decode([:return_maps, :use_nil])
    |> case do
      [true, success] -> {:ok, success}
      [false, error] -> {:error, error}
    end
  end

  @doc false
  def terminate(_reason, [_, port]) do
    send(port, {self(), :close})
  end

  defp build_env(
         module_path,
         unsecure_tls,
         https_proxy_settings,
         http_proxy_settings,
         no_proxy_settings
       ) do
    env_opts =
      get_env_options(
        module_path,
        unsecure_tls,
        https_proxy_settings,
        http_proxy_settings,
        no_proxy_settings
      )

    # convert to maps to merge and then back to a list
    # Keyword.merge does not work with charlist keys
    prune_system_env()
    |> Enum.into(%{})
    |> Map.merge(Enum.into(env_opts, %{}))
    |> Enum.to_list()
  end

  # Sets all environment variables that are not in the whitelist to false.

  # https://security.erlef.org/secure_coding_and_deployment_hardening/external_executables.html

  # The Node.js service inherits all environment variables.
  # This is to ensure that the Node.js service does not inherit
  # any sensitive variables.

  defp prune_system_env() do
    Enum.map(System.get_env(), fn {key, value} ->
      if key in @nodejs_env_white_list do
        {String.to_charlist(key), maybe_string_to_charlist(value)}
      else
        {String.to_charlist(key), false}
      end
    end)
  end

  defp maybe_string_to_charlist(str) when is_binary(str), do: String.to_charlist(str)
  defp maybe_string_to_charlist(not_bin), do: not_bin

  defp get_env_options(module_path, unsecure_tls, nil, nil, _) do
    [
      {'NODE_PATH', node_path(module_path)},
      {'WRITE_CHUNK_SIZE', String.to_charlist("#{@read_chunk_size}")},
      {'NODE_TLS_REJECT_UNAUTHORIZED', String.to_charlist(unsecure_tls)}
    ]
  end

  defp get_env_options(module_path, unsecure_tls, https_proxy_settings, http_proxy_settings, nil) do
    [
      {'NODE_PATH', node_path(module_path)},
      {'WRITE_CHUNK_SIZE', String.to_charlist("#{@read_chunk_size}")},
      {'NODE_TLS_REJECT_UNAUTHORIZED', String.to_charlist(unsecure_tls)},
      https_proxy_settings,
      http_proxy_settings
    ]
  end

  defp get_env_options(
         module_path,
         unsecure_tls,
         https_proxy_settings,
         http_proxy_settings,
         no_proxy_settings
       ) do
    [
      {'NODE_PATH', node_path(module_path)},
      {'WRITE_CHUNK_SIZE', String.to_charlist("#{@read_chunk_size}")},
      {'NODE_TLS_REJECT_UNAUTHORIZED', String.to_charlist(unsecure_tls)},
      https_proxy_settings,
      http_proxy_settings,
      no_proxy_settings
    ]
  end
end
