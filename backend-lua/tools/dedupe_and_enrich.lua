-- One-shot maintenance tool: dedupe the news table.
--
--   Pass 1 (always): canonicalize URLs (strip fragment + trailing slashes) and
--   merge rows that differ only by URL form (e.g. ".../article" vs
--   ".../article/"). Keeps the row with the best content (image + newest).
--
--   Pass 2 (only with `titles` arg): merge rows that share the same normalized
--   title under DIFFERENT canonical URLs — the same story syndicated by
--   another source (e.g. InfoAmazônia vs Mongabay, oeco.org.br vs oc.eco.br).
--   Prints every merged group so you can eyeball it.
--
-- Run from project root:
--   lua5.1 backend-lua/tools/dedupe_and_enrich.lua            # URL pass only
--   lua5.1 backend-lua/tools/dedupe_and_enrich.lua titles     # + title pass

package.path = "./backend-lua/?.lua;./backend-lua/?/init.lua;" .. package.path

local sqlite = require("lsqlite3")
local cjson = require("cjson")

local DB_PATH = os.getenv("SQLITE_PATH")
if not DB_PATH or DB_PATH == "" then
    DB_PATH = "./backend-lua/data/yvy.db"
end

local do_titles = (arg and arg[1] == "titles")

local db = sqlite.open(DB_PATH)
if not db then
    print("ERROR: cannot open DB at " .. DB_PATH)
    os.exit(1)
end

print("DB: " .. DB_PATH .. (do_titles and "  (URL + title passes)" or "  (URL pass only)"))

local function esc(s)
    return (tostring(s or ""):gsub("'", "''"))
end

local function canonical_url(u)
    if type(u) ~= "string" or u == "" then return u end
    u = u:gsub("#[^#]*$", "")
    if #u > 1 then u = u:gsub("/+$", "") end
    return u
end

