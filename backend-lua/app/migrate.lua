local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
package.path = script_dir .. "../?.lua;" .. script_dir .. "../?/init.lua;" .. package.path

local env = require("app.env")
local db = require("app.db")
local logger = require("app.logger")

env.load_dotenv(".env")
env.load_dotenv("../.env")

logger.info("Running SQLite JSONB migration")
db.migrate_to_jsonb()
logger.info("SQLite JSONB migration complete")
