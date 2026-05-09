defmodule SymphonyElixir.Claude.AppServer do
  @moduledoc """
  Adapter for Anthropic's Claude Code CLI (`claude --print`).

  Spawns the `claude` CLI as a subprocess inside the Symphony workspace
  for the issue. Claude runs in non-interactive print mode with
  newline-delimited JSON event streaming on stdout, which we parse and
  forward to Symphony's orchestrator via the same `on_message` callback
  shape that `SymphonyElixir.Codex.AppServer` uses.

  This module's public API mirrors `Codex.AppServer` so
  `SymphonyElixir.AgentRunner` can dispatch to either based on the
  workflow's `agent.type` setting.
  """

  require Logger

  @port_line_bytes 1_048_576
  @default_turn_timeout :timer.minutes(60)

  @type session :: %{
          workspace: Path.t(),
          worker_host: String.t() | nil,
          metadata: map(),
          thread_id: String.t()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    expanded =
      workspace
      |> Path.expand()
      |> to_string()

    thread_id = generate_thread_id()
    metadata = %{thread_id: thread_id, worker_host: worker_host}

    {:ok,
     %{
       workspace: expanded,
       worker_host: worker_host,
       metadata: metadata,
       thread_id: thread_id
     }}
  end

  @spec stop_session(session()) :: :ok
  def stop_session(_session), do: :ok

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{workspace: workspace, metadata: metadata, thread_id: thread_id},
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    timeout = Keyword.get(opts, :turn_timeout_ms, @default_turn_timeout)

    case spawn_claude(workspace, prompt) do
      {:ok, port} ->
        turn_id = generate_turn_id()
        session_id = "#{thread_id}-#{turn_id}"

        Logger.info(
          "Claude session started for #{issue_context(issue)} session_id=#{session_id} workspace=#{workspace}"
        )

        emit_message(
          on_message,
          :session_started,
          %{session_id: session_id, thread_id: thread_id, turn_id: turn_id},
          metadata
        )

        case await_completion(port, on_message, metadata, timeout, "") do
          {:ok, summary} ->
            Logger.info(
              "Claude session completed for #{issue_context(issue)} session_id=#{session_id}"
            )

            emit_message(on_message, :session_completed, summary, metadata)

            {:ok,
             %{
               result: summary,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            Logger.warning(
              "Claude session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}"
            )

            emit_message(on_message, :session_failed, %{reason: inspect(reason)}, metadata)

            {:error, reason}
        end

      {:error, reason} ->
        emit_message(on_message, :startup_failed, %{reason: inspect(reason)}, metadata)
        {:error, reason}
    end
  end

  defp spawn_claude(workspace, prompt) do
    case System.find_executable("claude") do
      nil ->
        {:error, :claude_not_found}

      claude_path ->
        try do
          port =
            Port.open(
              {:spawn_executable, claude_path},
              [
                :binary,
                :exit_status,
                :stderr_to_stdout,
                {:cd, workspace},
                {:line, @port_line_bytes},
                {:args, claude_args(prompt)}
              ]
            )

          {:ok, port}
        rescue
          error -> {:error, error}
        end
    end
  end

  defp claude_args(prompt) do
    [
      "--print",
      "--input-format",
      "text",
      "--output-format",
      "stream-json",
      "--verbose",
      prompt
    ]
  end

  defp await_completion(port, on_message, metadata, timeout, buffer) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        full = buffer <> line
        emit_event_from_line(on_message, metadata, full)
        await_completion(port, on_message, metadata, timeout, "")

      {^port, {:data, {:noeol, partial}}} ->
        await_completion(port, on_message, metadata, timeout, buffer <> partial)

      {^port, {:exit_status, 0}} ->
        {:ok, %{exit_status: 0, partial_buffer: maybe_truncate(buffer)}}

      {^port, {:exit_status, status}} ->
        {:error, {:exit, status, maybe_truncate(buffer)}}
    after
      timeout ->
        safely_close(port)
        {:error, :timeout}
    end
  end

  defp emit_event_from_line(on_message, metadata, line) do
    case Jason.decode(line) do
      {:ok, payload} when is_map(payload) ->
        event = event_atom(payload)

        emit_message(
          on_message,
          event,
          %{payload: payload, raw: maybe_truncate(line)},
          metadata
        )

      _ ->
        emit_message(on_message, :stream_text, %{raw: maybe_truncate(line)}, metadata)
    end
  end

  defp event_atom(%{"type" => type}) when is_binary(type), do: String.to_atom("claude_#{type}")
  defp event_atom(_), do: :claude_event

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp emit_message(_on_message, _event, _details, _metadata), do: :ok

  defp default_on_message(_message), do: :ok

  defp issue_context(%{identifier: id}) when is_binary(id), do: id
  defp issue_context(%{"identifier" => id}) when is_binary(id), do: id
  defp issue_context(_), do: "unknown_issue"

  defp generate_thread_id do
    "claude-thread-" <> random_token()
  end

  defp generate_turn_id do
    "turn-" <> random_token()
  end

  defp random_token do
    :crypto.strong_rand_bytes(8)
    |> Base.encode16(case: :lower)
  end

  defp maybe_truncate(text) when is_binary(text) do
    if byte_size(text) > 1_000 do
      binary_part(text, 0, 1_000) <> "…"
    else
      text
    end
  end

  defp maybe_truncate(other), do: inspect(other)

  defp safely_close(port) when is_port(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end
  end
end
