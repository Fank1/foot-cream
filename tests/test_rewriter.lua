-- tests/test_rewriter.lua — metric_epub.lua (the pure-Lua in-place rewriter):
-- apply/revert round-trip, entity-encoded fallback, guard_next, and the
-- record/backup bookkeeping. Uses tests/archiver_stub.lua in place of
-- libarchive.

local T = require("run")
local archiver = require("archiver_stub")

local TMP = os.getenv("FOOTCREAM_TEST_DIR") or "/tmp/footcream_tests"

local Metric = dofile("metric_epub.lua")

local function make_epub(path, xhtml)
    local w = archiver.Writer:new()
    assert(w:open(path))
    w:setZipCompression("store")
    w:addFileFromMemory("mimetype", "application/epub+zip")
    w:setZipCompression("deflate")
    w:addFileFromMemory("OEBPS/content.xhtml", xhtml)
    w:close()
end

local function read_epub(path)
    local r = archiver.Reader:new()
    if not r:open(path) then return nil end
    local out = {}
    for e in r:iterate() do
        if e.mode == "file" then out[e.path] = r:extractToMemory(e.path) end
    end
    r:close()
    return out
end

local function clean(path)
    os.remove(path)
    os.remove(path .. ".orig")
    os.remove(path .. ".inprogress")
end

local XHTML = "<html><body><p>He was six feet tall and weighed two hundred pounds.</p></body></html>"

T("apply converts in place and revert restores", function()
    local epub = TMP .. "/rw_roundtrip.epub"
    local rec  = TMP .. "/rw_roundtrip.rec"
    make_epub(epub, XHTML)
    clean(rec)
    local res = Metric.apply(epub, rec, {
        { from = "six feet", to = "1.8 m" },
        { from = "two hundred pounds", to = "91 kg" },
    })
    assert_eq(res:match("^OK"), "OK", "apply returned " .. res)
    local out = read_epub(epub)
    local body = out["OEBPS/content.xhtml"]
    assert(body:find("1.8 m", 1, true), "converted text present:\n" .. body)
    assert(body:find("91 kg", 1, true), "second conversion present:\n" .. body)

    local res2 = Metric.revert(epub, rec)
    assert_eq(res2, "OK", "revert returned " .. res2)
    local restored = read_epub(epub)
    assert(restored["OEBPS/content.xhtml"]:find("six feet", 1, true), "original restored")
    assert(restored["OEBPS/content.xhtml"]:find("two hundred pounds", 1, true), "original restored 2")
end)

T("entity-encoded fallback matches numeric character refs", function()
    local epub = TMP .. "/rw_entity.epub"
    local rec  = TMP .. "/rw_entity.rec"
    make_epub(epub, "<html><body><p>It hit 98&#xB0;F outside.</p></body></html>")
    clean(rec)
    local res = Metric.apply(epub, rec, { { from = "98°F", to = "37 °C" } })
    assert_eq(res:match("^OK"), "OK", "apply returned " .. res)
    local body = read_epub(epub)["OEBPS/content.xhtml"]
    assert(body:find("37 °C", 1, true), "entity fallback converted:\n" .. body)
end)

T("guard_next suppresses an idiom match", function()
    local epub = TMP .. "/rw_guard.epub"
    local rec  = TMP .. "/rw_guard.rec"
    make_epub(epub, XHTML)
    clean(rec)
    local res = Metric.apply(epub, rec, {
        { from = "six feet", to = "1.8 m", guard_next = { "tall" } },
    })
    assert_eq(res, "OK:0", "guarded phrase must not convert, got " .. res)
end)

T("apply then revert leaves the record and backup cleaned", function()
    local epub = TMP .. "/rw_cleanup.epub"
    local rec  = TMP .. "/rw_cleanup.rec"
    make_epub(epub, XHTML)
    clean(rec)
    assert_eq(Metric.apply(epub, rec, { { from = "six feet", to = "1.8 m" } }):match("^OK"), "OK")
    assert_eq(Metric.revert(epub, rec), "OK")
    local f = io.open(rec, "rb"); assert_eq(f, nil, "record removed after revert")
    local b = io.open(rec .. ".orig", "rb"); assert_eq(b, nil, "backup removed after revert")
    local m = io.open(rec .. ".inprogress", "rb"); assert_eq(m, nil, "marker removed after revert")
end)

T("has_soft_hyphens detects U+00AD in html", function()
    local epub = TMP .. "/rw_shy.epub"
    make_epub(epub, "<html><body><p>one\xC2\xADhundred</p></body></html>")
    assert_eq(Metric.has_soft_hyphens(epub), true, "soft hyphen must be detected")
end)
