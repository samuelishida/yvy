-- test_deter_protected.lua — Incursão DETER × UC/TI por geometria (plan: protected-area-crossing, Inc 3)
--
-- yvy.db temporário com lookup_data de UC/TI; require do tool como módulo
-- (arg-guard impede o scan no load); asserts sobre detect_territory:
--   (a) corte grande com centroide fora mas 3/4 cantos dentro (UC em "C") → flagged
--   (b) corte pequeno com centroide dentro → flagged (via centroide)
--   (c) fora de tudo → não flagged
--   (d) cantos dentro mas área < gate → não flagged
--   (e) atributo `uc` + geometria → hit único (dedup) com area_ha do atributo
--   (f) TI por centroide
--
-- Fixtures em regiões disjuntas para os asserts não se pisarem:
--   RESEX C (côncava, com entalhe)   : lon -61..-60,  lat -11..-10  (entalhe topo-direita)
--   RESEX Leste (retângulo cheio)    : lon -59..-58,  lat -11..-10
--   Terra Norte (retângulo cheio)    : lon -62..-61,  lat -1..-0.5
-- Redis: chaves de alerta limpas no teardown (common-mistakes #2).

local env = require("app.env")
local sqlite3 = require("lsqlite3")

dofile("tests/helpers.lua")

local tmp_yvy_db = "./yvy_deter_protected_" .. tostring(os.time()) .. ".db"
env.set("SQLITE_PATH", tmp_yvy_db)
package.loaded["app.db"] = nil
package.loaded["app.lookups.conservation_units_lookup"] = nil
package.loaded["app.lookups.indigenous_lands_lookup"] = nil
package.loaded["tools.deter_protected_alerts"] = nil

local db_mod = require("app.db")
local redis = require("app.redis")

local UC_FIXTURE = {
    -- Retângulo (-61..-60, -11..-10) com entalhe no topo-ESQUERDA: a região
    -- (lon -61..-60.5, lat -10.5..-10) fica FORA do polígono (C aberta à esquerda).
    ["RESEX C"] = {
        rings = { { { -61, -11 }, { -60, -11 }, { -60, -10 }, { -60.5, -10 }, { -60.5, -10.5 }, { -61, -10.5 }, { -61, -11 } } },
        category = "RESEX",
    },
    ["RESEX Leste"] = {
        rings = { { { -59, -11 }, { -58, -11 }, { -58, -10 }, { -59, -10 }, { -59, -11 } } },
        category = "RESEX",
    },
}
local TI_FIXTURE = {
    ["Terra Norte"] = {
        rings = { { { -62, -1 }, { -61, -1 }, { -61, -0.5 }, { -62, -0.5 }, { -62, -1 } } },
    },
}

local tool

local function poly(bbox, area_km2, uc_attr, areauckm)
    return {
        min_lat = bbox.min_lat, min_lon = bbox.min_lon,
        max_lat = bbox.max_lat, max_lon = bbox.max_lon,
        area_km2 = area_km2, uc = uc_attr, areauckm = areauckm,
    }
end

local function find_hit(hits, type_, name)
    for _, h in ipairs(hits) do
        if h.type == type_ and h.name == name then return h end
    end
    return nil
end

describe("deter protected alerts (geometry)", function()
    setup(function()
        db_mod.init_db()
        db_mod.set_lookup_data("conservation_units", UC_FIXTURE)
        db_mod.set_lookup_data("indigenous_lands", TI_FIXTURE)
        redis.delete("alerts:deter_protected")
        redis.delete("alerts:deter_protected:last_run")
        tool = require("tools.deter_protected_alerts")
    end)

    teardown(function()
        for _, f in ipairs({ tmp_yvy_db, tmp_yvy_db .. "-wal", tmp_yvy_db .. "-shm" }) do
            os.remove(f)
        end
    end)

    it("flags a large cut whose centroid is outside but 3 corners are inside (concave UC)", function()
        -- bbox lon -60.85..-60.35, lat -10.7..-10.2: centroide (-60.6,-10.45) cai no
        -- entalhe (fora); cantos inf-esq/inf-dir/sup-dir dentro → 3 ≥ 3 (gate).
        local p = poly({ min_lon = -60.85, min_lat = -10.7, max_lon = -60.35, max_lat = -10.2 }, 10)
        local hit = find_hit(tool.detect_territory(p), "uc", "RESEX C")
        assert.is_not_nil(hit, "expected corner-gate hit on RESEX C")
        assert.are_equal(0, hit.area_ha, "geometry hits carry no fabricated area")
    end)

    it("flags a cut whose centroid is inside even when small", function()
        local p = poly({ min_lon = -58.8, min_lat = -10.8, max_lon = -58.2, max_lat = -10.2 }, 1)
        local hit = find_hit(tool.detect_territory(p), "uc", "RESEX Leste")
        assert.is_not_nil(hit, "expected centroid hit on RESEX Leste")
    end)

    it("does not flag a cut outside all protected areas", function()
        local p = poly({ min_lon = -55.5, min_lat = -13.0, max_lon = -55.0, max_lat = -12.5 }, 10)
        assert.are_equal(0, #tool.detect_territory(p))
    end)

    it("does not flag corners-inside when area is below the large-cut gate", function()
        -- Mesmo bbox do caso (a), mas área pequena → gate de cantos desligado e
        -- centroide ainda fora → nada.
        local p = poly({ min_lon = -60.85, min_lat = -10.7, max_lon = -60.35, max_lat = -10.2 }, 1)
        assert.are_equal(0, #tool.detect_territory(p))
    end)

    it("dedups attr + geometry hits and keeps the attr area", function()
        -- uc="RESEX Leste" (atributo nativo) E geometria cobre o bbox → 1 hit só,
        -- com area_ha = areauckm * 100 (sem double-count que fabricaria crit).
        local p = poly({ min_lon = -58.8, min_lat = -10.8, max_lon = -58.2, max_lat = -10.2 }, 10, "RESEX Leste", 2.0)
        local hits = tool.detect_territory(p)
        local n = 0
        local hit
        for _, h in ipairs(hits) do
            if h.type == "uc" and h.name == "RESEX Leste" then n = n + 1; hit = h end
        end
        assert.are_equal(1, n, "attr + geometry must dedup to a single hit")
        assert.are_equal(200, hit.area_ha)
    end)

    it("flags a TI by centroid", function()
        -- bbox longe das bordas da TI (lat -1..-0.5): centroide (-61.5,-0.65) dentro.
        local p = poly({ min_lon = -61.8, min_lat = -0.7, max_lon = -61.2, max_lat = -0.6 }, 1)
        local hit = find_hit(tool.detect_territory(p), "ti", "Terra Norte")
        assert.is_not_nil(hit, "expected centroid hit on Terra Norte")
        assert.are_equal(0, hit.area_ha)
    end)
end)
