-- debug: test regex engine against the real _FAST_UNIT_PAT
package.path = "./tests/?.lua;" .. package.path
local R = require("regex")
local stub = require("kobo_stub")
stub.install()
_G.G_reader_settings = stub.settings
local FootFree = dofile("main.lua")

-- Extract the built pattern by scanning with mock doc and print hits
local MockDoc = require("mock_doc")
local doc = MockDoc.new("He was six feet tall. They walked two miles.", { file = "/tmp/x.txt" })
local hits = doc:findAllText(_G.__? ) -- can't access local

-- Instead, rebuild the pattern string here by copying the alternation logic
print("FAST pat exists in module? ", tostring(FootFree._FAST_UNIT_PAT))
