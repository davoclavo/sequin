defmodule Sequin.Streams do
  @moduledoc false
  import Ecto.Query

  alias Sequin.Error
  alias Sequin.Postgres
  alias Sequin.Repo
  alias Sequin.Streams.Consumer
  alias Sequin.Streams.ConsumerState
  alias Sequin.Streams.Message
  alias Sequin.Streams.OutstandingMessage
  alias Sequin.Streams.Query
  alias Sequin.Streams.Stream
  alias Sequin.StreamsRuntime

  # General

  def reload(%Message{} = msg) do
    # Repo.reload/2 does not support compound pks
    msg.key |> Message.where_key_and_stream_id(msg.stream_id) |> Repo.one()
  end

  # Streams

  def list_streams_for_account(account_id) do
    account_id |> Stream.where_account_id() |> Repo.all()
  end

  def get_stream_for_account(account_id, id) do
    res = account_id |> Stream.where_account_id() |> Stream.where_id(id) |> Repo.one()

    case res do
      nil -> {:error, Error.not_found(entity: :stream)}
      stream -> {:ok, stream}
    end
  end

  def create_stream_for_account_with_lifecycle(account_id, attrs) do
    Repo.transaction(fn ->
      case create_stream(account_id, attrs) do
        {:ok, stream} ->
          create_records_partition(stream)
          stream

        {:error, changes} ->
          Repo.rollback(changes)
      end
    end)
  end

  def delete_stream_with_lifecycle(%Stream{} = stream) do
    Repo.transaction(fn ->
      case delete_stream(stream) do
        {:ok, stream} ->
          drop_records_partition(stream)
          stream

        {:error, changes} ->
          Repo.rollback(changes)
      end
    end)
  end

  def all_streams, do: Repo.all(Stream)

  def create_stream(account_id, attrs) do
    %Stream{account_id: account_id}
    |> Stream.changeset(attrs)
    |> Repo.insert()
  end

  defp create_records_partition(%Stream{} = stream) do
    Repo.query!("""
    CREATE TABLE streams.messages_#{stream.idx} PARTITION OF streams.messages FOR VALUES IN ('#{stream.id}');
    """)
  end

  def delete_stream(%Stream{} = stream) do
    Repo.delete(stream)
  end

  defp drop_records_partition(%Stream{} = stream) do
    Repo.query!("""
    DROP TABLE IF EXISTS streams.messages_#{stream.idx};
    """)
  end

  # Consumers

  def all_consumers do
    Repo.all(Consumer)
  end

  def get_consumer!(consumer_id) do
    consumer_id
    |> Consumer.where_id()
    |> Repo.one!()
  end

  def list_consumers_for_account(account_id) do
    account_id |> Consumer.where_account_id() |> Repo.all()
  end

  def list_consumers_for_stream(stream_id) do
    stream_id |> Consumer.where_stream_id() |> Repo.all()
  end

  def get_consumer_for_account(account_id, id) do
    res = account_id |> Consumer.where_account_id() |> Consumer.where_id(id) |> Repo.one()

    case res do
      nil -> {:error, Error.not_found(entity: :consumer)}
      consumer -> {:ok, consumer}
    end
  end

  def create_consumer_for_account_with_lifecycle(account_id, attrs) do
    Repo.transact(fn ->
      with {:ok, consumer} <- create_consumer(account_id, attrs),
           {:ok, _} <- create_consumer_state(consumer) do
        {:ok, consumer}
      end
    end)
  end

  def create_consumer_with_lifecycle(attrs) do
    account_id = Map.fetch!(attrs, :account_id)

    create_consumer_for_account_with_lifecycle(account_id, attrs)
  end

  def delete_consumer_with_lifecycle(consumer) do
    Repo.transact(fn ->
      case delete_consumer(consumer) do
        :ok ->
          StreamsRuntime.Supervisor.stop_for_consumer(consumer.id)
          delete_consumer_state(consumer)
          consumer

        error ->
          error
      end
    end)
  end

  def update_consumer_with_lifecycle(%Consumer{} = consumer, attrs) do
    consumer
    |> Consumer.update_changeset(attrs)
    |> Repo.update()
  end

  def create_consumer(account_id, attrs) do
    %Consumer{account_id: account_id}
    |> Consumer.create_changeset(attrs)
    |> Repo.insert()
  end

  def create_consumer_state(%Consumer{} = consumer) do
    %ConsumerState{}
    |> ConsumerState.create_changeset(%{consumer_id: consumer.id})
    |> Repo.insert()
  end

  def delete_consumer(%Consumer{} = consumer) do
    Repo.delete(consumer)
  end

  def delete_consumer_state(%Consumer{} = consumer) do
    consumer.id |> ConsumerState.where_consumer_id() |> Repo.delete()
  end

  def get_consumer_state(consumer_id) do
    consumer_id
    |> ConsumerState.where_consumer_id()
    |> Repo.one!()
  end

  def next_for_consumer(%Consumer{} = consumer, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 100)
    not_visible_until = DateTime.add(DateTime.utc_now(), consumer.ack_wait_ms, :millisecond)
    now = NaiveDateTime.utc_now()
    max_ack_pending = consumer.max_ack_pending

    available_oms =
      consumer.id
      |> OutstandingMessage.where_consumer_id()
      |> order_by([om], asc: om.message_seq)
      |> limit(^max_ack_pending)

    available_oms_query =
      from(aom in subquery(available_oms), as: :outstanding_message)
      |> OutstandingMessage.where_deliverable()
      |> order_by([aom], asc: aom.message_seq)
      |> limit(^batch_size)
      |> lock("FOR UPDATE SKIP LOCKED")
      |> select([aom], aom.id)

    Repo.transact(fn ->
      case Repo.all(available_oms_query) do
        aom_ids when aom_ids != [] ->
          {_, messages} =
            Repo.update_all(
              from(om in OutstandingMessage,
                where: om.id in ^aom_ids,
                join: m in Message,
                on: m.key == om.message_key and m.stream_id == om.message_stream_id,
                select: %{ack_id: om.id, message: m}
              ),
              set: [
                state: "delivered",
                not_visible_until: not_visible_until,
                deliver_count: dynamic([om], om.deliver_count + 1),
                last_delivered_at: now
              ]
            )

          messages =
            Enum.map(messages, fn %{ack_id: ack_id, message: message} ->
              %{message | ack_id: ack_id}
            end)

          {:ok, messages}

        [] ->
          {:ok, []}

        error ->
          error
      end
    end)
  end

  # Messages

  def get_message!(key, stream_id) do
    key
    |> Message.where_key_and_stream_id(stream_id)
    |> Repo.one!()
  end

  def assign_message_seqs_with_lock(stream_id, limit \\ 1_000) do
    lock_key = {"assign_message_seqs_with_lock", stream_id}

    Repo.transact(
      fn ->
        case Postgres.try_advisory_xact_lock(lock_key) do
          :ok ->
            assign_message_seqs(stream_id, limit)

            :ok

          {:error, :locked} ->
            {:error, :locked}
        end
      end,
      timeout: :timer.seconds(20)
    )
  end

  def assign_message_seqs(stream_id, limit \\ 1_000) do
    subquery =
      from(m in Message,
        where: is_nil(m.seq) and m.stream_id == ^stream_id,
        order_by: [asc: m.updated_at],
        select: %{key: m.key, stream_id: m.stream_id},
        limit: ^limit
      )

    {count, msgs} =
      Repo.update_all(
        select(
          from(m in Message, join: s in subquery(subquery), on: m.key == s.key and m.stream_id == s.stream_id),
          [m],
          %{key: m.key, seq: m.seq}
        ),
        set: [seq: dynamic([_m], fragment("nextval('streams.messages_seq')"))]
      )

    {count, msgs}
  end

  def upsert_messages(messages, is_retry? \\ false) do
    now = DateTime.utc_now()

    messages =
      Enum.map(messages, fn message ->
        message
        |> Sequin.Map.from_ecto()
        |> Message.put_data_hash()
        |> Map.put(:updated_at, now)
        |> Map.put(:inserted_at, now)
        |> Map.put(:seq, nil)
      end)

    on_conflict =
      from(m in Message,
        where: fragment("? IS DISTINCT FROM ?", m.data_hash, fragment("EXCLUDED.data_hash")),
        update: [
          set: [
            data: fragment("EXCLUDED.data"),
            data_hash: fragment("EXCLUDED.data_hash"),
            updated_at: fragment("EXCLUDED.updated_at"),
            seq: nil
          ]
        ]
      )

    {count, nil} =
      Repo.insert_all(
        Message,
        messages,
        on_conflict: on_conflict,
        conflict_target: [:key, :stream_id],
        timeout: :timer.seconds(30)
      )

    {:ok, count}
  rescue
    e in Postgrex.Error ->
      if e.postgres.code == :character_not_in_repertoire and is_retry? == false do
        messages =
          Enum.map(messages, fn %{data: data} = message ->
            Map.put(message, :data, String.replace(data, "\u0000", ""))
          end)

        upsert_messages(messages, true)
      else
        reraise e, __STACKTRACE__
      end
  end

  # Outstanding Messages

  def all_outstanding_messages do
    Repo.all(OutstandingMessage)
  end

  def get_outstanding_message!(id) do
    Repo.get!(OutstandingMessage, id)
  end

  def ack_messages(consumer_id, message_ids) do
    Repo.transact(fn ->
      {_, _} =
        consumer_id
        |> OutstandingMessage.where_consumer_id()
        |> OutstandingMessage.where_ids(message_ids)
        |> OutstandingMessage.where_state(:pending_redelivery)
        |> Repo.update_all(set: [state: :available, not_visible_until: nil])

      {_, _} =
        consumer_id
        |> OutstandingMessage.where_consumer_id()
        |> OutstandingMessage.where_ids(message_ids)
        |> OutstandingMessage.where_state(:delivered)
        |> Repo.delete_all()

      :ok
    end)

    :ok
  end

  def nack_messages(consumer_id, message_ids) do
    {_, _} =
      consumer_id
      |> OutstandingMessage.where_consumer_id()
      |> OutstandingMessage.where_ids(message_ids)
      |> Repo.update_all(set: [state: :available, not_visible_until: nil])

    :ok
  end

  def list_outstanding_messages_for_consumer(consumer_id) do
    consumer_id
    |> OutstandingMessage.where_consumer_id()
    |> Repo.all()
  end

  def populate_outstanding_messages_with_lock(consumer_id) do
    lock_key = {"populate_outstanding_messages_with_lock", consumer_id}

    Repo.transact(fn ->
      case Postgres.try_advisory_xact_lock(lock_key) do
        :ok ->
          populate_outstanding_messages(consumer_id)

          :ok

        {:error, :locked} ->
          {:error, :locked}
      end
    end)
  end

  def populate_outstanding_messages(%Consumer{} = consumer) do
    now = NaiveDateTime.utc_now()

    res =
      Query.populate_outstanding_messages(
        consumer_id: UUID.string_to_binary!(consumer.id),
        stream_id: UUID.string_to_binary!(consumer.stream_id),
        now: now,
        max_outstanding_message_count: consumer.max_ack_pending * 5,
        table_schema: "streams"
      )

    case res do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def populate_outstanding_messages(consumer_id) do
    consumer = get_consumer!(consumer_id)
    populate_outstanding_messages(consumer)
  end
end