local function norm_title(s)
    if type(s) ~= "string" then return "" end
    return s:lower():gsub("[%p%s]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Higher score = better row to keep (has image, has translations, newest).
local function row_score(r)
    local s = 0
    local ok, d = pcall(cjson.decode, r.data_json or "{}")
    if ok then
        if d.urlToImage and d.urlToImage ~= "" then s = s + 1000 end
        if d.title_en and d.title_en ~= "" then s = s + 100 end
        if d.description_en and d.description_en ~= "" then s = s + 100 end
    end
    s = s + (#tostring(r.ingested_at or ""))
    return s, ok and d or {}
end

-- Merge loser data (image/translations) into winner data if missing.
local function merge_data(winner, d)
    if (not winner.urlToImage or winner.urlToImage == "") and d.urlToImage and d.urlToImage ~= "" then
        winner.urlToImage = d.urlToImage
    end
    if (not winner.title_en or winner.title_en == "") and d.title_en and d.title_en ~= "" then
        winner.title_en = d.title_en
    end
    if (not winner.description_en or winner.description_en == "") and d.description_en and d.description_en ~= "" then
        winner.description_en = d.description_en
    end
end

local before = 0
for _ in db:nrows("SELECT 1 FROM news") do before = before + 1 end
print("rows before: " .. before)

db:exec("BEGIN")

-- ── Pass 1: canonical-URL duplicates ──────────────────────────────────────
local merged_count = 0
local deleted_count = 0
local by_canon = {}
for row in db:nrows("SELECT url, publishedAt, ingested_at, json(data) AS data_json FROM news") do
    local canon = canonical_url(row.url)
    if not by_canon[canon] then by_canon[canon] = {} end
    by_canon[canon][#by_canon[canon] + 1] = row
end

for canon, rows in pairs(by_canon) do
    if #rows > 1 then
        merged_count = merged_count + 1
        local best_idx, best_score, best_data = 1, -1, {}
        for i, r in ipairs(rows) do
            local s, d = row_score(r)
            if s > best_score then best_idx, best_score, best_data = i, s, d end
        end

        for i, r in ipairs(rows) do
            if i ~= best_idx then
                local _, d = row_score(r)
                merge_data(best_data, d)
                if r.url ~= canon then
                    db:exec("DELETE FROM news WHERE url = '" .. esc(r.url) .. "'")
                    deleted_count = deleted_count + 1
                end
            end
        end

        local data_json = cjson.encode(best_data)
        local winner = rows[best_idx]
        if winner.url == canon then
            db:exec("UPDATE news SET data = jsonb('" .. esc(data_json) .. "') WHERE url = '" .. esc(canon) .. "'")
        else
            -- Winner used a non-canonical URL: move it under the canonical URL.
            db:exec("DELETE FROM news WHERE url = '" .. esc(winner.url) .. "'")
            db:exec(string.format(
                "INSERT OR REPLACE INTO news (url, publishedAt, ingested_at, data) VALUES ('%s', '%s', '%s', jsonb('%s'))",
                esc(canon), esc(winner.publishedAt), esc(winner.ingested_at), esc(data_json)
            ))
            deleted_count = deleted_count + 1
        end
    elseif rows[1].url ~= canon then
        -- Single row with a non-canonical URL (trailing slash): migrate it.
        local r = rows[1]
        db:exec("UPDATE news SET url = '" .. esc(canon) .. "' WHERE url = '" .. esc(r.url) .. "'")
    end
end

-- ── Pass 2: same-title, different-URL duplicates (cross-source) ───────────
local title_groups = 0
local title_deleted = 0
if do_titles then
    local by_title = {}
    for row in db:nrows("SELECT url, publishedAt, ingested_at, json(data) AS data_json FROM news") do
        local ok, d = pcall(cjson.decode, row.data_json or "{}")
        local nt = ok and norm_title(d.title) or ""
        if nt ~= "" then
            if not by_title[nt] then by_title[nt] = {} end
            by_title[nt][#by_title[nt] + 1] = row
        end
    end

    for nt, rows in pairs(by_title) do
        if #rows > 1 then
            -- Only merge when the rows have genuinely different canonical URLs
            -- (same-URL variants were already collapsed in pass 1).
            local canon_set = {}
            for _, r in ipairs(rows) do
                canon_set[canonical_url(r.url)] = true
            end
            local canon_count = 0
            for _ in pairs(canon_set) do canon_count = canon_count + 1 end
            if canon_count > 1 then
                title_groups = title_groups + 1
                local best_idx, best_score, best_data = 1, -1, {}
                for i, r in ipairs(rows) do
                    local s, d = row_score(r)
                    if s > best_score then best_idx, best_score, best_data = i, s, d end
                end

                print("  title-dup group: " .. nt)
                for i, r in ipairs(rows) do
                    print("      " .. (i == best_idx and "KEEP " or "drop") .. " " .. r.url .. "  (ing=" .. tostring(r.ingested_at) .. ")")
                end

                for i, r in ipairs(rows) do
                    if i ~= best_idx then
                        local _, d = row_score(r)
                        merge_data(best_data, d)
                        db:exec("DELETE FROM news WHERE url = '" .. esc(r.url) .. "'")
                        title_deleted = title_deleted + 1
                    end
                end

                local data_json = cjson.encode(best_data)
                db:exec("UPDATE news SET data = jsonb('" .. esc(data_json) .. "') WHERE url = '" .. esc(rows[best_idx].url) .. "'")
            end
        end
    end
end

db:exec("COMMIT")

local after = 0
for _ in db:nrows("SELECT 1 FROM news") do after = after + 1 end
print("canon-URL merged groups: " .. merged_count)
print("canon-URL rows deleted:  " .. deleted_count)
if do_titles then
    print("title-dup merged groups: " .. title_groups)
    print("title-dup rows deleted:  " .. title_deleted)
end
print("rows after: " .. after)

db:close()
print("done.")
