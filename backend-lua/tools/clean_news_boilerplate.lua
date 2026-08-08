-- One-shot maintenance tool: strip RSS boilerplate attribution suffixes
-- ("O post ... apareceu primeiro em ..." / "The post ... appeared first on ...")
-- from news descriptions already stored in the DB, including translated
-- description_en.
--
-- The RSS scraper strips boilerplate on new syncs; this tool fixes the rows
-- already persisted. Idempotent: a second run reports "rows changed: 0".
--
-- Run from project root:
--   lua5.1 backend-lua/tools/clean_news_boilerplate.lua

package.path = "./backend-lua/?.lua;./backend-lua/?/init.lua;" .. package.path

local sqlite = require("lsqlite3")
local cjson = require("cjson")

local DB_PATH = os.getenv("SQLITE_PATH")
if not DB_PATH or DB_PATH == "" then
    DB_PATH = "./backend-lua/data/yvy.db"
end

local db = sqlite.open(DB_PATH)
if not db then
    print("ERROR: cannot open DB at " .. DB_PATH)
    os.exit(1)
end

print("DB: " .. DB_PATH)

-- Import strip_boilerplate from utils. utils.lua only pulls env/cjson/lua-csv,
-- so this tool stays lightweight (no lxp/http_client/browser_fallback deps).
local strip = require("app.utils").strip_boilerplate

local changed = 0
local skipped = 0

db:exec("BEGIN")

-- Read via json(data) — never the raw BLOB (AGENTS.md Gotchas).
local select_stmt = db:prepare("SELECT url, json(data) AS data_text FROM news")
if not select_stmt then
    print("ERROR preparing SELECT: " .. tostring(db:errmsg()))
    os.exit(1)
end

for row in select_stmt:nrows() do
    local ok, data = pcall(cjson.decode, row.data_text)
    if not ok or type(data) ~= "table" then
        skipped = skipped + 1
        print("SKIP (corrupt JSONB): " .. row.url)
    else
        local desc = data.description
        local desc_en = data.description_en
        -- cjson decodes JSON null as a userdata sentinel; normalize to nil so
        -- null keys are treated as absent (and never written back as null).
        if desc == cjson.null then desc = nil end
        if desc_en == cjson.null then desc_en = nil end
        local clean = desc and strip(desc) or desc
        local clean_en = desc_en and strip(desc_en) or desc_en

        if (clean and clean ~= desc) or (clean_en and clean_en ~= desc_en) then
            -- JSONB round-trip: json_set on the text form, jsonb() on write.
            -- Only include description_en in json_set when the key already
            -- exists and is non-empty — otherwise json_set would create
            -- "description_en": null on rows that never had a translation.
            local set = "json_set(json(data), '$.description', ?"
            local params = { clean }
            if desc_en and desc_en ~= "" then
                set = set .. ", '$.description_en', ?"
                params[#params + 1] = clean_en
            end
            set = set .. ")"

            local stmt = db:prepare("UPDATE news SET data = jsonb(" .. set .. ") WHERE url = ?")
            if not stmt then
                print("ERROR preparing UPDATE: " .. tostring(db:errmsg()))
            else
                for i, p in ipairs(params) do stmt:bind(i, p) end
                stmt:bind(#params + 1, row.url)
                local rc = stmt:step()
                stmt:finalize()
                if rc == sqlite.DONE then
                    changed = changed + 1
                else
                    print("ERROR updating " .. row.url .. ": " .. tostring(db:errmsg()))
                end
            end
        end
    end
end

select_stmt:finalize()
db:exec("COMMIT")

print("rows changed: " .. changed)
if skipped > 0 then
    print("rows skipped (corrupt JSONB): " .. skipped)
end
print("idempotent: a second run should report rows changed: 0")
