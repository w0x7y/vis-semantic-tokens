-- vis-semantic-tokens: LSP semantic token highlighting for vis-lspc.
-- Hooks into any vis-lspc setup without patching it: advertises semanticTokens
-- capabilities, requests textDocument/semanticTokens/full on open and change,
-- handles workspace/semanticTokens/refresh, and layers semantic highlights over
-- vis's base syntax highlighter (LPeg or vis-treesitter).

local M = {
  enabled = true,
  max_size = 512 * 1024,
  -- Style overrides keyed by LSP tokenType, "tokenType.modifier", or "modifier".
  -- Set a key to false to explicitly skip highlighting that token type.
  styles = {},
}

-- Self-contained style compatibility (vis 0.9 vs later vis.ui)
local ui = vis.ui
local STYLE_ID = ui.style_push and ui:style_push() or 56

local function define_style(win, id, spec)
  if ui.style_define then
    return ui:style_define(id, spec)
  end
  return win:style_define(id, spec)
end

local CLIENT_TOKEN_TYPES = {
  "namespace",
  "type",
  "class",
  "enum",
  "interface",
  "struct",
  "typeParameter",
  "parameter",
  "variable",
  "property",
  "enumMember",
  "event",
  "function",
  "method",
  "macro",
  "keyword",
  "modifier",
  "comment",
  "string",
  "number",
  "regexp",
  "operator",
  "decorator",
}

local CLIENT_TOKEN_MODIFIERS = {
  "declaration",
  "definition",
  "readonly",
  "static",
  "deprecated",
  "abstract",
  "async",
  "modification",
  "documentation",
  "defaultLibrary",
}

-- Map LSP semantic token types (and Roslyn/OmniSharp + rust-analyzer variants)
-- to vis.lexers STYLE_* keys. Types omitted here (variable, property, keyword,
-- comment, string, number, operator) are left to the base highlighter so
-- finer-grained grammar distinctions (e.g. conditional vs return keywords) stay intact.
local TOKEN_TYPE_STYLES = {
  -- Standard LSP types
  namespace = { "STYLE_MODULE", "STYLE_TYPE" },
  type = { "STYLE_TYPE" },
  class = { "STYLE_CLASS", "STYLE_TYPE" },
  enum = { "STYLE_TYPE" },
  interface = { "STYLE_TYPE" },
  struct = { "STYLE_TYPE" },
  typeParameter = { "STYLE_TYPE" },
  builtinType = { "STYLE_TYPE_BUILTIN", "STYLE_TYPE" },
  parameter = { "STYLE_VARIABLE_PARAMETER", "STYLE_VARIABLE" },
  enumMember = { "STYLE_CONSTANT" },
  ["function"] = { "STYLE_FUNCTION" },
  method = { "STYLE_FUNCTION" },
  macro = { "STYLE_FUNCTION_MACRO", "STYLE_FUNCTION_BUILTIN", "STYLE_PREPROCESSOR" },
  decorator = { "STYLE_ANNOTATION", "STYLE_ATTRIBUTE" },
  selfKeyword = { "STYLE_VARIABLE_BUILTIN" },
  lifetime = { "STYLE_LIFETIME", "STYLE_CONSTANT" },

  -- Type + modifier specializations
  ["variable.defaultLibrary"] = { "STYLE_VARIABLE_BUILTIN" },
  ["function.defaultLibrary"] = { "STYLE_FUNCTION_BUILTIN", "STYLE_FUNCTION" },
  ["method.defaultLibrary"] = { "STYLE_FUNCTION_BUILTIN", "STYLE_FUNCTION" },
  ["class.defaultLibrary"] = { "STYLE_TYPE_BUILTIN", "STYLE_CLASS", "STYLE_TYPE" },
  ["type.defaultLibrary"] = { "STYLE_TYPE_BUILTIN", "STYLE_TYPE" },

  -- Roslyn / OmniSharp non-standard semantic token names
  ["namespace name"] = { "STYLE_MODULE", "STYLE_TYPE" },
  ["class name"] = { "STYLE_CLASS", "STYLE_TYPE" },
  ["record class name"] = { "STYLE_CLASS", "STYLE_TYPE" },
  ["struct name"] = { "STYLE_TYPE" },
  ["record struct name"] = { "STYLE_TYPE" },
  ["interface name"] = { "STYLE_TYPE" },
  ["enum name"] = { "STYLE_TYPE" },
  ["delegate name"] = { "STYLE_TYPE" },
  ["type parameter name"] = { "STYLE_TYPE" },
  ["method name"] = { "STYLE_FUNCTION" },
  ["extension method name"] = { "STYLE_FUNCTION" },
  ["enum member name"] = { "STYLE_CONSTANT" },
  ["constant name"] = { "STYLE_CONSTANT" },
}

