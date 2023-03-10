defmodule Ash.Policy.Checker do
  @moduledoc false

  alias Ash.Policy.{Check, Policy}

  def strict_check_facts(%{policies: policies} = authorizer) do
    Enum.reduce_while(policies, {:ok, authorizer, authorizer.facts}, fn policy,
                                                                        {:ok, authorizer, facts} ->
      case do_strict_check_facts(policy, authorizer, facts) do
        {:ok, authorizer, facts} ->
          {:cont, {:ok, authorizer, facts}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp do_strict_check_facts(%Policy{} = policy, authorizer, facts) do
    policy.condition
    |> List.wrap()
    |> Enum.reduce_while({:ok, authorizer, facts}, fn {check_module, opts},
                                                      {:ok, authorizer, facts} ->
      case do_strict_check_facts(
             %Check{check_module: check_module, check_opts: opts},
             authorizer,
             facts
           ) do
        {:ok, authorizer, facts} -> {:cont, {:ok, authorizer, facts}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, authorizer, facts} ->
        if Enum.all?(List.wrap(policy.condition), fn {check_module, opts} ->
             case Ash.Policy.Policy.fetch_fact(facts, {check_module, opts}) do
               {:ok, true} ->
                 true

               {:ok, false} ->
                 false

               _ ->
                 # don't prune fact checking a branch if we don't know
                 true
             end
           end) do
          strict_check_policies(policy.policies, authorizer, facts)
        else
          {:ok, authorizer, facts}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp do_strict_check_facts(%Ash.Policy.Check{} = check, authorizer, facts) do
    check_module = check.check_module
    opts = check.check_opts

    try do
      case check_module.strict_check(authorizer.actor, authorizer, opts) do
        {:ok, boolean} when is_boolean(boolean) ->
          {:ok, authorizer, Map.put(facts, {check_module, opts}, boolean)}

        {:ok, :unknown} ->
          {:ok, authorizer, facts}

        {:error, error} ->
          {:error, error}

        other ->
          raise "Invalid return value from strict_check call #{check_module}.strict_check(actor, authorizer, #{inspect(opts)}) -  #{inspect(other)}"
      end
    rescue
      e ->
        reraise Ash.Error.to_ash_error(e, __STACKTRACE__,
                  error_context:
                    "Strict checking: #{check_module.describe(opts)} on resource: #{authorizer.resource}"
                ),
                __STACKTRACE__
    end
  end

  defp strict_check_policies(policies, authorizer, facts) do
    Enum.reduce_while(policies, {:ok, authorizer, facts}, fn policy, {:ok, authorizer, facts} ->
      case do_strict_check_facts(policy, authorizer, facts) do
        {:ok, authorizer, facts} -> {:cont, {:ok, authorizer, facts}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  def find_real_scenarios(scenarios, facts) do
    Enum.filter(scenarios, fn scenario ->
      scenario_is_reality(scenario, facts) == :reality
    end)
  end

  defp scenario_is_reality(scenario, facts) do
    scenario
    |> Map.drop([true, false])
    |> Enum.reduce_while(:reality, fn {fact, requirement}, status ->
      case Map.fetch(facts, fact) do
        {:ok, ^requirement} ->
          {:cont, status}

        {:ok, _} ->
          {:halt, :not_reality}

        :error ->
          {:cont, :maybe}
      end
    end)
  end

  def strict_check_scenarios(authorizer) do
    case Ash.Policy.Policy.solve(authorizer) do
      {:ok, value, authorizer} when is_boolean(value) ->
        {:ok, value, authorizer}

      {:ok, scenarios, authorizer} ->
        {:ok,
         scenarios
         |> Ash.Policy.SatSolver.simplify_clauses()
         |> remove_scenarios_with_impossible_facts(authorizer), authorizer}

      {:error, :unsatisfiable} ->
        {:error, :unsatisfiable}
    end
  end

  defp remove_scenarios_with_impossible_facts(scenarios, authorizer) do
    # Remove any scenarios with a fact that must be a certain value, but are not, at strict check time
    # They aren't true, so that scenario isn't possible

    Enum.reject(scenarios, fn scenario ->
      Enum.any?(scenario, fn {{mod, opts}, required_value} ->
        opts[:access_type] == :strict &&
          not match?(
            {:ok, ^required_value},
            Policy.fetch_fact(authorizer.facts, {mod, opts})
          )
      end)
    end)
  end
end
