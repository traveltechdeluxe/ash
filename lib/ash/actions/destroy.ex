defmodule Ash.Actions.Destroy do
  @moduledoc false

  alias Ash.Actions.Helpers

  require Ash.Tracer

  @spec run(Ash.Api.t(), Ash.Changeset.t(), Ash.Resource.Actions.action(), Keyword.t()) ::
          {:ok, list(Ash.Notifier.Notification.t())}
          | :ok
          | {:error, Ash.Changeset.t()}
          | {:error, term}
  def run(api, changeset, action, opts) do
    {changeset, opts} = Ash.Actions.Helpers.add_process_context(api, changeset, opts)

    Ash.Tracer.span :action,
                    Ash.Api.Info.span_name(
                      api,
                      changeset.resource,
                      action.name
                    ),
                    opts[:tracer] do
      metadata = %{
        api: api,
        resource: changeset.resource,
        resource_short_name: Ash.Resource.Info.short_name(changeset.resource),
        actor: opts[:actor],
        tenant: opts[:tenant],
        action: action.name,
        authorize?: opts[:authorize?]
      }

      Ash.Tracer.set_metadata(opts[:tracer], :action, metadata)

      Ash.Tracer.telemetry_span [:ash, Ash.Api.Info.short_name(api), :destroy], metadata do
        case do_run(api, changeset, action, opts) do
          {:error, error} ->
            if opts[:tracer] do
              stacktrace =
                case error do
                  %{stacktrace: %{stacktrace: stacktrace}} ->
                    stacktrace || []

                  _ ->
                    {:current_stacktrace, stacktrace} =
                      Process.info(self(), :current_stacktrace)

                    stacktrace
                end

              Ash.Tracer.set_handled_error(opts[:tracer], Ash.Error.to_error_class(error),
                stacktrace: stacktrace
              )
            end

            {:error, error}

          other ->
            other
        end
      end
    end
  rescue
    e ->
      reraise Ash.Error.to_error_class(e, changeset: changeset, stacktrace: __STACKTRACE__),
              __STACKTRACE__
  end

  def do_run(api, changeset, %{soft?: true} = action, opts) do
    changeset =
      if changeset.__validated_for_action__ == action.name do
        %{changeset | action_type: :destroy}
      else
        Ash.Changeset.for_destroy(%{changeset | action_type: :destroy}, action.name, %{},
          actor: opts[:actor]
        )
      end

    Ash.Actions.Update.do_run(api, changeset, action, opts)
  end

  def do_run(api, changeset, action, opts) do
    {changeset, opts} = Ash.Actions.Helpers.add_process_context(api, changeset, opts)

    return_destroyed? = opts[:return_destroyed?]
    changeset = %{changeset | api: api}

    changeset =
      if opts[:tenant] do
        Ash.Changeset.set_tenant(changeset, opts[:tenant])
      else
        changeset
      end

    with %{valid?: true} = changeset <- Ash.Changeset.validate_multitenancy(changeset),
         %{valid?: true} = changeset <- changeset(changeset, api, action, opts),
         %{valid?: true} = changeset <- authorize(changeset, api, opts),
         {:ok, result, instructions} <- commit(changeset, api, opts) do
      changeset.resource
      |> add_notifications(
        changeset.action,
        instructions,
        opts[:return_notifications?]
      )
      |> add_destroyed(return_destroyed?, result)
    end
    |> case do
      {:ok, result} ->
        {:ok, result}

      {:ok, result, notifications} ->
        {:ok, result, notifications}

      :ok ->
        :ok

      %Ash.Changeset{errors: errors} = changeset ->
        errors = Helpers.process_errors(changeset, errors)
        {:error, Ash.Error.to_error_class(errors, changeset: changeset)}

      {:error, error} ->
        errors = Helpers.process_errors(changeset, List.wrap(error))
        {:error, Ash.Error.to_error_class(errors, changeset: changeset)}
    end
  end

  defp authorize(changeset, api, opts) do
    if opts[:authorize?] do
      case api.can(changeset, opts[:actor],
             alter_source?: true,
             return_forbidden_error?: true,
             maybe_is: false
           ) do
        {:ok, true, changeset} ->
          changeset

        {:ok, false, error} ->
          Ash.Changeset.add_error(changeset, error)

        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    else
      changeset
    end
  end

  defp commit(changeset, api, opts) do
    changeset
    |> Ash.Changeset.put_context(:private, %{actor: opts[:actor], authorize?: opts[:authorize?]})
    |> Ash.Changeset.with_hooks(
      fn
        %{valid?: false} = changeset ->
          {:error, changeset}

        changeset ->
          if changeset.action.manual do
            {mod, action_opts} = changeset.action.manual

            if result = changeset.context[:private][:action_result] do
              result
            else
              mod.destroy(changeset, action_opts, %{
                actor: opts[:actor],
                tenant: changeset.tenant,
                authorize?: opts[:authorize?],
                api: changeset.api
              })
              |> validate_manual_action_return_result!(changeset.resource, changeset.action)
            end
          else
            if result = changeset.context[:private][:action_result] do
              result
            else
              changeset.resource
              |> Ash.DataLayer.destroy(changeset)
              |> Ash.Actions.Helpers.rollback_if_in_transaction(changeset)
              |> case do
                :ok ->
                  {:ok,
                   Ash.Resource.set_meta(changeset.data, %Ecto.Schema.Metadata{
                     state: :deleted,
                     schema: changeset.resource
                   })}

                {:error, error} ->
                  {:error, Ash.Changeset.add_error(changeset, error)}
              end
            end
          end
          |> then(fn result ->
            case result do
              {:ok, destroyed} ->
                if opts[:return_destroyed?] do
                  {:ok, destroyed, %{notifications: []}}
                  |> Helpers.load(changeset, api,
                    actor: opts[:actor],
                    authorize?: opts[:authorize?],
                    tracer: opts[:tracer]
                  )
                  |> Helpers.notify(changeset, opts)
                  |> Helpers.select(changeset)
                  |> Helpers.restrict_field_access(changeset)
                else
                  {:ok, destroyed, %{notifications: []}}
                  |> Helpers.notify(changeset, opts)
                end

              {:error, %Ash.Changeset{} = changeset} ->
                {:error, changeset}

              other ->
                other
            end
          end)
      end,
      transaction?: Keyword.get(opts, :transaction?, true) && changeset.action.transaction?,
      rollback_on_error?: opts[:rollback_on_error?],
      notification_metadata: opts[:notification_metadata],
      return_notifications?: opts[:return_notifications?],
      transaction_metadata: %{
        type: :destroy,
        metadata: %{
          actor: opts[:actor],
          record: changeset.data,
          resource: changeset.resource,
          action: changeset.action.name
        }
      }
    )
    |> case do
      {:ok, result, changeset, instructions} ->
        instructions =
          Map.update(
            instructions,
            :set_keys,
            %{changeset: changeset, notification_data: result},
            &Map.merge(&1, %{changeset: changeset, notification_data: result})
          )

        {:ok, Helpers.select(result, changeset), instructions}

      {:error, %Ash.Changeset{} = changeset} ->
        {:error, changeset}

      {:error, error} ->
        {:error, error}
    end
  end

  defp validate_manual_action_return_result!({:ok, %resource{}} = result, resource, _) do
    result
  end

  defp validate_manual_action_return_result!(
         {:ok, %resource{}, notifications} = result,
         resource,
         _
       )
       when is_list(notifications) do
    result
  end

  defp validate_manual_action_return_result!({:error, _error} = result, _resource, _) do
    result
  end

  defp validate_manual_action_return_result!(other, resource, action) do
    raise Ash.Error.Framework.AssumptionFailed,
      message: """
      Manual action #{inspect(action.name)} on #{inspect(resource)} returned an invalid result.

      Expected one of the following:

      * {:ok, %Resource{}}
      * {:ok, %Resource{}, notifications}
      * {:error, error}

      Got:

      #{inspect(other)}
      """
  end

  defp add_notifications(resource, action, instructions, return_notifications?) do
    if return_notifications? do
      {:ok, Map.get(instructions, :notifications, [])}
    else
      Ash.Actions.Helpers.warn_missed!(resource, action, instructions)
      :ok
    end
  end

  defp add_destroyed(:ok, true, destroyed) do
    {:ok, destroyed}
  end

  defp add_destroyed({:ok, notifications}, true, destroyed) do
    {:ok, destroyed, notifications}
  end

  defp add_destroyed(result, _, _) do
    result
  end

  defp changeset(changeset, api, action, opts) do
    changeset = %{changeset | api: api}

    if changeset.__validated_for_action__ == action.name do
      changeset
    else
      Ash.Changeset.for_destroy(changeset, action.name, %{}, opts)
    end
    |> Ash.Changeset.timeout(opts[:timeout] || changeset.timeout)
  end
end
