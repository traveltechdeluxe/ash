defmodule Ash.Mix.Tasks.Helpers do
  @moduledoc """
  Helpers for Ash Mix tasks.
  """

  @doc """
  Gets all extensions in use by the current project's domains and resources
  """
  def extensions!(argv, opts \\ []) do
    if opts[:in_use?] do
      Mix.shell().info("Getting extensions in use by resources in current project...")
      domains = Ash.Mix.Tasks.Helpers.domains!(argv)

      resource_extensions =
        domains
        |> Enum.flat_map(&Ash.Domain.Info.resources/1)
        |> all_extensions()

      domains
      |> all_extensions()
      |> Enum.concat(resource_extensions)
      |> Enum.uniq()
      |> case do
        [] ->
          Mix.shell().info("No extensions in use by resources in current project...")

        extensions ->
          extensions
      end
    else
      Mix.shell().info("Getting extensions in current project...")

      Application.loaded_applications()
      |> Stream.map(&elem(&1, 0))
      |> Stream.flat_map(&List.wrap(elem(:application.get_key(&1, :modules), 1)))
      |> Stream.filter(&Spark.implements_behaviour?(&1, Spark.Dsl.Extension))
      |> Enum.uniq()
      |> case do
        [] ->
          Mix.shell().info("No extensions in the current project.")
          []

        extensions ->
          extensions
      end
    end
  end

  @doc """
  Get all domains for the current project and ensure they are compiled.
  """
  def domains!(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: [domains: :string])

    domains =
      if opts[:domains] && opts[:domains] != "" do
        opts[:domains]
        |> Kernel.||("")
        |> String.split(",")
        |> Enum.flat_map(fn
          "" ->
            []

          domain ->
            [Module.concat([domain])]
        end)
      else
        apps =
          if Code.ensure_loaded?(Mix.Project) do
            if apps_paths = Mix.Project.apps_paths() do
              apps_paths |> Map.keys() |> Enum.sort()
            else
              [Mix.Project.config()[:app]]
            end
          else
            []
          end

        Enum.flat_map(apps, &Application.get_env(&1, :ash_domains, []))
      end

    domains
    |> Enum.map(&ensure_compiled(&1, argv))
    |> case do
      [] ->
        raise "must supply the --domains argument, or set `config :my_app, ash_domains: [...]` in config"

      domains ->
        domains
    end
  end

  defp all_extensions(modules) do
    modules
    |> Enum.flat_map(&Spark.extensions/1)
    |> Enum.uniq()
  end

  defp ensure_compiled(domain, args) do
    if Code.ensure_loaded?(Mix.Tasks.App.Config) do
      Mix.Task.run("app.config", args)
    else
      Mix.Task.run("loadpaths", args)
      "--no-compile" not in args && Mix.Task.run("compile", args)
    end

    case Code.ensure_compiled(domain) do
      {:module, _} ->
        # TODO: We shouldn't need to make sure that the resources are compiled
        domain
        |> Ash.Domain.Info.resources()
        |> Enum.each(&Code.ensure_compiled/1)

        domain

      {:error, error} ->
        Mix.raise("Could not load #{inspect(domain)}, error: #{inspect(error)}. ")
    end
  end
end
