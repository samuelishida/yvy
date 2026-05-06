#!/usr/bin/env lua
-- main_frontend.lua — Yvy frontend server entry point (Lua baremetal)
-- Serves React build static files + proxies /api/* to backend
-- Usage: lua main_frontend.lua

-- Add project root to package path
local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. package.path

local env = require("app.env")

-- Try multiple .env locations
env.load_dotenv(".env")
env.load_dotenv("../.env")
env.load_dotenv(script_dir .. "../.env")

local frontend_server = require("app.frontend_server")
local logger = require("app.logger")

logger.info("=== Yvy Frontend (Lua) Starting ===")
frontend_server.start()
