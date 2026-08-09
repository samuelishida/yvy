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

.PHONY: all clean run warm-car-protected

warm-car-protected: $(TARGET)
	@echo 'Re-gera pré-cálculo CAR x UC/TI no car.db.'
	@echo 'Rode após importar CAR novo ou atualizar conservation_units.json / indigenous_lands.json.'
	cd .. && lua5.1 backend-lua/tools/warm_car_protected_overlap.lua
