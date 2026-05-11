defmodule Synthex.Hub.Telemetry do
  @moduledoc """
  Bridge between Synthex's `:telemetry` events and the hub's
  master-API endpoints.

  The synthesis loop in `Synthex.Gym.Mujoco.solve/2` emits a
  `[:synthex, :mujoco, :bit_accepted]` event whenever a CEGAR
  step lands an improvement. By attaching a handler here, masters
  publish a fresh policy snapshot to the hub on every accepted
  bit — no callback-option plumbing required at the
  synthesis-loop call site.
  """

  require Logger

  alias Synthex.Hub.Client
  alias Synthex.Core.PrettyPrint

  @event [:synthex, :mujoco, :bit_accepted]

  @doc """
  Attach a telemetry handler that pushes a policy snapshot to
  `client` on every accepted CEGAR bit.

  Options:

    * `:handler_id`  — telemetry handler id (must be unique per
                      node). Default: `"synthex-hub-snapshot-push"`.
    * `:on_error`    — `(reason) -> any` callback for failed
                      pushes. Default: logs at warning level.

  Returns `:ok` (matches `:telemetry.attach/4` for ergonomic
  pattern matching in caller scripts).
  """
  @spec attach_snapshot_publisher(Client.t(), keyword) :: :ok
  def attach_snapshot_publisher(%Client{} = client, opts \\ []) do
    id = Keyword.get(opts, :handler_id, "synthex-hub-snapshot-push")

    on_error =
      Keyword.get(opts, :on_error, fn reason ->
        Logger.warning("[Synthex.Hub] snapshot push failed: #{inspect(reason)}")
      end)

    :telemetry.attach(id, @event, &__MODULE__.handle_event/4, %{
      client: client,
      on_error: on_error
    })
  end

  @doc false
  def handle_event(@event, measurements, metadata, %{client: client, on_error: on_error}) do
    preds = metadata.bit_predicates

    code =
      PrettyPrint.to_python(preds,
        bits_per_dim: metadata.bits_per_dim,
        n_action_dims: metadata.n_action_dims,
        action_range: metadata.action_range,
        action_dim_names: metadata.action_dim_names
      )

    attrs = %{
      env_name: metadata.env_name,
      bit_predicates: %{"preds" => Enum.map(preds, &PrettyPrint.to_json_term/1)},
      policy_code: code,
      code_language: "python",
      n_bits: metadata.n_bits,
      target_bit: metadata.bit_idx,
      cegar_iter: metadata.cegar_iter,
      iter: metadata.iter,
      best_reward: measurements[:reward]
    }

    case Client.push_policy_snapshot(client, attrs) do
      {:ok, _snapshot} -> :ok
      {:error, reason} -> on_error.(reason)
    end
  end
end
