local wezterm = require("wezterm")
local config = wezterm.config_builder()

-- Keep the title bar hidden while retaining the native resize affordance.
config.window_decorations = "RESIZE"
config.window_background_opacity = 0.8
config.macos_window_background_blur = 50

return config
