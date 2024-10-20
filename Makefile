.PHONY: install start dev stop restart build clean test

# Instalar as dependências do projeto
install:
	npm install

# Iniciar a aplicação em modo de produção
start:
	NODE_ENV=production node server.js

# Iniciar a aplicação em modo de desenvolvimento com nodemon
dev:
	nodemon server.js

# Parar a aplicação
stop:
	# Se estiver usando pm2
	pm2 stop server || true

# Reiniciar a aplicação
restart:
	# Se estiver usando pm2
	pm2 restart server || true

# Construir o frontend (se aplicável)
build:
	npm run build

# Limpar arquivos temporários ou de build
clean:
	rm -rf build

# Executar testes 
test:
	npm test
