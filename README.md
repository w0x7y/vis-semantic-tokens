# vis-semantic-tokens

lsp semantic token highlighting for [vis](https://github.com/martanne/vis) and [vis-lspc](https://git.sr.ht/~mcepl/vis-lspc). hooks into any `vis-lspc` setup without patching it, and layers semantic highlights over vis's lpeg lexer or [vis-treesitter](https://github.com/w0x7y/vis-treesitter)

### install

needs vis `0.9` or later and `vis-lspc`

```sh
git clone https://github.com/w0x7y/vis-semantic-tokens ~/.config/vis/plugins/vis-semantic-tokens
```

then in `visrc.lua`:

```lua
require("plugins/vis-lspc")
require("plugins/vis-semantic-tokens")
```

it finds `vis-lspc` automatically in `package.loaded` (regardless of require order). if you load `vis-lspc` under a custom module path, pass it directly:

```lua
local lspc = require("my/path/to/vis-lspc")
require("plugins/vis-semantic-tokens").attach(lspc)
```

### what it does

~ advertises `textDocument.semanticTokens` and `workspace.semanticTokens.refreshSupport` in `vis-lspc`'s initialize capabilities\
~ requests `textDocument/semanticTokens/full` on file open, `didChange`, save, and `workspace/semanticTokens/refresh`\
~ decodes utf-16 delta-encoded tokens and only paints ranges whose text still matches the buffer\
~ skips `variable`, `property`, `keyword`, `comment`, `string`, `number` and `operator` by default so tree-sitter's finer keyword and punctuation colors stay intact\
~ works with standard lsp token names and roslyn/omnisharp names (`class name`, `method name`, etc.)\
~ adds `:semantic-tokens-refresh` to force a refresh

### config

```lua
local st = require("plugins/vis-semantic-tokens")
st.max_size = 512 * 1024
st.styles["class"] = "fore:yellow"
st.styles["function.defaultLibrary"] = "fore:cyan"
st.styles["parameter"] = false -- leave to the base highlighter
```

unset entries fall back to `vis.lexers.STYLE_*`, so any vis theme works without extra setup

_license: [mit](./LICENSE)_
