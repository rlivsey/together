defmodule Together.Worker do
  @moduledoc ~S"""
  Together.Worker can be started with the following options:

  - `keep: :first | :last`
  - `type: :throttle | :debounce`
  - `delay: integer`
  """

  use GenServer
  use Together.Global, :start_link

  @default_opts %{
    keep: :last,
    type: :throttle,
    delay: 60_000
  }

  def init(opts) do
    {:ok, Enum.into(opts, @default_opts)}
  end

  def handle_call({:process, id, action}, _from, config) do
    update(id, action, config)
    {:reply, :ok, config}
  end

  def handle_call({:cancel, id}, _from, %{store: store} = config) do
    with {_action, ref} <- Together.Store.get(store, id) do
      Process.cancel_timer(ref)
      Together.Store.delete(store, id)
      {:reply, :ok, config}
    else
      nil -> {:reply, :error, config}
    end
  end

  defp update(id, action, %{proxy: proxy, delay: delay, store: store} = config) do
    record =
      with {old_action, ref} <- Together.Store.get(store, id) do
        update_record({old_action, ref}, id, action, config)
      else
        nil -> {action, Together.Proxy.queue(proxy, id, delay)}
      end

    Together.Store.put(store, id, record)
  end

  defp update_record({old_action, ref}, id, new_action, config) do
    {update_action(old_action, new_action, config), update_ref(ref, id, config)}
  end

  defp update_action(old_action, _action, %{keep: :first}), do: old_action
  defp update_action(_action, new_action, %{keep: :last}), do: new_action

  defp update_ref(ref, _id, %{type: :throttle}), do: ref
  defp update_ref(ref, id, %{type: :debounce, delay: delay, proxy: proxy}) do
    Process.cancel_timer(ref)
    Together.Proxy.queue(proxy, id, delay)
  end

  def handle_cast({:proceed, id}, %{store: store} = config) do
    {action, _ref} = Together.Store.pop(store, id)

    case action do
      {m, f, a} -> Task.start(m, f, a)
      func -> Task.start(func)
    end

    {:noreply, config}
  end
end
