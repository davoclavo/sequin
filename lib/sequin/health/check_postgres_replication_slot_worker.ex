defmodule Sequin.Health.CheckPostgresReplicationSlotWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: 120, timestamp: :scheduled_at]

  import Sequin.Error.Guards, only: [is_error: 1]

  alias Sequin.Databases
  alias Sequin.Databases.PostgresDatabase
  alias Sequin.Error
  alias Sequin.Health
  alias Sequin.Health.Event
  alias Sequin.Metrics
  alias Sequin.NetworkUtils
  alias Sequin.Replication
  alias Sequin.Repo

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"postgres_database_id" => postgres_database_id}}) do
    with {:ok, database} <- Databases.get_db(postgres_database_id),
         database = Repo.preload(database, :replication_slot),
         Logger.metadata(database_id: database.id, replication_id: database.replication_slot.id),
         :ok <- check_database(database) do
      check_replication_slot(database)
      measure_replication_lag(database.replication_slot)

      :syn.publish(:replication, {:postgres_replication_slot_checked, database.id}, :postgres_replication_slot_checked)

      :ok
    else
      {:error, %Error.NotFoundError{}} ->
        Logger.warning("Database not found: #{postgres_database_id}")
        :ok

      :error ->
        :ok
    end
  end

  def enqueue(postgres_database_id) do
    %{postgres_database_id: postgres_database_id}
    |> new()
    |> Oban.insert()
  end

  def enqueue(postgres_database_id, unique: false) do
    %{postgres_database_id: postgres_database_id}
    # Effectively disable unique constraint for this job
    |> new(unique: [states: [:available], period: 1])
    |> Oban.insert()
  end

  def enqueue_in(postgres_database_id, delay_seconds) do
    %{postgres_database_id: postgres_database_id}
    |> new(schedule_in: delay_seconds)
    |> Oban.insert()
  end

  defp check_database(%PostgresDatabase{} = database) do
    with :ok <- Databases.test_tcp_reachability(database),
         :ok <- Databases.test_connect(database),
         :ok <- Databases.test_permissions(database),
         {:ok, latency} <- NetworkUtils.measure_latency(database.hostname, database.port) do
      Health.put_event(database.replication_slot, %Event{slug: :db_connectivity_checked, status: :success})
      Metrics.measure_database_avg_latency(database, latency)
      :ok
    else
      {:error, error} when is_error(error) ->
        Health.put_event(database.replication_slot, %Event{slug: :db_connectivity_checked, status: :fail, error: error})
        :error

      {:error, error} when is_exception(error) ->
        error = Error.service(service: :postgres_database, message: Exception.message(error))
        Health.put_event(database.replication_slot, %Event{slug: :db_connectivity_checked, status: :fail, error: error})
        :error
    end
  rescue
    error ->
      error = Error.service(service: :postgres_database, message: Exception.message(error))
      Health.put_event(database.replication_slot, %Event{slug: :db_connectivity_checked, status: :fail, error: error})
      :error
  end

  defp check_replication_slot(database) do
    case Databases.verify_slot(database, database.replication_slot) do
      :ok ->
        Health.put_event(database.replication_slot, %Event{slug: :replication_slot_checked, status: :success})
        :ok

      {:error, error} when is_error(error) ->
        Health.put_event(database.replication_slot, %Event{slug: :replication_slot_checked, status: :fail, error: error})
        :error

      {:error, error} when is_exception(error) ->
        error = Error.service(service: :postgres_database, message: Exception.message(error))
        Health.put_event(database.replication_slot, %Event{slug: :replication_slot_checked, status: :fail, error: error})
        :error
    end
  end

  defp measure_replication_lag(slot) do
    case Replication.measure_replication_lag(slot) do
      {:ok, lag_bytes} ->
        lag_mb = Float.round(lag_bytes / 1024 / 1024, 0)

        if lag_bytes > Replication.lag_bytes_alert_threshold(slot) do
          Logger.warning("Replication lag is #{lag_mb}MB")
        else
          Logger.info("Replication lag is #{lag_mb}MB")
        end

      {:error, error} ->
        Logger.error("Failed to measure replication lag: #{inspect(error)}")
    end
  end
end
