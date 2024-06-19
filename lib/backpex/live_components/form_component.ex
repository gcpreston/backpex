defmodule Backpex.FormComponent do
  @moduledoc """
  The form live component.
  """

  use BackpexWeb, :html
  use Phoenix.LiveComponent

  import Backpex.HTML.Resource

  alias Backpex.Fields.Upload
  alias Backpex.LiveResource
  alias Backpex.Resource
  alias Backpex.ResourceAction

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:action_type, fn -> nil end)
      |> assign_new(:show_form_errors, fn -> false end)
      |> update_assigns()
      |> assign_form()

    {:ok, socket}
  end

  defp update_assigns(%{assigns: %{action_type: :item}} = socket) do
    socket
    |> assign_fields()
    |> assign_changeset()
  end

  defp update_assigns(%{assigns: assigns} = socket) do
    socket
    |> apply_action(assigns.live_action)
    |> maybe_assign_uploads()
  end

  defp maybe_assign_uploads(socket) do
    socket =
      Enum.reduce(socket.assigns.fields, socket, fn {_name, field_options} = field, acc ->
        field_options.module.assign_uploads(field, acc)
      end)

    assign_new(socket, :removed_uploads, fn -> Keyword.new() end)
  end

  defp assign_fields(%{assigns: %{action_to_confirm: action_to_confirm}} = socket) do
    socket
    |> assign_new(:fields, fn -> action_to_confirm.module.fields() end)
    |> assign(:save_label, action_to_confirm.module.confirm_label(socket.assigns))
  end

  defp assign_changeset(%{assigns: %{action_to_confirm: action_to_confirm}} = socket) do
    init_change = action_to_confirm.module.init_change(socket.assigns)
    changeset_function = &action_to_confirm.module.changeset/3

    socket
    |> assign(item_action_types: init_change)
    |> assign(:changeset_function, changeset_function)
    |> assign_new(:changeset, fn ->
      init_change
      |> Ecto.Changeset.change()
      |> LiveResource.call_changeset_function(changeset_function, %{}, socket.assigns)
    end)
  end

  defp apply_action(socket, action) when action in [:edit, :new] do
    socket
    |> assign(:save_label, Backpex.translate("Save"))
  end

  defp apply_action(socket, :resource_action) do
    %{assigns: %{resource_action: resource_action}} = socket

    socket
    |> assign(:save_label, ResourceAction.name(resource_action, :label))
    |> assign(:fields, resource_action.module.fields())
  end

  defp assign_form(socket) do
    changeset = socket.assigns.changeset
    form = Phoenix.Component.to_form(changeset, as: :change)

    assign(socket, :form, form)
  end

  def handle_event("validate", %{"change" => change, "_target" => target}, %{assigns: %{action_type: :item}} = socket) do
    %{
      assigns: %{item_action_types: item_action_types, changeset_function: changeset_function, fields: fields} = assigns
    } = socket

    target = Enum.at(target, 1)

    change =
      change
      |> drop_readonly_changes(fields, assigns)
      |> put_upload_change(socket, :validate)

    changeset = Resource.change(item_action_types, change, changeset_function, assigns, [], target)
    form = Phoenix.Component.to_form(changeset, as: :change)

    send(self(), {:update_changeset, changeset})

    socket =
      socket
      |> assign(:form, form)
      |> assign(:show_form_errors, false)

    {:noreply, socket}
  end

  def handle_event("validate", %{"change" => change, "_target" => target}, socket) do
    %{assigns: %{item: item, changeset_function: changeset_function, fields: fields} = assigns} = socket

    target = Enum.at(target, 1)
    assocs = Map.get(assigns, :assocs, [])

    change =
      change
      |> drop_readonly_changes(fields, assigns)
      |> put_upload_change(socket, :validate)

    changeset = Resource.change(item, change, changeset_function, assigns, assocs, target)
    form = Phoenix.Component.to_form(changeset, as: :change)

    send(self(), {:update_changeset, changeset})

    socket =
      socket
      |> assign(:form, form)
      |> assign(:show_form_errors, false)

    {:noreply, socket}
  end

  def handle_event("validate", _params, socket) do
    socket = assign(socket, :show_form_errors, false)

    {:noreply, socket}
  end

  def handle_event("cancel-entry", %{"ref" => ref, "id" => id}, socket) do
    socket = cancel_upload(socket, String.to_existing_atom(id), ref)

    {:noreply, socket}
  end

  def handle_event("cancel-existing-entry", %{"ref" => file_key, "id" => upload_key}, socket) do
    upload_key = String.to_existing_atom(upload_key)

    field =
      socket.assigns.fields()
      |> Enum.find(fn {_name, field_options} ->
        Map.has_key?(field_options, :upload_key) and Map.get(field_options, :upload_key) == upload_key
      end)

    removed_uploads =
      socket.assigns
      |> Map.get(:removed_uploads, [])
      |> Keyword.update(upload_key, [file_key], fn existing -> [file_key | existing] end)

    files = Upload.existing_file_paths(field, socket.assigns.item, Keyword.get(removed_uploads, upload_key, []))
    uploaded_files = Keyword.put(socket.assigns[:uploaded_files], upload_key, files)

    socket =
      socket
      |> assign(:removed_uploads, removed_uploads)
      |> assign(:uploaded_files, uploaded_files)

    {:noreply, socket}
  end

  def handle_event("save", %{"action-key" => key, "change" => change}, %{assigns: %{action_type: :item}} = socket) do
    key = String.to_existing_atom(key)
    handle_item_action(socket, key, change)
  end

  def handle_event("save", %{"change" => change, "return" => _}, socket) do
    %{assigns: %{live_action: live_action, fields: fields} = assigns} = socket

    change =
      change
      |> put_upload_change(socket, :insert)
      |> drop_readonly_changes(fields, assigns)

    handle_save(socket, live_action, change, follow_return_to: true)
  end

  def handle_event("save", %{"change" => change, "continue-editing" => _}, socket) do
    %{assigns: %{live_action: live_action, fields: fields} = assigns} = socket

    change =
      change
      |> put_upload_change(socket, :insert)
      |> drop_readonly_changes(fields, assigns)

    handle_save(socket, live_action, change, follow_return_to: false)
  end

  def handle_event("save", %{"action-key" => key}, socket) do
    key = String.to_existing_atom(key)
    handle_item_action(socket, key, %{})
  end

  def handle_event("save", _params, socket) do
    handle_item_action(socket, nil, %{})
  end

  def handle_event(msg, params, socket) do
    socket =
      Enum.reduce(socket.assigns.fields, socket, fn el, acc ->
        el.module.handle_form_event(el, msg, params, acc)
      end)

    {:noreply, socket}
  end

  defp handle_save(socket, :new, params, opts) do
    follow_return_to = Keyword.get(opts, :follow_return_to, true)

    %{
      assigns:
        %{
          repo: repo,
          live_resource: live_resource,
          singular_name: singular_name,
          changeset_function: changeset_function,
          item: item
        } = assigns
    } = socket

    insert_opts = [
      assigns: assigns,
      pubsub: assigns[:pubsub],
      assocs: Map.get(assigns, :assocs, []),
      after_save: fn item ->
        handle_uploads(socket)
        live_resource.on_item_created(socket, item)

        {:ok, item}
      end
    ]

    case Resource.insert(item, params, repo, changeset_function, insert_opts) do
      {:ok, item} ->
        return_to = live_resource.return_to(socket, assigns, :new, item)
        info_msg = Backpex.translate({"New %{resource} has been created successfully.", %{resource: singular_name}})

        socket =
          socket
          |> assign(:show_form_errors, false)
          |> clear_flash()
          |> put_flash(:info, info_msg)
          |> maybe_push_navigate(follow_return_to, to: return_to)

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        form = Phoenix.Component.to_form(changeset, as: :change)

        socket =
          socket
          |> assign(:show_form_errors, true)
          |> assign(:form, form)

        send(self(), {:update_changeset, changeset})

        {:noreply, socket}
    end
  end

  defp handle_save(socket, :edit, params, opts) do
    follow_return_to = Keyword.get(opts, :follow_return_to, true)

    %{
      assigns:
        %{
          repo: repo,
          live_resource: live_resource,
          singular_name: singular_name,
          changeset_function: changeset_function,
          item: item
        } = assigns
    } = socket

    update_opts = [
      assigns: assigns,
      pubsub: assigns[:pubsub],
      assocs: Map.get(assigns, :assocs, []),
      after_save: fn item ->
        handle_uploads(socket)
        live_resource.on_item_updated(socket, item)

        {:ok, item}
      end
    ]

    case Resource.update(item, params, repo, changeset_function, update_opts) do
      {:ok, item} ->
        return_to = live_resource.return_to(socket, assigns, :edit, item)
        info_msg = Backpex.translate({"%{resource} has been edited successfully.", %{resource: singular_name}})

        socket =
          socket
          |> assign(:show_form_errors, false)
          |> clear_flash()
          |> put_flash(:info, info_msg)
          |> maybe_push_navigate(follow_return_to, to: return_to)

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        form = Phoenix.Component.to_form(changeset, as: :change)

        socket =
          socket
          |> assign(:show_form_errors, true)
          |> assign(:form, form)

        send(self(), {:update_changeset, changeset})

        {:noreply, socket}
    end
  end

  defp handle_save(socket, :resource_action, params, opts) do
    follow_return_to = Keyword.get(opts, :follow_return_to, true)

    %{
      assigns:
        %{
          resource_action: resource_action,
          item: item,
          changeset_function: changeset_function,
          return_to: return_to
        } = assigns
    } = socket

    assocs = Map.get(assigns, :assocs, [])
    changeset = Backpex.Resource.change(item, params, changeset_function, assigns, assocs)

    case changeset do
      %{valid?: true} ->
        result = resource_action.module.handle(socket, params)

        if match?({:ok, _msg}, result), do: handle_uploads(socket)

        socket =
          socket
          |> assign(:show_form_errors, false)
          |> put_flash_message(result)
          |> maybe_push_navigate(follow_return_to, to: return_to)

        {:noreply, socket}

      _not_valid ->
        form = Phoenix.Component.to_form(changeset, as: :change)

        socket =
          socket
          |> assign(:show_form_errors, true)
          |> assign(:form, form)

        send(self(), {:update_changeset, changeset})

        {:noreply, socket}
    end
  end

  defp handle_item_action(socket, action_key, params) do
    %{
      assigns:
        %{
          selected_items: selected_items,
          action_to_confirm: action_to_confirm,
          return_to: return_to,
          item_action_types: item_action_types,
          changeset_function: changeset_function
        } = assigns
    } = socket

    changeset = Backpex.Resource.change(item_action_types, params, changeset_function, assigns)

    case changeset do
      %{valid?: true} ->
        selected_items =
          Enum.filter(selected_items, fn item ->
            LiveResource.can?(socket.assigns, action_key, item, socket.assigns.live_resource)
          end)

        {message, socket} =
          socket
          |> assign(:show_form_errors, false)
          |> assign(selected_items: [])
          |> assign(select_all: false)
          |> action_to_confirm.module.handle(selected_items, params)

        {message, push_patch(socket, to: return_to)}

      _not_valid ->
        form = Phoenix.Component.to_form(changeset, as: :change)

        socket =
          socket
          |> assign(:show_form_errors, true)
          |> assign(:form, form)

        {:noreply, socket}
    end
  end

  defp drop_readonly_changes(change, fields, assigns) do
    read_only =
      fields
      |> Enum.filter(&Backpex.Field.readonly?(&1, assigns))
      |> Enum.map(&Atom.to_string(&1.name))

    Map.drop(change, read_only)
  end

  defp put_flash_message(socket, {type, msg}) do
    socket
    |> clear_flash()
    |> put_flash(flash_key(type), msg)
  end

  defp flash_key(:ok), do: :info
  defp flash_key(:error), do: :error

  defp put_upload_change(change, socket, action) do
    Enum.reduce(socket.assigns.fields, change, fn
      {_name, %{upload_key: upload_key} = field_options} = _field, acc ->
        %{put_upload_change: put_upload_change} = field_options

        uploaded_entries = uploaded_entries(socket, upload_key)
        removed_entries = Keyword.get(socket.assigns.removed_uploads, upload_key, [])

        put_upload_change.(socket, acc, socket.assigns.item, uploaded_entries, removed_entries, action)

      _field, acc ->
        acc
    end)
  end

  defp handle_uploads(%{assigns: %{uploads: _uploads}} = socket) do
    for {_name, %{upload_key: upload_key} = field_options} = _field <- socket.assigns.fields do
      if Map.has_key?(socket.assigns.uploads, upload_key) do
        %{consume_upload: consume_upload, remove_uploads: remove_uploads} = field_options

        item = socket.assigns.item

        consume_uploaded_entries(socket, upload_key, fn meta, entry ->
          consume_upload.(socket, item, meta, entry)
        end)

        removed_entries = Keyword.get(socket.assigns.removed_uploads, upload_key, [])
        remove_uploads.(socket, item, removed_entries)
      end
    end
  end

  defp handle_uploads(_socket), do: :ok

  defp maybe_push_navigate(socket, false, _opts), do: socket
  defp maybe_push_navigate(socket, true, opts), do: push_navigate(socket, opts)

  def render(assigns) do
    form_component(assigns)
  end
end
