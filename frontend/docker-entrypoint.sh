#!/bin/bash

# Fail fast
set -e

# Se desejar, você pode adicionar aqui algumas configurações ou comandos adicionais antes de iniciar o servidor

# Executar o comando para servir a aplicação com o Serve
exec serve -s build -l 3000
