-- tests/kobo_stub.lua — KOReader module stubs so main.lua loads headlessly.
--
-- Usage:
--   package.loaded[...] entries are installed by install(); call it BEFORE
--   dofile-ing main.lua. The stubs are intentionally minimal: they provide the
--   shape main.lua references at load (WidgetContainer:extend, Geom:new,
--   Blitbuffer colors, DataStorage:getDataDir, logger, UIManager no-ops) and a
--   G_reader_settings fake is injected as a global by tests/settings.lua.

local M = {}

local function extend(self, o)
    o = o or {}
    return setmetatable(o, { __index = self })
end

local Widget = { extend = extend }

local WidgetContainer = { extend = extend }

local Geom = {
    new = function(_, o) return o or {} end,
}

local Blitbuffer = {
    COLOR_BLACK = 0x000000,
    COLOR_WHITE = 0xFFFFFF,
}

local function noop() end

local logger = {
    info = noop, warn = noop, error = noop, dbg = noop,
}

-- In-memory fake for G_reader_settings (global; see settings.lua).
-- The plugin reads settings at call time via the global, so tests set defaults
-- through the same accessor before running a scan.
local settings = { _t = {} }
function settings.readSetting(self, k) return settings._t[k] end
function settings.saveSetting(self, k, v) settings._t[k] = v end
function settings.delSetting(self, k) settings._t[k] = nil end
function settings.readSettingF(self, k, default)
    return settings._t[k] ~= nil and settings._t[k] or default
end

local _tmp = os.getenv("FOOTCREAM_TEST_DIR")
if not _tmp then
    _tmp = "/tmp/footcream_tests"
    os.execute("mkdir -p " .. _tmp)
end

local DataStorage = {
    getDataDir = function() return _tmp end,
}

local Notification = {
    new = function() return {} end,
}
local InfoMessage = {
    new = function() return {} end,
}
local UIManager = {
    show = noop, close = noop, setDirty = noop, scheduleIn = noop,
    restartKOReader = noop,
}
local Event = {}
local RenderImage = { new = function() return {} end }

local ffiutil = {
    -- gettime for _now(); deliberately NO runInSubProcess so the scan runs
    -- synchronously in-process for tests.
    gettime = function() return os.clock() end,
    -- v1.7.0 i18n: `local T = ffiutil.template` substitutes %1..%n in the
    -- translated template with the given args.
    template = function(fmt, ...)
        local args = { ... }
        return (fmt:gsub("%%(%d)", function(d)
            local n = tonumber(d)
            return args[n] ~= nil and tostring(args[n]) or ""
        end))
    end,
}

local lfs = {
    attributes = function(path, what)
        local f = io.open(path, "rb")
        if not f then return nil end
        local size = f:seek("end")
        f:close()
        if what == "modification" then return size end
        return { size = size }
    end,
}

local Trapper = {
    wrap = noop,
}

M.settings = settings

function M.install()
    local slots = {
        ["ui/widget/container/widgetcontainer"] = WidgetContainer,
        ["ui/widget/widget"]                    = Widget,
        ["ui/geometry"]                         = Geom,
        ["ffi/blitbuffer"]                      = Blitbuffer,
        ["ui/widget/infomessage"]               = InfoMessage,
        ["ui/uimanager"]                        = UIManager,
        ["datastorage"]                         = DataStorage,
        ["logger"]                              = logger,
        ["ui/widget/notification"]              = Notification,
        ["ui/event"]                            = Event,
        ["ui/renderimage"]                      = RenderImage,
        ["libs/libkoreader-lfs"]                = lfs,
        ["lfs"]                                 = lfs,
        ["ffi/util"]                            = ffiutil,
        -- gettext module: `local _ = require("gettext")` returns the translate
        -- function with .loadMO/.current_lang attached. This Lua build won't
        -- allow fields on functions, so use a callable table instead.
        ["gettext"]                             = setmetatable(
            {
                loadMO = function() end,
                current_lang = "en",
                ngettext = function(singular, plural, n)
                    return (n == 1) and singular or plural
                end,
            },
            { __call = function(_, s) return s end }),
        ["ui/trapper"]                          = Trapper,
    }
    for name, mod in pairs(slots) do
        package.loaded[name] = mod
    end
    -- The plugin reads the global G_reader_settings; make it visible.
    if not _G.G_reader_settings then
        _G.G_reader_settings = settings
    end
    -- v1.7.0 i18n: the plugin calls the KOReader globals _() and T() on every
    -- user-facing string. Identity stubs keep the scan path working headless.
    _G._ = _G._ or function(s) return s end
    _G.T = _G.T or function(fmt, ...)
        local args = { ... }
        return (fmt:gsub("%%(%d)", function(d)
            local n = tonumber(d)
            return args[n] ~= nil and tostring(args[n]) or ""
        end))
    end
end

return M
