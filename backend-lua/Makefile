# Makefile for Yvy C frontend server

CC = gcc
CFLAGS = -Wall -O2
TARGET = yvy-server
SRC = yvy-server.c

# Windows (MinGW)
ifeq ($(OS),Windows_NT)
    TARGET = yvy-server.exe
    LDFLAGS = -lws2_32
else
    # Linux/macOS
    LDFLAGS = 
endif

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $(TARGET) $(SRC) $(LDFLAGS)

clean:
	rm -f $(TARGET)

run: $(TARGET)
	./$(TARGET) --port 5001 --backend 127.0.0.1 --static ../frontend/build

.PHONY: all clean run warm-car-protected backfill-prodes warm-car-prodes merge-car-prodes clone-car-prodes-workers warm-risk-scores

warm-car-protected: $(TARGET)
	@echo 'Re-gera pré-cálculo CAR x UC/TI no car.db.'
	@echo 'Rode após importar CAR novo ou atualizar conservation_units.json / indigenous_lands.json.'
	cd .. && lua5.1 backend-lua/tools/warm_car_protected_overlap.lua

warm-car-prodes: $(TARGET)
	@echo 'Re-gera pré-cálculo CAR x PRODES no car.db.'
	@echo 'Rode após importar CAR novo ou atualizar deforestation_data (PRODES).'
	cd .. && lua5.1 backend-lua/tools/warm_car_prodes.lua

clone-car-prodes-workers: $(TARGET)
	@echo 'Para rodar em paralelo por UF, use backend-lua/tools/clone_car_prodes_worker.sh'
	@echo 'Exemplo: bash backend-lua/tools/clone_car_prodes_worker.sh data/car/car.db /tmp/yvy-prodes-workers 8'

merge-car-prodes: $(TARGET)
	@echo 'Merge dos clones gerados por clone-car-prodes-workers.'
	@echo 'Uso: make merge-car-prodes CLONES="/tmp/yvy-prodes-workers/*/car.db"'
	cd .. && bash -c 'lua5.1 backend-lua/tools/merge_car_prodes.lua $$CLONES'

backfill-prodes:
	@echo 'Backfill das colunas year/class_type em deforestation_data (2M rows).'
	@echo 'Rode ANTES do deploy, com o backend parado (operação offline no DB).'
	cd .. && lua5.1 scripts/deploy/backfill_prodes_columns.lua

warm-risk-scores:
	@echo 'Re-gera pré-cálculo de scores de risco no risk.db.'
	@echo 'Rode após importar MapBiomas/PRODES novo ou mudar RISK_VERSION.'
	cd .. && lua5.1 backend-lua/tools/warm_risk_scores.lua
