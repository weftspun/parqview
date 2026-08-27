defmodule Parqview.ReleaseSteps do
  @moduledoc """
  Release steps that make Burrito cross-builds actually bootable.

  Explorer's Polars backend is a Rust NIF delivered by `rustler_precompiled`,
  which downloads exactly one artefact: the one matching the *build* host. Burrito
  will happily wrap that release for four targets, producing three binaries that
  crash on boot with a load error.

  `swap_nif/1` replaces the bundled NIF with the one for the target being built,
  pulled from the rustler_precompiled cache. Populate that cache first:

      mix rustler_precompiled.download Explorer.PolarsBackend.Native --all
  """
  require Logger

  @nif_for %{
    "macos_arm" => "aarch64-apple-darwin",
    "macos_x86" => "x86_64-apple-darwin",
    "linux_x86" => "x86_64-unknown-linux-gnu",
    "linux_arm" => "aarch64-unknown-linux-gnu",
    "windows_x86" => "x86_64-pc-windows-msvc"
  }

  @cache Path.expand("~/Library/Caches/rustler_precompiled/precompiled_nifs")

  def swap_nif(release) do
    case System.get_env("BURRITO_TARGET") do
      nil -> release
      target -> do_swap(release, target)
    end
  end

  defp do_swap(release, target) do
    triple = Map.get(@nif_for, target)

    if is_nil(triple) do
      Logger.warning("no NIF triple known for target #{target}; leaving host NIF in place")
      release
    else
      native_dir =
        release.path
        |> Path.join("lib")
        |> Path.wildcard()
        |> Enum.find(&(Path.basename(&1) =~ ~r/^explorer-/))
        |> case do
          nil -> nil
          dir -> Path.join([dir, "priv", "native"])
        end

      cond do
        is_nil(native_dir) or not File.dir?(native_dir) ->
          Logger.warning("explorer priv/native not found in release; skipping NIF swap")
          release

        true ->
          swap_into(native_dir, triple, target)
          release
      end
    end
  end

  defp swap_into(native_dir, triple, target) do
    archive =
      @cache
      |> Path.join("*#{triple}*.tar.gz")
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, "legacy_cpu"))
      |> List.first()

    if archive do
      Enum.each(Path.wildcard(Path.join(native_dir, "libexplorer*")), &File.rm!/1)
      :ok = :erl_tar.extract(String.to_charlist(archive), [:compressed, {:cwd, String.to_charlist(native_dir)}])

      Logger.info("swapped Explorer NIF for #{target} (#{triple})")
    else
      raise """
      no cached Explorer NIF for #{triple}.
      Run: mix rustler_precompiled.download Explorer.PolarsBackend.Native --all
      """
    end
  end
end
