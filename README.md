# Yvy

Este repositório é o projeto Yvy, um aplicativo de observabilidade ambiental para monitorar o desmatamento no Brasil, utilizando Node.js, React, MongoDB e dados do Yvy.

## 🧰 Instalação

Clone o repositório:

```bash
git clone https://gitlab.com/samuelishida/yvy.git
cd yvy
```

Instale as dependências do projeto:

```bash
make install
```

**Nota:** Certifique-se de ter o Node.js e o npm instalados em sua máquina.

## 🚀 Uso

Para iniciar a aplicação, você pode utilizar os comandos disponíveis no Makefile.

### Iniciar a aplicação em modo de desenvolvimento:

```bash
make dev
```

Isso iniciará o servidor com o nodemon, que reinicia automaticamente a aplicação quando alterações no código são detectadas.

### Iniciar a aplicação em modo de produção:

```bash
make start
```

Isso iniciará o servidor em modo de produção.

A aplicação estará disponível em [http://localhost:8080](http://localhost:8080) ou na porta especificada no seu arquivo `.env`.

Você também pode acessar a aplicação em produção no Railway através deste link:
```
https://yvy-production.up.railway.app/
```

## 🔧 Configuração das Variáveis de Ambiente

Crie um arquivo `.env` na raiz do projeto com as seguintes variáveis:

```env
MONGODB_URI=sua_uri_de_conexao_mongodb
NEWS_API_KEY=sua_chave_da_newsapi
PORT=8080
```

- **MONGODB_URI**: A URI de conexão com o seu banco de dados MongoDB.
- **NEWS_API_KEY**: Sua chave de API obtida em [NewsAPI.org](https://newsapi.org).
- **PORT**: (Opcional) A porta em que o servidor irá rodar.

**Importante:** Não compartilhe o arquivo `.env` em repositórios públicos.

## 🗂️ Estrutura do Projeto

- **server.js**: Arquivo principal do backend em Node.js (Express).
- **models/**: Diretório contendo os modelos do Mongoose para o MongoDB.
  - **models/News.js**: Modelo para os artigos de notícias.
- **news-api.js**: Script para buscar e salvar notícias da NewsAPI.
- **mongo.js**: Script para conectar ao MongoDB.
- **Makefile**: Scripts para automatizar a execução e gerenciamento da aplicação.
- **package.json**: Lista de dependências do projeto e scripts npm.
- **client/**: Diretório contendo o código do frontend em React.
  - **client/public/index.html**: Arquivo HTML principal para o frontend.
  - **client/src/index.js**: Script principal do React para o frontend.
  - **client/src/components/**: Componentes React utilizados na aplicação.

## 🚧 Automação com Makefile

O projeto inclui um Makefile para facilitar o gerenciamento dos comandos. Aqui estão os comandos disponíveis:

- **Instalar as dependências**:

  ```bash
  make install
  ```

- **Iniciar a aplicação em modo de desenvolvimento**:

  ```bash
  make dev
  ```

- **Iniciar a aplicação em modo de produção**:

  ```bash
  make start
  ```

- **Parar a aplicação (se estiver usando pm2)**:

  ```bash
  make stop
  ```

- **Reiniciar a aplicação (se estiver usando pm2)**:

  ```bash
  make restart
  ```

- **Construir o frontend**:

  ```bash
  make build
  ```

- **Limpar arquivos temporários ou de build**:

  ```bash
  make clean
  ```

## 📊 Acessando o MongoDB

Para verificar os dados no MongoDB, você pode utilizar uma ferramenta como o [MongoDB Compass](https://www.mongodb.com/try/download/compass) ou a linha de comando:

```bash
mongo --host localhost --port 27017 -u seu_usuario -p sua_senha

> show dbs
> use yvy_data
> db.news.countDocuments({})
```

## 🤝 Contribuindo

1. Faça um fork do projeto.
2. Crie uma branch para sua feature:

   ```bash
   git checkout -b feature/minha-nova-feature
   ```

3. Commit suas alterações:

   ```bash
   git commit -m 'Adiciona minha nova feature'
   ```

4. Faça push para a branch:

   ```bash
   git push origin feature/minha-nova-feature
   ```

5. Abra um Pull Request.

## 📜 Licença

Este projeto está licenciado sob a [licença MIT](LICENSE) - veja o arquivo LICENSE para mais detalhes.

