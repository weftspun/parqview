defmodule ParqviewWeb.PageController do
  use ParqviewWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
