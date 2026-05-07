# Yvy Backend - Organized Folder Structure

## New Structure (May 6, 2026)

```
backend-lua/
├── main.lua                      # Backend entry point
├── main_frontend.lua             # Frontend entry point (deprecated)
├── yvy-server.c                  # C HTTP server for frontend
├── Makefile                      # Build C server
│
├── app/
│   ├── server.lua                # HTTP server & router
│   ├── db.lua                    # Database layer (SQLite + JSONB)
│   ├── redis.lua                 # Redis client + pooling
│   ├── http_client.lua           # HTTP client with retry logic
│   ├── env.lua                   # Environment variable loader
│   ├── utils.lua                 # JSON, CSV, date utilities
│   ├── logger.lua                # Structured JSON logging
│   ├── init.lua                  # Startup initialization
│   ├── ingest.lua                # Data ingestion (PRODES)
│   ├── migrate.lua               # JSONB migration
│   ├── translate.lua             # Translation chain
│   ├── scrapers.lua              # RSS scraper
│   │
│   ├── routes/                   # API route handlers
│   │   ├── fires.lua             # /api/fires, /api/fires/sync
│   │   ├── deforestation.lua     # /api/data
│   │   ├── biomes.lua            # /api/biomes
│   │   ├── weather.lua           # /api/weather/*
│   │   ├── news.lua              # /api/news, /api/news/refresh
│   │   └── alerts.lua            # /api/alerts (generation logic)
│   │
│   ├── lookups/                  # Geospatial lookups
│   │   ├── biome_lookup.lua      # Biome classification
│   │   ├── indigenous_lands_lookup.lua  # TI point-in-polygon
│   │   └── conservation_units_lookup.lua  # UC point-in-polygon
│   │
│   └── middleware/               # Request middleware
│       ├── auth.lua              # API key validation
│       └── rate_limit.lua        # Rate limiting
│
├── data/                         # Static data files
│   ├── biome_data.json
│   ├── indigenous_lands.json
│   ├── conservation_units.json
│   └── prodes_brasil_2023.csv
│
└── tests/                        # Test files
    ├── test_db.lua
    ├── test_geo.lua
    ├── test_utils.lua
    ├── test_translate.lua
    └── test_alerts.lua
```

## Module Organization

### **Core Modules** (app/*.lua)
Low-level infrastructure used by all other modules:
- `server.lua` - HTTP server, routing, request handling
- `db.lua` - Database connection pool, CRUD operations
- `redis.lua` - Redis client with connection pooling
- `http_client.lua` - HTTP client with retry logic
- `env.lua` - Environment variable management
- `utils.lua` - Common utilities (JSON, CSV, dates)
- `logger.lua` - Structured logging
- `init.lua` - Startup initialization, background tasks

### **Route Handlers** (app/routes/*.lua)
API endpoint implementations:
- `fires.lua` - Fire data endpoints
- `deforestation.lua` - Deforestation data
- `biomes.lua` - Biome classification
- `weather.lua` - Air quality, temperature
- `news.lua` - News aggregation
- `alerts.lua` - Alert generation

### **Lookup Modules** (app/lookups/*.lua)
Geospatial classification:
- `biome_lookup.lua` - Classify lat/lon to biome
- `indigenous_lands_lookup.lua` - Check if point is in TI
- `conservation_units_lookup.lua` - Check if point is in UC

### **Middleware** (app/middleware/*.lua)
Request processing:
- `auth.lua` - API key authentication
- `rate_limit.lua` - Rate limiting (Redis + in-memory)

### **Data Processing** (app/*.lua)
- `translate.lua` - Multi-provider translation chain
- `scrapers.lua` - RSS feed scraping
- `ingest.lua` - PRODES data ingestion
- `migrate.lua` - Database migration

## Updated Require Paths

### In `main.lua`:
```lua
local fires         = require("app.routes.fires")
local deforestation = require("app.routes.deforestation")
local biomes        = require("app.routes.biomes")
local weather       = require("app.routes.weather")
local news          = require("app.routes.news")
local alerts        = require("app.routes.alerts")
local auth          = require("app.middleware.auth")
local rl            = require("app.middleware.rate_limit")
```

### In `init.lua`:
```lua
local biome       = require("app.lookups.biome_lookup")
local ti          = require("app.lookups.indigenous_lands_lookup")
local uc          = require("app.lookups.conservation_units_lookup")
local fires_mod   = require("app.routes.fires")
local news_mod    = require("app.routes.news")
local alerts_mod  = require("app.routes.alerts")
```

### In route files:
```lua
local auth       = require("app.middleware.auth")
local rl         = require("app.middleware.rate_limit")
local biome_lookup = require("app.lookups.biome_lookup")
local ti_lookup    = require("app.lookups.indigenous_lands_lookup")
local uc_lookup    = require("app.lookups.conservation_units_lookup")
```

## Benefits

### ✅ **Better Organization**
- Routes clearly separated from business logic
- Lookup modules grouped together
- Middleware isolated for easy reuse
- Core infrastructure at top level

### ✅ **Easier Navigation**
- Find route handlers in `app/routes/`
- Find geospatial logic in `app/lookups/`
- Find auth/rate limiting in `app/middleware/`

### ✅ **Scalability**
- Easy to add new routes (just add file to `routes/`)
- Easy to add new lookups (add file to `lookups/`)
- Clear separation of concerns

### ✅ **Maintainability**
- Logical grouping reduces cognitive load
- Related files are co-located
- Import paths are predictable

## C Server Location

The C HTTP server (`yvy-server.c`) is now in `backend-lua/` because:
1. It's part of the backend deployment
2. Compiled alongside Lua modules
3. Build script (`Makefile`) in same directory
4. Simplifies deployment (single directory)

## Testing

All modules tested and working:
```bash
# Start full stack
cd scripts
.\start-lua-stack.ps1

# Test endpoints
Invoke-WebRequest http://localhost:5000/health  # Backend
Invoke-WebRequest http://localhost:5001/        # Frontend
```

## Migration Notes

### Files Moved:
- `app/fires.lua` → `app/routes/fires.lua`
- `app/deforestation.lua` → `app/routes/deforestation.lua`
- `app/biomes.lua` → `app/routes/biomes.lua`
- `app/weather.lua` → `app/routes/weather.lua`
- `app/news.lua` → `app/routes/news.lua`
- `app/alerts.lua` → `app/routes/alerts.lua`
- `app/biome_lookup.lua` → `app/lookups/biome_lookup.lua`
- `app/indigenous_lands_lookup.lua` → `app/lookups/indigenous_lands_lookup.lua`
- `app/conservation_units_lookup.lua` → `app/lookups/conservation_units_lookup.lua`
- `app/auth.lua` → `app/middleware/auth.lua`
- `app/rate_limit.lua` → `app/middleware/rate_limit.lua`
- `frontend/yvy-server.c` → `backend-lua/yvy-server.c`
- `frontend/Makefile` → `backend-lua/Makefile`

### Files Updated:
- `main.lua` - Updated all require paths
- `app/init.lua` - Updated lookup and route imports
- All route files - Updated middleware and lookup imports
- `scripts/run-c-frontend.ps1` - Updated build paths
- `backend-lua/yvy-server.c` - Updated STATIC_DIR path

**Status:** ✅ All modules loading correctly, full stack operational.
