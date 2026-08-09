# App Settings

`AppSettings` stores preferences in the operating system's normal per-user
configuration directory:

- Linux/BSD: `$XDG_CONFIG_HOME/<app>`, or `~/.config/<app>`
- Windows: `%APPDATA%\<app>`, falling back to `%LOCALAPPDATA%`
- macOS: `~/Library/Application Support/<app>`

The add-on creates an `AppSettings` autoload. Values are kept in a human-readable
`settings.cfg` file and saved atomically, with the previous copy retained as
`settings.cfg.bak`.

```gdscript
AppSettings.set_value("window", "maximized", true)
var maximized := AppSettings.get_value("window", "maximized", false)
```

Saving is immediate by default. To batch writes, pass `false` and call `save()`
once:

```gdscript
AppSettings.set_value("audio", "master_volume", 0.8, false)
AppSettings.set_value("audio", "muted", false, false)
AppSettings.save()
```

Useful paths and helpers:

```gdscript
print(AppSettings.config_directory_path)
print(AppSettings.settings_file_path)
var layouts_path := AppSettings.get_file_path("layouts")
AppSettings.open_config_directory()
```

The directory name and the environment variable used to override the complete
path are configurable under **Project Settings > App Settings**. They default
to values derived from the application name. This project configures
`spellbreak-modkit` and `SPELLBREAK_MODKIT_CONFIG_DIR`.
