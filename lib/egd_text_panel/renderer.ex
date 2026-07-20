# SPDX-FileCopyrightText: 2026 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0
defmodule EgdTextPanel.Renderer do
  @moduledoc """
  Behaviour for rendering terminal output to an EGD image
  """

  @typedoc ":egd.egd_image()"
  @type egd_image() :: pid()

  @typedoc """
  Renderer state

  Initial state comes from the `:renderer_state` option that was passed to
  `EgdTextPanel.start_link/1`.
  """
  @type state() :: term()

  @doc """
  Called before the text is drawn
  """
  @callback draw_background(egd_image(), state()) :: state()

  @doc """
  Render the final image
  """
  @callback render_image(egd_image(), state()) :: state()
end
