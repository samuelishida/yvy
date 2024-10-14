# Yvy

## Getting Started

Este repositório é o projeto Yvy, um aplicativo de observabilidade ambiental para monitorar o desmatamento no Brasil, utilizando Flask, Leaflet, MongoDB e dados do TerraBrasilis.

### Pré-requisitos

- Python 3.9+
- Docker e Docker Compose
- Git

### Instalação

1. Clone o repositório:
   ```bash
   git clone https://gitlab.com/samuelishida/yvy.git
   cd yvy
   ```

3. Configure o Docker e inicialize os containers:
   ```bash
   make
   ```

### Uso

Após inicializar o Docker, o aplicativo estará disponível em `http://localhost:5000`.

- Acesse a página inicial para informações básicas.
- Navegue até `/dashboard` para visualizar os dados.
- Acesse `/map` para visualizar o mapa do TerraBrasilis.

#### Acessando o MongoDB

Para verificar os dados no MongoDB, execute:
```bash
make mongo-access

show dbs

use yvy_data

db.yvy_data.countDocuments({})
```

### Estrutura do Projeto

- `backend/backend.py`: Script principal do Flask para o backend.
- `frontend/frontend.py`: Script principal do Flask para o frontend.
- `frontend/templates/`: Contém os arquivos HTML renderizados pelas rotas do Flask.
- `frontend/static/`: Arquivos estáticos como CSS e JavaScript.
- `docker-compose.yml`: Configuração do Docker para facilitar o desenvolvimento.
- `requirements.txt`: Lista de dependências do Python.
- `Makefile`: Scripts para automatizar a construção e execução dos serviços (frontend e backend).

### Automação com Makefile

O projeto inclui um Makefile para facilitar o gerenciamento dos serviços. Aqui estão os comandos disponíveis:

- Construir serviços:
  - `make build-frontend` - Parar e construir somente o frontend.
  - `make build-backend` - Parar e construir somente o backend.
  - `make build` - Parar e construir tanto o frontend quanto o backend.

- Parar serviços:
  - `make stop-frontend` - Parar o serviço do frontend.
  - `make stop-backend` - Parar o serviço do backend.
  - `make stop` - Parar todos os serviços.

- Reconstruir serviços:
  - `make rebuild-frontend` - Derruba, remove e reconstrói o frontend.
  - `make rebuild-backend` - Derruba, remove e reconstrói o backend.
  - `make rebuild` - Derruba, remove, reconstrói e reinicia todos os serviços.

- Limpar volumes e reconstruir:
  - `make clean` - Remove todos os volumes persistentes e reconstrói os serviços.

- Executar os serviços:
  - `make run` - Inicializa todos os serviços.
  - `make run-frontend` - Inicializa o frontend em segundo plano.
  - `make run-backend` - Inicializa o backend em segundo plano.
  

### Contribuindo

1. Faça um fork do projeto.
2. Crie uma branch para sua feature (`git checkout -b feature/nova-feature`).
3. Commit suas alterações (`git commit -m 'Adiciona nova feature'`).
4. Faça push para a branch (`git push origin feature/nova-feature`).
5. Abra um Pull Request.

### Licença

Este projeto está licenciado sob a licença MIT - veja o arquivo [LICENSE](LICENSE) para mais detalhes.

### Contato

Samuel Ishida - [GitLab](https://gitlab.com/samuelishida)

Sinta-se à vontade para abrir uma issue se encontrar algum problema ou tiver sugestões de melhorias.
