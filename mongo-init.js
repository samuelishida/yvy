// Conecte-se ao banco de dados "Yvy_data" (será criado automaticamente se não existir)
db = db.getSiblingDB('yvy_data');

// Crie um usuário com permissões de leitura e escrita
db.createUser({
  user: "root",
  pwd: "example",
  roles: [
    {
      role: "readWrite",
      db: "yvy_data"
    }
  ]
});
