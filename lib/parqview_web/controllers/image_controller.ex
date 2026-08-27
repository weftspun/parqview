defmodule ParqviewWeb.ImageController do
  @moduledoc """
  Serves image bytes embedded in a Parquet relation.

  No input validation: a bad relation or id raises and the process dies, which is
  what should happen. `Parqview.NotFoundError` carries `plug_status: 404` so the
  crash is reported as the client error it is.
  """
  use ParqviewWeb, :controller

  def show(conn, %{"relation" => rel, "id" => id}) do
    {:ok, bytes} = Parqview.Dataset.image_bytes(rel, to_id(id))

    conn
    |> put_resp_content_type(content_type(bytes), nil)
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, bytes)
  end

  defp to_id(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> raise Parqview.NotFoundError, message: "no image #{inspect(id)}"
    end
  end

  defp content_type(<<0xFF, 0xD8, _::binary>>), do: "image/jpeg"
  defp content_type(<<0x89, "PNG", _::binary>>), do: "image/png"
  defp content_type(<<"GIF8", _::binary>>), do: "image/gif"
  defp content_type(_), do: "application/octet-stream"
end
