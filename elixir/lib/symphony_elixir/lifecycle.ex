defmodule SymphonyElixir.Lifecycle do
  @moduledoc """
  Armada's Linear-state lifecycle for project agent loops.

  The workflow prompt describes the operating model, but this module is the
  runtime contract. It decides which role owns a status, which status a picked
  up issue should enter while work is active, and when a completed Codex turn
  should continue in the same role versus hand off to the next pickup shelf.
  """

  alias SymphonyElixir.Linear.Issue

  defstruct [
    :role,
    :entry_state,
    :working_state,
    :handoff_states,
    :terminal_states,
    :summary
  ]

  @type t :: %__MODULE__{
          role: atom(),
          entry_state: String.t(),
          working_state: String.t(),
          handoff_states: [String.t()],
          terminal_states: [String.t()],
          summary: String.t()
        }

  @terminal_states ["Done", "Closed", "Cancelled", "Canceled", "Duplicate"]

  @role_by_state %{
    "agent ready" => %{
      role: :implementer,
      working_state: "In Progress",
      handoff_states: ["Review Ready", "Human Review"],
      summary:
        "Implement the requested change, validate it, and hand off completed work to Review Ready. Use Human Review only for true blockers that prevent implementation or validation."
    },
    "in progress" => %{
      role: :implementer,
      working_state: "In Progress",
      handoff_states: ["Review Ready", "Human Review"],
      summary: "Continue implementation work already in progress until it can hand off."
    },
    "review ready" => %{
      role: :reviewer,
      working_state: "Reviewing",
      handoff_states: ["Ready to Merge", "Rework Needed", "Human Review"],
      summary: "Review the implementation and route it to Ready to Merge, Rework Needed, or Human Review."
    },
    "reviewing" => %{
      role: :reviewer,
      working_state: "Reviewing",
      handoff_states: ["Ready to Merge", "Rework Needed", "Human Review"],
      summary: "Continue review already underway until it can hand off."
    },
    "rework needed" => %{
      role: :fixer,
      working_state: "In Progress",
      handoff_states: ["Review Ready", "Human Review"],
      summary:
        "Fix reviewer findings only, validate the fix, and hand off completed work to Review Ready. Use Human Review only for true blockers that prevent implementation or validation."
    },
    "ready to merge" => %{
      role: :merger,
      working_state: "Merging",
      handoff_states: ["Done", "Human Review"],
      summary: "Merge approved work when possible, then move to Done or Human Review with a blocker."
    },
    "merging" => %{
      role: :merger,
      working_state: "Merging",
      handoff_states: ["Done", "Human Review"],
      summary: "Continue merge work already underway until it can complete or block."
    }
  }

  @pickup_states ["agent ready", "review ready", "rework needed", "ready to merge"]

  @spec context_for(Issue.t()) :: {:ok, t()} | {:error, {:unsupported_lifecycle_state, term()}}
  def context_for(%Issue{state: state}) do
    case Map.fetch(@role_by_state, normalize_state(state)) do
      {:ok, config} ->
        {:ok,
         %__MODULE__{
           role: config.role,
           entry_state: state,
           working_state: config.working_state,
           handoff_states: config.handoff_states,
           terminal_states: @terminal_states,
           summary: config.summary
         }}

      :error ->
        {:error, {:unsupported_lifecycle_state, state}}
    end
  end

  @spec pickup_state?(term()) :: boolean()
  def pickup_state?(state), do: normalize_state(state) in @pickup_states

  @spec begin_work(Issue.t(), (String.t(), String.t() -> :ok | {:error, term()})) ::
          {:ok, Issue.t(), t()} | {:error, term()}
  def begin_work(%Issue{id: issue_id} = issue, update_state_fun)
      when is_binary(issue_id) and is_function(update_state_fun, 2) do
    with {:ok, context} <- context_for(issue),
         :ok <- maybe_move_to_working_state(issue, context, update_state_fun) do
      {:ok, %{issue | state: context.working_state}, context}
    end
  end

  def begin_work(%Issue{} = issue, update_state_fun) when is_function(update_state_fun, 2) do
    with {:ok, context} <- context_for(issue),
         false <- pickup_state?(issue.state) do
      {:ok, %{issue | state: context.working_state}, context}
    else
      true -> {:error, {:missing_issue_id_for_state_transition, issue.identifier}}
      error -> error
    end
  end

  def begin_work(issue, _update_state_fun), do: {:error, {:invalid_issue_for_lifecycle, issue}}

  @spec continue_same_role?(t(), Issue.t()) :: boolean()
  def continue_same_role?(%__MODULE__{working_state: working_state}, %Issue{state: state}) do
    normalize_state(state) == normalize_state(working_state)
  end

  @spec boundary_state?(t(), Issue.t()) :: boolean()
  def boundary_state?(%__MODULE__{} = context, %Issue{state: state}) do
    normalized = normalize_state(state)

    Enum.any?(context.handoff_states ++ context.terminal_states, fn candidate ->
      normalize_state(candidate) == normalized
    end)
  end

  @spec prompt(t()) :: String.t()
  def prompt(%__MODULE__{} = context) do
    """
    Armada runtime role: #{context.role}

    Symphony has already claimed this issue for the #{context.role} role and moved it from #{inspect(context.entry_state)} to #{inspect(context.working_state)} when required.

    Your job for this run:
    - #{context.summary}
    - Keep working until the issue can leave #{inspect(context.working_state)}.
    - Valid handoff states for this role: #{Enum.join(context.handoff_states, ", ")}.
    - Do not finish your turn while the issue remains in #{inspect(context.working_state)} unless you are genuinely blocked and have recorded the blocker in the workpad.
    - Implementers and fixers must not move directly to Human Review just because work touches UI, copy, layout, product judgment, or lacks a GitHub remote. Record those as review risks and move completed work to Review Ready.
    - Move directly to Human Review only when blocked before completion by a human decision, credentials, external action, deploy, domain/DNS, payment, or another requirement that cannot be safely implemented or validated.
    """
  end

  defp maybe_move_to_working_state(%Issue{id: issue_id, state: state}, context, update_state_fun) do
    if pickup_state?(state) and normalize_state(state) != normalize_state(context.working_state) do
      update_state_fun.(issue_id, context.working_state)
    else
      :ok
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(state), do: state |> to_string() |> normalize_state()
end