-- Percent-encode a POSIX file path as a file:// URI (matching vis-lspc)
local function path_to_uri(path)
  return "file://" .. path:gsub("[^%w/._~-]", function(ch)
    return string.format("%%%02X", ch:byte())
  end)
end

-- Build 0-based byte start offsets for each 0-based line in text
local function index_lines(text)
  local starts = { [0] = 0 }
  local lengths = {}
  local line = 0
  local pos = 1
  local n = #text
  while pos <= n do
    local nl = text:find("\n", pos, true)
    if not nl then
      lengths[line] = n - pos + 1
      return starts, lengths, line + 1
    end
    lengths[line] = nl - pos
    line = line + 1
    starts[line] = nl -- 0-based byte offset after '\n'
    pos = nl + 1
  end
  lengths[line] = 0
  return starts, lengths, line + 1
end

-- Convert a UTF-16 code-unit offset within a UTF-8 line slice to a 0-based byte offset
local function utf16_to_byte(text, line_start, line_len, target_u16)
  if target_u16 <= 0 or line_len <= 0 then
    return 0
  end
  local i = 0
  local u16 = 0
  while i < line_len and u16 < target_u16 do
    local b = text:byte(line_start + i + 1)
    if b < 0x80 then
      i = i + 1
      u16 = u16 + 1
    elseif b < 0xE0 then
      i = i + 2
      u16 = u16 + 1
    elseif b < 0xF0 then
      i = i + 3
      u16 = u16 + 1
    else
      i = i + 4
      u16 = u16 + 2
    end
  end
  return i
end

