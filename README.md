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

2. Configure o Docker e inicialize os containers:
   ```bash
   sudo docker-compose up --build
   ```

3. Baixe e extraia a base de dados do TerraBrasilis:
   - Acesse o link [TerraBrasilis PRODES Brasil](https://terrabrasilis.dpi.inpe.br/download/dataset/brasil-prodes/raster/prodes_brasil_2023.zip) para baixar a base de dados.
   - Extraia o arquivo ZIP na pasta do projeto.

### Uso

Após inicializar o Docker, o aplicativo estará disponível em `http://localhost:5000`.

- Acesse a página inicial para informações básicas.
- Navegue até `/dashboard` para visualizar os dados de desmatamento.
- Acesse `/map` para visualizar o mapa interativo com sobreposição de dados.

### Estrutura do Projeto

- `main.py`: Script principal do Flask.
- `templates/`: Contém os arquivos HTML renderizados pelas rotas do Flask.
- `static/`: Arquivos estáticos como CSS e JavaScript.
- `docker-compose.yml`: Configuração do Docker para facilitar o desenvolvimento.
- `requirements.txt`: Lista de dependências do Python.

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