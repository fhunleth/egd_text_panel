# SPDX-FileCopyrightText: 2026 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule EgdTextPanelTest do
  use ExUnit.Case
  doctest EgdTextPanel

  @test_width 320
  @test_height 240

  defmodule Renderer do
    @behaviour EgdTextPanel.Renderer

    @impl true
    def draw_background(image, state) do
      :egd.filledRectangle(
        image,
        {0, 0},
        {319, 239},
        :egd.color({255, 255, 255})
      )

      state
    end

    @impl true
    def render_image(image, state) do
      send(state.pid, {:png, :egd.render(image, :png)})
      state
    end
  end

  test "basic functionality" do
    panel =
      start_supervised!(
        {EgdTextPanel,
         renderer: __MODULE__.Renderer,
         renderer_state: %{pid: self()},
         width: @test_width,
         height: @test_height,
         margins: {4, 4, 4, 4}}
      )

    IO.puts(panel, """
    This is a simple text panel for EGD that lets you use IO.puts to send text to it.

    panel = EgdTextPanel.start_link(options...)
    IO.puts(panel, "Hello, world!")

    EgdTextPanel collects output and calls a user-provided function to to render it.
    """)

    assert_receive {:png, result}, 500

    # FIX: Actually check when it's right
    File.write("out.png", result)
  end
end
