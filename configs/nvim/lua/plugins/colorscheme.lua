return {
  {
    "folke/tokyonight.nvim",
    opts = {
      transparent = true, -- Main transparent flag
      styles = {
        sidebars = "transparent", -- Make sidebars (like nvim-tree) transparent
        floats = "transparent",   -- Make floating windows (like LSP info) transparent
      },
    },
  },
}
