defmodule SyncordianWeb.PageController do
  @moduledoc """
  Plain controller for static pages (scaffold leftover).

  The interactive UI is served by the LiveViews in `lib/syncordian_web/live/`;
  this controller only renders the default `home` template without the app layout.
  """
  use SyncordianWeb, :controller

  @doc "Renders the static home page without the app layout."
  def home(conn, _params) do
    # The home page is often custom made,
    # so skip the default app layout.
    render(conn, :home, layout: false)
  end
end
