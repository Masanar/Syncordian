defmodule SyncordianWeb.Cart do
  use SyncordianWeb, :live_view

  def mount(_params, session, socket) do
    socket = socket
    |> PhoenixLiveSession.maybe_subscribe(session)
    |> put_session_assigns(session)

    {:ok, socket}
  end

  def handle_info({:live_session_updated, session}, socket) do
    {:noreply, put_session_assigns(socket, session)}
  end

  def handle_event("add_to_cart", %{"product_id" => product_id}, socket) do
    updated_cart = [product_id | socket.assigns.cart]
    PhoenixLiveSession.put_session(socket, "cart", updated_cart)

    {:noreply, socket}
  end

  defp put_session_assigns(socket, session) do
    socket
    |> assign(:shopping_cart, Map.get(session, "shopping_cart", []))
  end
end
