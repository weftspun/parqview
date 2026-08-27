defmodule Parqview.NotFoundError do
  @moduledoc """
  Raised when a request names a relation or row that does not exist.

  This is the let-it-crash path, not a guard around it: the controller does no
  defensive checking and simply dies on bad input. The only thing this module
  adds is `plug_status`, which `Plug.Exception` reads to answer 404 instead of
  500. The process still crashes and is still restarted; the client just gets an
  honest status code rather than one implying the server is broken.
  """
  defexception [:message, plug_status: 404]
end
