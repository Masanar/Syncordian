defmodule SyncordianWeb.About do
  @moduledoc """
  Landing page LiveView (route `/`) — a static About page describing the project.
  """
  use SyncordianWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, socket}
  end
end