-- Decode LSP delta-encoded semantic token integers against the snapshot text
local function decode_tokens(data, legend, text)
  local token_types = legend and legend.tokenTypes
  local token_mods = legend and legend.tokenModifiers or {}
  if not token_types or not data or #data < 5 then
    return {}
  end

  local line_starts, line_lens, line_count = index_lines(text)
  local tokens = {}
  local line = 0
  local char = 0
  local n = #data

  for i = 1, n - 4, 5 do
    local dline = data[i]
    local dstart = data[i + 1]
    local length = data[i + 2]
    local type_idx = data[i + 3]
    local mod_bits = data[i + 4]

    if dline > 0 then
      line = line + dline
      char = dstart
    else
      char = char + dstart
    end

    local ttype = token_types[type_idx + 1]
    if ttype and length > 0 and line < line_count then
      local lstart = line_starts[line]
      local llen = line_lens[line] or 0
      -- Fast path: check if line slice is pure ASCII
      local slice = text:sub(lstart + 1, lstart + llen)
      local bstart, bend
      if not slice:find("[\128-\255]") then
        bstart = lstart + char
        bend = bstart + length
      else
        bstart = lstart + utf16_to_byte(text, lstart, llen, char)
        bend = lstart + utf16_to_byte(text, lstart, llen, char + length)
      end

      if bend > bstart and bend <= #text then
        local mods = nil
        if mod_bits and mod_bits > 0 then
          mods = {}
          local bit = 1
          for mi = 1, #token_mods do
            if math.floor(mod_bits / bit) % 2 == 1 then
              mods[#mods + 1] = token_mods[mi]
            end
            bit = bit * 2
          end
        end

        tokens[#tokens + 1] = {
          start = bstart,
          len = bend - bstart,
          text = text:sub(bstart + 1, bend),
          type = ttype,
          mods = mods,
        }
      end
    end
  end

  return tokens
end

local function lookup_lexers(keys)
  local lexers = vis.lexers
  if type(lexers) ~= "table" then
    return nil
  end
  for _, key in ipairs(keys) do
    local s = rawget(lexers, key)
    if type(s) == "string" and s ~= "" then
      return s
    end
  end
  for _, key in ipairs(keys) do
    local s = lexers[key]
    if type(s) == "string" and s ~= "" then
      return s
    end
  end
  return nil
end

-- Resolve a token's (type, mods) into a vis style string, or nil to skip
local function resolve_style(ttype, mods)
  -- 1. Explicit user/theme overrides in M.styles
  if mods then
    for _, m in ipairs(mods) do
      local key = ttype .. "." .. m
      local s = M.styles[key]
      if s ~= nil then
        return s or nil
      end
    end
  end
  if M.styles[ttype] ~= nil then
    return M.styles[ttype] or nil
  end

  -- 2. Built-in type+modifier mapping via vis.lexers
  if mods then
    for _, m in ipairs(mods) do
      local keys = TOKEN_TYPE_STYLES[ttype .. "." .. m]
      if keys then
        local s = lookup_lexers(keys)
        if s then
          return s
        end
      end
    end
  end

  -- 3. Built-in type mapping via vis.lexers
  local keys = TOKEN_TYPE_STYLES[ttype]
  if keys then
    return lookup_lexers(keys)
  end

  return nil
end

-- Per-path cache: path -> { tokens = {...}, inflight = bool, dirty = bool, ls = ls }
local cache = {}
local attached_lspc = nil

local function find_window_for_path(path)
  for win in vis:windows() do
    if win.file and win.file.path == path then
      return win
    end
  end
end

local function supports_full(ls)
  local p = ls and ls.capabilities and ls.capabilities.semanticTokensProvider
  if type(p) ~= "table" or type(p.legend) ~= "table" then
    return false
  end
  if p.full == false then
    return false
  end
  return p.full ~= nil or p.range == nil
end

local function request_tokens(ls, file)
  if not M.enabled or not ls or not ls.initialized or not file or not file.path then
    return
  end
  if file.size == 0 or file.size > M.max_size or not supports_full(ls) then
    return
  end

  local path = file.path
  local st = cache[path]
  if not st then
    st = { tokens = nil, inflight = false, dirty = false, ls = ls }
    cache[path] = st
  end

  if st.inflight then
    st.dirty = true
    return
  end

  st.inflight = true
  st.dirty = false
  st.ls = ls

  local win = find_window_for_path(path) or vis.win
  local content = file:content(0, file.size)
  local params = { textDocument = { uri = path_to_uri(path) } }
  ls:call_method("textDocument/semanticTokens/full", params, win, {
    path = path,
    content = content,
  })
end

local function hook_server(ls, lspc)
  if not ls or ls._vis_semantic_tokens_hooked then
    return
  end
  ls._vis_semantic_tokens_hooked = true

  -- Intercept semanticTokens responses before vis-lspc warns "unknown method"
  local orig_resp = ls.handle_method_response
  function ls:handle_method_response(method_response, req)
    if req and req.method == "textDocument/semanticTokens/full" then
      self.inflight[method_response.id] = nil
      local ctx = req.ctx
      local st = ctx and cache[ctx.path]
      if st then
        st.inflight = false
      end

      if not method_response.error and method_response.result and method_response.result.data and ctx then
        local provider = self.capabilities and self.capabilities.semanticTokensProvider
        local legend = type(provider) == "table" and provider.legend or nil
        if st then
          st.tokens = decode_tokens(method_response.result.data, legend, ctx.content)
        end
        local win = find_window_for_path(ctx.path)
        if win then
          win:draw()
        end
      end

      -- If edits happened while the request was in flight, fetch once more
      if st and st.dirty then
        local win = find_window_for_path(ctx.path)
        if win and win.file then
          request_tokens(self, win.file)
        end
      end
      return
    end
    return orig_resp(self, method_response, req)
  end

  -- Handle server-initiated workspace/semanticTokens/refresh requests
  local orig_call = ls.handle_method_call
  function ls:handle_method_call(method_call)
    if method_call and method_call.method == "workspace/semanticTokens/refresh" then
      self:rpc({ id = method_call.id, result = lspc.json.null })
      for win in vis:windows() do
        if win.file and win.file.path and self:is_file_opened(win.file) then
          request_tokens(self, win.file)
        end
      end
      return
    end
    return orig_call(self, method_call)
  end

  -- Re-fetch semantic tokens whenever vis-lspc sends a didChange notification
  local orig_did_change = ls.send_did_change
  function ls:send_did_change(file)
    orig_did_change(self, file)
    request_tokens(self, file)
  end
end

function M.refresh(win)
  win = win or vis.win
  if not attached_lspc or not win or not win.file or not win.file.path then
    return
  end
  local open = attached_lspc.open_files[win.file.path]
  if not open then
    return
  end
  for ls in pairs(open.language_servers) do
    request_tokens(ls, win.file)
  end
end

function M.attach(lspc)
  if not lspc or attached_lspc == lspc then
    return M
  end
  attached_lspc = lspc

  -- Advertise semanticTokens support in vis-lspc's initialize capabilities
  local caps = lspc.client_capabilites
  if type(caps) == "table" then
    caps.workspace = caps.workspace or {}
    caps.workspace.semanticTokens = { refreshSupport = true }
    caps.textDocument = caps.textDocument or {}
    caps.textDocument.semanticTokens = {
      dynamicRegistration = false,
      requests = { range = false, full = true },
      tokenTypes = CLIENT_TOKEN_TYPES,
      tokenModifiers = CLIENT_TOKEN_MODIFIERS,
      formats = { "relative" },
      overlappingTokenSupport = false,
      multilineTokenSupport = false,
    }
  end

  vis.events.subscribe(lspc.events.LS_INITIALIZED, function(ls)
    hook_server(ls, lspc)
  end)

  vis.events.subscribe(lspc.events.LS_DID_OPEN, function(ls, file)
    hook_server(ls, lspc)
    request_tokens(ls, file)
  end)

  -- Hook any servers already running when attached late
  for _, ls in pairs(lspc.running or {}) do
    hook_server(ls, lspc)
  end

  return M
end

-- Auto-discover an already-loaded vis-lspc module regardless of require path
local function discover_lspc()
  local direct = package.loaded["plugins/vis-lspc"] or package.loaded["vis-lspc"]
  if type(direct) == "table" and direct.client_capabilites then
    return direct
  end
  for _, mod in pairs(package.loaded) do
    if type(mod) == "table" and mod.name == "vis-lspc" and type(mod.client_capabilites) == "table" then
      return mod
    end
  end
end

local found = discover_lspc()
if found then
  M.attach(found)
end

-- Also try again at INIT in case vis-semantic-tokens was required before vis-lspc
vis.events.subscribe(vis.events.INIT, function()
  if not attached_lspc then
    local lspc = discover_lspc()
    if lspc then
      M.attach(lspc)
    end
  end
end)

vis.events.subscribe(vis.events.FILE_CLOSE, function(file)
  if file and file.path then
    cache[file.path] = nil
  end
end)

vis.events.subscribe(vis.events.WIN_HIGHLIGHT, function(win)
  if not M.enabled or not win.file or not win.file.path then
    return
  end
  local st = cache[win.file.path]
  local tokens = st and st.tokens
  if not tokens or #tokens == 0 then
    return
  end
  local view = win.viewport and win.viewport.bytes
  if not view or view.finish <= view.start then
    return
  end

  local vstart, vend = view.start, view.finish
  local file = win.file
  local fsize = file.size
  local last_spec = nil

  for i = 1, #tokens do
    local tok = tokens[i]
    local s = tok.start
    local e = s + tok.len
    if s >= vend then
      break
    end
    if e > vstart and e <= fsize then
      -- Only paint if the text at this range still matches the snapshot
      if file:content(s, tok.len) == tok.text then
        local spec = resolve_style(tok.type, tok.mods)
        if spec then
          if spec ~= last_spec then
            define_style(win, STYLE_ID, spec)
            last_spec = spec
          end
          win:style(STYLE_ID, s, e - 1)
        end
      end
    end
  end
end)

vis:command_register("semantic-tokens-refresh", function(_, _, win)
  M.refresh(win)
end, "Re-request LSP semantic tokens for the current file")

return M
