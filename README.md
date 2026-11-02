# qmake-tools.nvim

Build, run, and use qmake projects in Neovim with clangd (LSP) – modeled after
[cmake-tools.nvim](https://github.com/Civitasv/cmake-tools.nvim).

- `:QMakeGenerate` runs qmake and creates a `compile_commands.json`
  (via `compiledb` or the built-in generator)
- the file is linked into the project root and clangd is restarted automatically
- build output runs asynchronously into the quickfix list (errors can be jumped to directly with `:cn`/`:cp`)
- Debug/Release builds in separate directories, switchable
- `:QMakeRun` builds and starts the program in a terminal split
- also works with `TEMPLATE = subdirs` (multiple programs → selection)
- saving a `.pro`/`.pri` updates the database automatically
- Linux, macOS, and Windows (MinGW, LLVM-MinGW, MSVC) – see [Windows](#windows)

## Requirements

- Neovim ≥ 0.10
- `qmake` / `qmake6`, `make` (on Windows: see [Windows](#windows))
- optionally `compiledb` (`pip install compiledb`) or `bear` – without either, the
  built-in generator reads the Makefiles directly
- `clangd` as the language server

Check with `:checkhealth qmake-tools`.

### How qmake is found

Each configuration uses the qmake of its kit. Automatically detected are:
`$QMAKE`, `qmake`/`qmake-qt5`/`qmake6` in PATH, `~/Qt/<version>/gcc_64/bin` (online installer),
`/opt/Qt/...`, `/usr/lib/qt5/bin`, `/usr/lib/qt6/bin`, Homebrew, and others. If none of these
is found, the shell configuration (`.bashrc`, `.zshrc`, `.profile`) is queried for aliases and
PATH entries. On Windows: `<drive>:\Qt\…` on all drives, see
[Windows](#windows). Everything else under [Kits](#kits).

## Installation

**lazy.nvim**

```lua
return {
  {
    "drook207/qmake-tools.nvim",
    -- local checkout instead: dir = "~/Projects/qmake-tools.nvim",
    name = "qmake-tools.nvim",
    lazy = true,
    ft = { "c", "cpp", "qmake" },
    cmd = {
      "QMakeGenerate", "QMakeBuild", "QMakeRun", "QMakeClean", "QMakeRebuild",
      "QMakeStop", "QMakeOpenExecutor", "QMakeCloseExecutor", "QMakeToggleExecutor",
      "QMakeInfo", "QMakeArgs", "QMakeArgsAdd", "QMakeRunArgs",
      "QMakeSelectBuildType", "QMakeSelectTarget", "QMakeSelectProject",
      "QMakeSelectConfig", "QMakeConfigNew", "QMakeConfigRename", "QMakeConfigDelete",
      "QMakeSelectKit", "QMakeKits", "QMakeKitAdd", "QMakeKitRemove",
    },
    opts = {},
    keys = {
      -- core workflow
      { "<leader>Qg", "<cmd>QMakeGenerate<cr>", desc = "Generate" },
      { "<leader>Qb", "<cmd>QMakeBuild<cr>", desc = "Build" },
      { "<leader>QB", "<cmd>QMakeRebuild<cr>", desc = "Clean + Build" },
      { "<leader>Qr", "<cmd>QMakeRun<cr>", desc = "Run target" },
      { "<leader>Qc", "<cmd>QMakeClean<cr>", desc = "Clean" },
      { "<leader>Ql", "<cmd>QMakeRunArgs<cr>", desc = "Set launch args" },

      -- qmake arguments
      { "<leader>Qae", "<cmd>QMakeArgs<cr>", desc = "Edit qmake args" },
      { "<leader>Qaa", ":QMakeArgsAdd ", desc = "Add qmake arg" },
      { "<leader>Qax", "<cmd>QMakeArgs!<cr>", desc = "Clear qmake args" },

      -- selection menus
      { "<leader>Qst", "<cmd>QMakeSelectBuildType<cr>", desc = "Select build type" },
      { "<leader>Qsl", "<cmd>QMakeSelectTarget<cr>", desc = "Select launch target" },
      { "<leader>Qsp", "<cmd>QMakeSelectProject<cr>", desc = "Select .pro file" },
      { "<leader>Qsk", "<cmd>QMakeSelectKit<cr>", desc = "Select kit" },
      { "<leader>Qsc", "<cmd>QMakeSelectConfig<cr>", desc = "Select config" },

      -- configurations
      { "<leader>QCn", "<cmd>QMakeConfigNew<cr>", desc = "New config" },
      { "<leader>QCs", "<cmd>QMakeSelectConfig<cr>", desc = "Select config" },
      { "<leader>QCr", "<cmd>QMakeConfigRename<cr>", desc = "Rename config" },
      { "<leader>QCd", "<cmd>QMakeConfigDelete<cr>", desc = "Delete config" },

      -- kits
      { "<leader>QKl", "<cmd>QMakeKits<cr>", desc = "List kits" },
      { "<leader>QKs", "<cmd>QMakeKits!<cr>", desc = "Rescan kits" },
      { "<leader>QKa", "<cmd>QMakeKitAdd<cr>", desc = "Add kit" },
      { "<leader>QKr", "<cmd>QMakeKitRemove<cr>", desc = "Remove kit" },

      -- build type directly
      { "<leader>Qtd", "<cmd>QMakeSelectBuildType Debug<cr>", desc = "Debug" },
      { "<leader>Qtr", "<cmd>QMakeSelectBuildType Release<cr>", desc = "Release" },

      -- window / process
      { "<leader>Qe", "<cmd>QMakeToggleExecutor<cr>", desc = "Toggle executor" },
      { "<leader>Qoe", "<cmd>QMakeOpenExecutor<cr>", desc = "Open executor" },
      { "<leader>Qoq", "<cmd>botright copen<cr>", desc = "Open quickfix" },
      { "<leader>Qxe", "<cmd>QMakeCloseExecutor<cr>", desc = "Close executor" },
      { "<leader>Qxq", "<cmd>cclose<cr>", desc = "Close quickfix" },
      { "<leader>QX", "<cmd>QMakeStop<cr>", desc = "Stop build" },

      -- misc
      { "<leader>Qi", "<cmd>QMakeInfo<cr>", desc = "Info" },
      { "<leader>QS", "<cmd>checkhealth qmake-tools<cr>", desc = "Health check" },
    },
  },
  {
    "folke/which-key.nvim",
    opts = {
      spec = {
        { "<leader>Q", group = "QMake", icon = "󰙲" },
        { "<leader>Qa", group = "qmake args" },
        { "<leader>Qs", group = "select" },
        { "<leader>Qt", group = "build type" },
        { "<leader>Qo", group = "open" },
        { "<leader>Qx", group = "close" },
        { "<leader>QC", group = "configs" },
        { "<leader>QK", group = "kits" },
      },
    },
  },
}
```

**Without a plugin manager**: copy the folder to
`~/.local/share/nvim/site/pack/plugins/start/qmake-tools.nvim`.

## Kits and configurations

As in Qt Creator, there are two levels:

- **Kit** = a Qt version including toolchain and environment (e.g. "Qt 5.12 Desktop",
  "Qt 5.15 Raspberry Pi"). Kits are global for all projects.
- **Configuration** = per project, a named combination of kit, build type,
  qmake arguments, and run arguments. Each has its own build directory,
  so switching is immediate without rebuilding.

### Kits

Installed Qt versions are detected automatically (`~/Qt/<version>/…`,
`/usr/lib/qt5/bin`, PATH, …). Custom kits go in `setup()`:

```lua
opts = {
  default_kit = "Qt 5.15 Desktop",     -- for new configurations
  kits = {
    { name = "Qt 5.15 Desktop", qmake = "~/Qt/5.15.2/gcc_64/bin/qmake" },
    { name = "Qt 5.12 Desktop", qmake = "~/Qt/5.12.12/gcc_64/bin/qmake" },

    -- Cross-compile with a custom Qt installation and toolchain in PATH
    { name = "Raspberry Pi 4",
      qmake = "/opt/qt5pi/bin/qmake",
      spec = "devices/linux-rasp-pi4-v3d-g++",          -- optional, otherwise the default spec of the Qt installation
      path = { "/opt/cross-pi-gcc/bin" },               -- prepend to PATH
      env = { PKG_CONFIG_SYSROOT_DIR = "/opt/rpi-sysroot" },
      run = false },                                     -- do not run locally

    -- Yocto/Boot2Qt SDK: environment script is sourced first
    { name = "Yocto aarch64",
      qmake = "qmake",                                   -- looked up in the script's PATH
      env_script = "/opt/poky/4.0/environment-setup-cortexa72-poky-linux",
      run_prefix = { "qemu-aarch64", "-L", "/opt/poky/4.0/sysroots/cortexa72-poky-linux" } },
  },
}
```

| Field | Meaning |
|---|---|
| `name` | Display name (required) |
| `qmake` | Path to qmake or name in the kit's PATH (required) |
| `spec` | mkspec, passed as `-spec` |
| `path` | Directories prepended to `PATH` |
| `env` | additional variables, `${VAR}` is expanded |
| `env_script` | shell script sourced first (Yocto, Boot2Qt, …); on Windows also `.bat`/`.cmd`, with arguments as a list |
| `make` | different make program (default: matching the toolchain) |
| `toolchain` | Windows: `false` = do not search for the compiler automatically |
| `vcvarsall` | Windows/MSVC: path to `vcvarsall.bat` (default: via vswhere), `false` = do not load |
| `msvc_arch` | Windows/MSVC: argument for `vcvarsall.bat` (default: from the Qt installation, e.g. `x64`) |
| `qmake_args` | additional qmake arguments for this kit only |
| `run` | `false` = `:QMakeRun` is disabled |
| `run_prefix` | prepended when running, e.g. qemu or an ssh script |

Kits can also be registered without a configuration file; they are then stored in
`stdpath("data")/qmake-tools-kits.json`:

```vim
:QMakeKitAdd "Qt 5.9 Legacy" /opt/Qt5.9.9/5.9.9/gcc_64/bin/qmake
:QMakeKitAdd                       " prompts for path and name
:QMakeKits                         " all kits with version, source, and problems
:QMakeKits!                        " rescan installations
```

### Configurations

```vim
:QMakeConfigNew pi                 " copy of the active configuration, then choose kit
:QMakeSelectKit Raspberry Pi 4     " change the kit of the active configuration
:QMakeSelectConfig                 " switch between configurations
:QMakeConfigRename / :QMakeConfigDelete
```

Build type, qmake arguments, and run arguments each belong to the active
configuration. When switching, the matching `compile_commands.json` is linked
and clangd is restarted. Regeneration only happens if none exists for the
configuration yet.

The build directory defaults to `build/<configuration>/<kit>-<build-type>`,
e.g. `build/pi/raspberry-pi-4-release`. Customizable via `build_dir` with the placeholders
`${config}`, `${kit}`, `${build_type}`, and `${build_type_lower}`.

### Cross-compiling and clangd

`compile_commands.json` contains the full path to the cross compiler. For clangd
to find its system headers and sysroot, it must be allowed to query the compiler:

```lua
vim.lsp.config("clangd", {
  cmd = { "clangd", "--query-driver=/opt/cross-pi-gcc/bin/*,/opt/poky/**/bin/*" },
})
```

Without `--query-driver`, clangd reports missing standard headers for cross configurations.

## Windows

On Windows, the plugin sets up the build environment like Qt Creator – without a
"Developer Command Prompt" and without the compiler in PATH:

- **Qt installations** are found on all drives: `C:\Qt`, `D:\Qt`, …
  (`<Version>\mingw*`, `<Version>\llvm-mingw*`, `<Version>\msvc*`, including nested
  offline installations such as `D:\Qt\5.12.12\5.12.12\mingw73_64`). Android and
  WebAssembly builds are skipped, ARM64 Qt on x64 machines is marked as a cross kit.
- **MinGW / LLVM-MinGW**: the matching compiler from `<Qt-Root>\Tools` is added to PATH
  (`mingw81_64` → `Tools\mingw810_64`, `mingw73_64` → `Tools\mingw730_64`, Qt 6
  `mingw_64` → newest `Tools\mingw*_64`). make is `mingw32-make`.
- **MSVC**: `vcvarsall.bat` from the newest Visual Studio installation (via `vswhere`) is
  loaded with the architecture of the Qt installation (`msvc2019_64` → `x64`). Building uses
  `jom` from Qt Creator (parallel), otherwise `nmake`. qmake gets `-FC` so errors with
  full paths end up in the quickfix list. Loading takes a few seconds and
  happens once per session and architecture.
- The `bin` directory of the Qt version is in PATH when building and running. At runtime,
  the directories of DLLs built in the project are added (instead of `LD_LIBRARY_PATH`).
- As in Qt Creator, qmake creates `Makefile.Debug`/`Makefile.Release`; programs are located
  in `debug\` and `release\` respectively and found there.
- `compile_commands.json` is created by the built-in generator (compiledb only understands
  GNU make, `bear` is not available for Windows). With MinGW it contains the full
  compiler path; clangd then needs `--query-driver`:

```lua
vim.lsp.config("clangd", {
  cmd = { "clangd", "--query-driver=D:/Qt/Tools/**/bin/*.exe" },
})
```

A kit can still be created manually as usual – the toolchain is added
automatically anyway. To customize deviations:

```lua
kits = {
  -- MinGW outside the Qt installation
  { name = "Qt 5.15 MinGW", qmake = "D:/Qt/5.15.2/mingw81_64/bin/qmake.exe", path = { "C:/mingw64/bin" } },
  -- specific Visual Studio version
  { name = "Qt 5.15 MSVC", qmake = "D:/Qt/5.15.2/msvc2019_64/bin/qmake.exe",
    vcvarsall = "C:/Program Files/Microsoft Visual Studio/2019/Professional/VC/Auxiliary/Build/vcvarsall.bat" },
}
```

`:checkhealth qmake-tools` shows per kit which compiler and which make
are used, `:QMakeInfo` the same for the active configuration.

## Commands

| Command | Function |
|---|---|
| `:QMakeGenerate` | run qmake, generate and link `compile_commands.json` |
| `:QMakeBuild [target]` | build (generates automatically first if needed) |
| `:QMakeRun` | build and run the program in a terminal |
| `:QMakeArgs [args]` | set additional qmake arguments for this project; without arguments: edit; `:QMakeArgs!` clears |
| `:QMakeArgsAdd args` | append qmake arguments |
| `:QMakeRunArgs [args]` | set run arguments; without arguments: edit; `:QMakeRunArgs!` clears |
| `:QMakeSelectBuildType [Debug\|Release]` | switch build type |
| `:QMakeSelectTarget` | choose program (when there are multiple executables) |
| `:QMakeSelectProject` | choose `.pro` file (when there are multiple in the root) |
| `:QMakeSelectConfig [name]` | switch configuration |
| `:QMakeConfigNew [name]` / `:QMakeConfigRename [name]` / `:QMakeConfigDelete [name]` | manage configurations |
| `:QMakeSelectKit [name]` | choose kit of the active configuration |
| `:QMakeKits[!]` | show kits (`!` = rescan) |
| `:QMakeKitAdd ["Name" qmake [spec]]` / `:QMakeKitRemove [name]` | register / remove kits |
| `:QMakeClean` / `:QMakeRebuild` | `make clean` / clean + build |
| `:QMakeStop` | cancel the running operation |
| `:QMakeOpenExecutor[!]` | open the output window and jump into it (`!` = keep focus) |
| `:QMakeCloseExecutor` / `:QMakeToggleExecutor` | close / toggle the output window |
| `:QMakeInfo` | show current settings |

`.pro` file, configurations, and active configuration are stored per project
(`stdpath("data")/qmake-tools.json`). State from older versions is migrated automatically
into a configuration `default`.

### qmake arguments per project

```vim
:QMakeArgs DEFINES+=MY_FLAG CONFIG+=c++20       " set (replaces existing)
:QMakeArgsAdd CONFIG+=sanitizer                 " append
:QMakeArgs                                      " edit current arguments in the input field
:QMakeArgs!                                     " clear all
:QMakeArgs -spec linux-clang                    " <Tab> after -spec lists the mkspecs
```

- Arguments are split like in the shell: `"..."` or `'...'` group spaces.
- They apply to the active configuration (all build types) and are placed in the qmake invocation
  after `qmake_args`, the kit's `qmake_args`, and `build_type_args`, so they take precedence.
- After every change, the database is regenerated automatically (if a build already exists),
  so clangd gets the new flags.
- `:QMakeInfo` shows the complete qmake invocation.
- `<Tab>` completes common entries such as `CONFIG+=c++20` or `QMAKE_CXXFLAGS+=`.

## Executor (output window)

qmake, compiledb, and make write their output live into a dedicated window,
like the executor of cmake-tools. Errors, warnings, and sections are color-highlighted,
the status line shows the state (⟳ running, ✓ done, ✗ error).

In the window:

| Key | Function |
|---|---|
| `<CR>` | jump to the error location under the cursor |
| `]e` / `[e` | next / previous error |
| `<C-c>` | cancel the running operation |
| `q` | close the window |

The window scrolls along as long as the cursor is at the end. If you scroll up to
read something, the view stays put. The quickfix list is always filled as well,
so `:cnext` and `:cprev` keep working.

The test-run output of `compiledb` (`make -n`) is only shown on an error;
otherwise a summary such as `compile_commands.json: 12 files` appears.

## Configuration (defaults)

```lua
require("qmake-tools").setup({
  kits = {},                       -- see Kits section
  default_kit = nil,               -- nil = first local kit
  detect_kits = true,              -- automatically offer installed Qt versions
  make_executable = nil,           -- nil = matching the toolchain (make, mingw32-make, jom, nmake)
  default_config = "default",      -- name of the first configuration
  build_dir = "build/${config}/${kit}-${build_type_lower}",
  build_types = { "Debug", "Release" },
  default_build_type = "Debug",
  qmake_args = {},                 -- e.g. { "-spec", "linux-clang" }
  build_type_args = {
    Debug = { "CONFIG+=debug", "CONFIG+=qml_debug" },
    Release = { "CONFIG+=release" },
  },
  jobs = nil,                      -- nil = number of CPU cores
  compile_commands = "auto",       -- "auto" | "compiledb" | "builtin" | "bear" | false
  link_compile_commands = true,
  restart_clangd = true,
  regenerate_on_save = true,
  build_before_run = true,
  add_library_search_paths = true, -- build libs + Qt libs in LD_LIBRARY_PATH or PATH (like Qt Creator)
  executor = {
    enabled = true,
    open = "always",               -- "always" | "on_error" | "never"
    position = "bottom",           -- "bottom" | "top" | "right" | "left"
    size = 15,                     -- height or width
    focus = false,                 -- jump into it when opening
    wrap = false,
    close_on_success = false,      -- close automatically after success
    close_on_success_delay = 1500, -- ms
  },
  open_quickfix = "never",         -- "always" | "on_error" | "never"
  errorformat = nil,               -- nil = built-in (gcc/clang, MSVC, qmake, make -w)
  terminal_height = 15,
})
```

More build types are easy to add:

```lua
opts = {
  build_types = { "Debug", "Release", "Profile" },
  build_type_args = { Profile = { "CONFIG+=release", "CONFIG+=force_debug_info" } },
}
```

## Keymaps (example)

```lua
vim.keymap.set("n", "<leader>qg", "<cmd>QMakeGenerate<cr>", { desc = "qmake generate" })
vim.keymap.set("n", "<leader>qb", "<cmd>QMakeBuild<cr>",    { desc = "qmake build" })
vim.keymap.set("n", "<leader>qr", "<cmd>QMakeRun<cr>",      { desc = "qmake run" })
vim.keymap.set("n", "<leader>qt", "<cmd>QMakeSelectBuildType<cr>", { desc = "qmake build type" })
```

## Statusline (lualine)

```lua
lualine_x = {
  { function() return require("qmake-tools").statusline() end,
    cond = function() return require("qmake-tools").is_qmake_project() end },
}
```

## Setting up clangd

```lua
-- Neovim 0.11+
vim.lsp.enable("clangd")
```

clangd finds the linked `compile_commands.json` in the project root. Without a
`.git` directory in the project, the file should be generated once with `:QMakeGenerate`
before opening a source file for the first time, so clangd recognizes the root.
`compile_commands.json` belongs in `.gitignore`.

## Notes

- qmake runs with `-r` so that with `subdirs` projects all sub-Makefiles exist
  immediately and `compiledb` finds all source files without a prior build.
- Files generated by moc (`moc_*.cpp`) only appear in the database after the first build.
  This only affects these generated files, not your sources.
- With `compile_commands = "bear"`, the database is recorded during the actual build
  instead of at `:QMakeGenerate`.
- `compile_commands = "auto"` uses `compiledb` if it is installed and the kit
  uses GNU make, otherwise the built-in generator (`"builtin"`). The latter reads CC/CXX,
  flags, DEFINES, INCPATH, and SOURCES from the Makefiles generated by qmake.
- The end of every operation triggers `User QMakeToolsDone` (`data = { title, ok }`),
  e.g. for custom notifications.
