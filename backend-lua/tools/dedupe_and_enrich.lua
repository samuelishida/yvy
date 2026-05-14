-- One-shot: canonicalize URLs, merge trailing-slash duplicates, backfill og:image
-- Run from project root: lua5.1 backend-lua/tools/dedupe_and_enrich.lua

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

local function canonical_url(u)
    if type(u) ~= "string" or u == "" then return u end
    u = u:gsub("#[^#]*$", "")
    if #u > 1 then u = u:gsub("/+$", "") end
    return u
end

-- Step 1: scan all rows, build map canon -> {rows}
local before = 0
for _ in db:nrows("SELECT 1 FROM news") do before = before + 1 end
print("rows before: " .. before)

local by_canon = {}
for row in db:nrows("SELECT url, publishedAt, ingested_at, json(data) AS data_json FROM news") do
    local canon = canonical_url(row.url)
    if not by_canon[canon] then by_canon[canon] = {} end
    by_canon[canon][#by_canon[canon] + 1] = row
end

-- Step 2: for each canon with > 1 row, merge fields (prefer one with image + newest ingest)
local merged_count = 0
local dup_urls_to_delete = {}

local function row_score(r)
    local s = 0
    local ok, d = pcall(cjson.decode, r.data_json or "{}")
    if ok and d.urlToImage and d.urlToImage ~= "" then s = s + 1000 end
    if r.ingested_at then s = s + (#tostring(r.ingested_at)) end
    return s, ok and d or {}
end

for canon, rows in pairs(by_canon) do
    if #rows > 1 then
        merged_count = merged_count + 1
        -- Pick winner by score (best image, freshest)
        local best_idx, best_score, best_data = 1, -1, {}
        for i, r in ipairs(rows) do
            local s, d = row_score(r)
            if s > best_score then best_idx, best_score, best_data = i, s, d end
        end
        -- Merge: if winner has no image but another does, copy
        for i, r in ipairs(rows) do
            if i ~= best_idx then
                local _, d = row_score(r)
                if (not best_data.urlToImage or best_data.urlToImage == "") and d.urlToImage and d.urlToImage ~= "" then
                    best_data.urlToImage = d.urlToImage
                end
                if (not best_data.title_en or best_data.title_en == "") and d.title_en and d.title_en ~= "" then
                    best_data.title_en = d.title_en
                end
                if (not best_data.description_en or best_data.description_en == "") and d.description_en and d.description_en ~= "" then
                    best_data.description_en = d.description_en
                end
                -- Schedule deletion of this dup row's URL (non-canonical variant)
                if r.url ~= canon then
                    dup_urls_to_delete[#dup_urls_to_delete + 1] = r.url
                end
            end
        end
        -- Write merged data back under canonical URL
        local data_json = cjson.encode(best_data)
        -- If winner row had non-canonical URL, we need to update to canonical
        local winner = rows[best_idx]
        if winner.url == canon then
            db:exec("UPDATE news SET data = jsonb('" .. data_json:gsub("'", "''") .. "') WHERE url = '" .. canon:gsub("'", "''") .. "'")
        else
            -- Delete winner under old URL, insert under canonical
            db:exec(string.format(
                "DELETE FROM news WHERE url = '%s'; INSERT OR REPLACE INTO news (url, publishedAt, ingested_at, data) VALUES ('%s', '%s', '%s', jsonb('%s'))",
                winner.url:gsub("'", "''"),
                canon:gsub("'", "''"),
                (winner.publishedAt or ""):gsub("'", "''"),
                (winner.ingested_at or ""):gsub("'", "''"),
                data_json:gsub("'", "''")
            ))
            dup_urls_to_delete[#dup_urls_to_delete + 1] = winner.url
        end
    elseif rows[1].url ~= canon then
        -- Single row but URL is not canonical (has trailing slash). Migrate.
        local r = rows[1]
        db:exec(string.format(
            "UPDATE news SET url = '%s' WHERE url = '%s'",
            canon:gsub("'", "''"), r.url:gsub("'", "''")
        ))
    end
end

-- Step 3: delete duplicates
local deleted = 0
for _, u in ipairs(dup_urls_to_delete) do
    db:exec("DELETE FROM news WHERE url = '" .. u:gsub("'", "''") .. "'")
    deleted = deleted + 1
end

local after = 0
for _ in db:nrows("SELECT 1 FROM news") do after = after + 1 end
print("merged groups: " .. merged_count)
print("deleted dup rows: " .. deleted)
print("rows after: " .. after)

db:close()
print("done.")
