defmodule ParqviewWeb.BrowseLive do
  @moduledoc """
  Browse a directory of Parquet relations: a sidebar of relations, a paged table
  for tabular ones, and a thumbnail grid for relations that embed image bytes.
  """
  use ParqviewWeb, :live_view
  alias Parqview.Dataset

  @per_page 50
  @per_grid 60

  @impl true
  def mount(_params, _session, socket) do
    rels = Dataset.relations()

    socket =
      socket
      |> assign(
        relations: rels, dir: Dataset.dir(), selected: nil, offset: 0,
        cols: [], rows: [], total: 0, images: [], image_mode: false
      )

    socket =
      case rels do
        [{first, _, _} | _] -> load(socket, first, 0)
        [] -> socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("select", %{"name" => name}, socket),
    do: {:noreply, load(socket, name, 0)}

  def handle_event("page", %{"offset" => off}, socket),
    do: {:noreply, load(socket, socket.assigns.selected, String.to_integer(off))}

  defp load(socket, name, offset) do
    if Dataset.image_relation?(name) do
      {images, total} = Dataset.image_page(name, offset, @per_grid)

      assign(socket,
        selected: name, offset: offset, images: images,
        total: total, image_mode: true, cols: [], rows: []
      )
    else
      {cols, rows, total} = Dataset.page(name, offset, @per_page)

      assign(socket,
        selected: name, offset: offset, cols: cols, rows: rows,
        total: total, image_mode: false, images: []
      )
    end
  end

  defp per(true), do: @per_grid
  defp per(false), do: @per_page

  defp commas(n) when is_integer(n) do
    n |> Integer.to_string() |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,") |> String.reverse()
  end

  defp human(b) when b > 1_073_741_824, do: "#{Float.round(b / 1_073_741_824, 1)} GiB"
  defp human(b) when b > 1_048_576, do: "#{Float.round(b / 1_048_576, 1)} MiB"
  defp human(b) when b > 1024, do: "#{Float.round(b / 1024, 1)} KiB"
  defp human(b), do: "#{b} B"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen font-mono text-sm bg-zinc-950 text-zinc-200">
      <aside class="w-72 shrink-0 overflow-y-auto border-r border-zinc-800 p-3">
        <div class="mb-3 text-xs text-zinc-500 break-all">{@dir}</div>
        <button
          :for={{name, rows, bytes} <- @relations}
          phx-click="select"
          phx-value-name={name}
          class={[
            "w-full text-left px-2 py-1 rounded hover:bg-zinc-800 block",
            @selected == name && "bg-zinc-800 text-emerald-400"
          ]}
        >
          <span class="block truncate">{name}</span>
          <span class="block text-xs text-zinc-500">{commas(rows)} rows · {human(bytes)}</span>
        </button>
      </aside>

      <main class="flex-1 overflow-auto p-4">
        <div :if={@selected} class="mb-3 flex items-center gap-3">
          <h1 class="text-emerald-400">{@selected}</h1>
          <span class="text-zinc-500">{commas(@total)} rows</span>
          <div class="ml-auto flex gap-2">
            <button
              phx-click="page"
              phx-value-offset={max(@offset - per(@image_mode), 0)}
              disabled={@offset == 0}
              class="px-2 py-1 border border-zinc-700 rounded disabled:opacity-30"
            >prev</button>
            <span class="px-2 py-1 text-zinc-500">
              {@offset + 1}–{min(@offset + per(@image_mode), @total)}
            </span>
            <button
              phx-click="page"
              phx-value-offset={@offset + per(@image_mode)}
              disabled={@offset + per(@image_mode) >= @total}
              class="px-2 py-1 border border-zinc-700 rounded disabled:opacity-30"
            >next</button>
          </div>
        </div>

        <div :if={@image_mode} class="grid grid-cols-6 gap-2">
          <figure :for={{id, path, score} <- @images}>
            <img
              src={~p"/img/#{@selected}/#{id}"}
              loading="lazy"
              class="w-full h-40 object-cover rounded border border-zinc-800"
            />
            <figcaption class="mt-1 text-[10px] text-zinc-500 truncate" title={path}>
              {path}
              <span :if={score} class="text-emerald-500">· {Float.round(score, 4)}</span>
            </figcaption>
          </figure>
        </div>

        <table :if={not @image_mode} class="w-full border-collapse">
          <thead>
            <tr class="text-left text-zinc-400">
              <th :for={c <- @cols} class="border-b border-zinc-700 px-2 py-1">{c}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} class="hover:bg-zinc-900">
              <td :for={v <- row} class="border-b border-zinc-900 px-2 py-1 align-top">{v}</td>
            </tr>
          </tbody>
        </table>
      </main>
    </div>
    """
  end
end
