// Conecte-se ao banco de dados "terrabrasilis_data" (será criado automaticamente se não existir)
db = db.getSiblingDB('terrabrasilis_data');

// Crie um usuário com permissões de leitura e escrita
db.createUser({
  user: "root",
  pwd: "example",
  roles: [
    {
      role: "readWrite",
      db: "terrabrasilis_data"
    }
  ]
});
