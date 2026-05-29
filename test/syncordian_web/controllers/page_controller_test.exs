defmodule SyncordianWeb.PageControllerTest do
  use SyncordianWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Syncordian"
  end
end
