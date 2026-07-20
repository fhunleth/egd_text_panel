# SPDX-FileCopyrightText: 2026 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule EgdTextPanel do
  @moduledoc """
  Simple text panel for use with EGD

  This text panel implements the Erlang I/O server protocol so write text to
  it with `IO.puts` and the like.

  Example:

      {:ok, io} = EgdTextPanel.start_link(your_options)
      IO.puts(io, "Hello")
  """

  use GenServer

  @render_delay 100

  @typedoc false
  @type state() :: %{
          renderer: module(),
          renderer_state: term(),
          columns: pos_integer(),
          rows: pos_integer(),
          # font: :egd.font(),
          font: atom(),
          font_height: pos_integer(),
          font_color: {float(), float(), float(), float()},
          render_pending: boolean(),
          lines: CircularBuffer.t(),
          column: non_neg_integer(),
          current_line: list()
        }

  @typedoc """
  Text panel margins within the image dimensions

  Fields are left, top, right, bottom margins in pixels
  """
  @type margins() ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @typedoc """
  Options for `start_link/1`

  * `:font_color` - a supported EGD font color atom or a 3-tuple with RGB values. Defaults to `:black`
  * `:font_path` - path to the font to use. Defaults to EGD's built-in font
  * `:height` - image height. Defaults to 200.
  * `:margins` - margins as a 4-tuple. Defaults to `{0, 0, 0, 0}`
  * `:name` - a name for the `GenServer`
  * `:renderer` - the module that implements the `EgdTextPanel.Renderer`. Required.
  * `:renderer_state` - the initial state for the behaviour. Defaults to `%{}`
  * `:width` - image width. Defaults to 320.
  """
  @type options() :: [
          renderer: module(),
          renderer_state: term(),
          margins: margins(),
          font_path: Path.t(),
          width: pos_integer(),
          height: pos_integer(),
          font_color: atom() | {byte(), byte(), byte()},
          name: GenServer.name()
        ]

  @doc """
  Starts an EGD text panel

  See `t:options/0` for options. `:renderer` is the only required option.
  """
  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts =
      Keyword.validate!(opts, [
        :name,
        :renderer,
        renderer_state: %{},
        font_path: Application.app_dir(:egd, "priv/fonts/6x11_latin1.wingsfont"),
        width: 320,
        height: 200,
        font_color: :black,
        margins: {0, 0, 0, 0}
      ])

    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl GenServer
  def init(opts) do
    renderer = Keyword.fetch!(opts, :renderer)
    renderer_state = Keyword.fetch!(opts, :renderer_state)
    font_path = Keyword.fetch!(opts, :font_path)
    margins = Keyword.fetch!(opts, :margins)

    font = :egd_font.load(font_path)
    font_color = Keyword.fetch!(opts, :font_color) |> :egd.color()
    {font_width, font_height} = :egd_font.size(font)
    {left, top, right, bottom} = margins
    columns = div(opts[:width] - left - right, font_width)
    rows = div(opts[:height] - top - bottom, font_height)

    if columns < 1 or rows < 1 do
      raise ArgumentError, "the display area is too small for the configured font and margins"
    end

    {:ok,
     %{
       renderer: renderer,
       renderer_state: renderer_state,
       width: opts[:width],
       height: opts[:height],
       columns: columns,
       rows: rows,
       font: font,
       font_height: font_height,
       font_color: font_color,
       render_pending: false,
       lines: CircularBuffer.new(rows - 1),
       column: 0,
       current_line: [],
       margins: margins
     }}
  end

  @impl GenServer
  def handle_info({:io_request, from, reply_as, request}, state) do
    {reply, state} = handle_request(request, state)
    send(from, {:io_reply, reply_as, reply})
    {:noreply, state}
  end

  def handle_info(:render, %{render_pending: true} = state) do
    {:noreply, %{state | render_pending: false} |> render()}
  end

  def handle_info(:render, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp handle_request({:put_chars, chars}, state), do: put_chars(chars, :unicode, state)
  defp handle_request({:put_chars, encoding, chars}, state), do: put_chars(chars, encoding, state)

  defp handle_request({:put_chars, module, function, arguments}, state) do
    put_chars(module, function, arguments, :unicode, state)
  end

  defp handle_request({:put_chars, encoding, module, function, arguments}, state) do
    put_chars(module, function, arguments, encoding, state)
  end

  defp handle_request({:requests, requests}, state) when is_list(requests) do
    Enum.reduce_while(requests, {:ok, state}, fn request, {_reply, state} ->
      {reply, state} = handle_request(request, state)

      case reply do
        {:error, _reason} -> {:halt, {reply, state}}
        _ -> {:cont, {reply, state}}
      end
    end)
  end

  defp handle_request({:get_geometry, :columns}, state), do: {state.columns, state}
  defp handle_request({:get_geometry, :rows}, state), do: {state.rows, state}

  defp handle_request({:get_chars, _encoding, _prompt, _count}, state),
    do: {{:error, :enotsup}, state}

  defp handle_request({:get_line, _encoding, _prompt}, state),
    do: {{:error, :enotsup}, state}

  defp handle_request({:get_until, _encoding, _prompt, _module, _function, _arguments}, state),
    do: {{:error, :enotsup}, state}

  defp handle_request({:setopts, []}, state), do: {:ok, state}
  defp handle_request({:setopts, _options}, state), do: {{:error, :enotsup}, state}
  defp handle_request(:getopts, state), do: {[], state}

  defp handle_request(_request, state), do: {{:error, :request}, state}

  defp put_chars(chars, encoding, state) do
    case decode_characters(chars, encoding) do
      {:ok, chars} ->
        state = Enum.reduce(chars, state, &put_character/2) |> schedule_render()
        {:ok, state}

      :error ->
        {{:error, :put_chars}, state}
    end
  end

  defp put_chars(module, function, arguments, encoding, state) do
    put_chars(apply(module, function, arguments), encoding, state)
  rescue
    _exception -> {{:error, :put_chars}, state}
  catch
    _kind, _reason -> {{:error, :put_chars}, state}
  end

  defp decode_characters(chars, encoding) when encoding in [:unicode, :latin1] do
    case :unicode.characters_to_list(chars, encoding) do
      characters when is_list(characters) -> {:ok, characters}
      _error -> :error
    end
  end

  defp decode_characters(_chars, _encoding), do: :error

  defp put_character(?\n, state), do: newline(state)
  defp put_character(?\r, state), do: %{state | column: 0}
  defp put_character(?\b, %{column: 0} = state), do: state
  defp put_character(?\b, state), do: %{state | column: state.column - 1}

  defp put_character(?\t, state) do
    spaces = 8 - rem(state.column, 8)
    Enum.reduce(1..spaces, state, fn _, state -> put_character(?\s, state) end)
  end

  defp put_character(character, %{columns: columns, column: columns} = state) do
    put_character(character, newline(state))
  end

  defp put_character(character, state) do
    current_line = replace_character(state.current_line, state.column, character)
    %{state | current_line: current_line, column: state.column + 1}
  end

  defp replace_character(line, column, character) when column < length(line),
    do: List.replace_at(line, column, character)

  defp replace_character(line, column, character),
    do: line ++ List.duplicate(?\s, column - length(line)) ++ [character]

  defp newline(state) do
    %{
      state
      | lines: CircularBuffer.insert(state.lines, state.current_line),
        current_line: [],
        column: 0
    }
  end

  defp schedule_render(%{render_pending: true} = state), do: state

  defp schedule_render(state) do
    Process.send_after(self(), :render, @render_delay)
    %{state | render_pending: true}
  end

  defp render(state) do
    {left, top, _right, _bottom} = state.margins

    image = :egd.create(state.width, state.height)
    renderer_state = state.renderer.draw_background(image, state.renderer_state)

    state.lines
    |> CircularBuffer.to_list()
    |> Kernel.++([state.current_line])
    |> Enum.with_index()
    |> Enum.each(fn {line, row} ->
      :egd.text(
        image,
        {left, top + row * state.font_height},
        state.font,
        line,
        state.font_color
      )
    end)

    renderer_state = state.renderer.render_image(image, renderer_state)
    :egd.destroy(image)

    %{state | renderer_state: renderer_state}
  end
end
