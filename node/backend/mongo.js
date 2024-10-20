// mongo.js

const mongoose = require('mongoose');
require('dotenv').config();

const MONGODB_URI = process.env.MONGODB_URI;

function connectToMongoDB() {
  mongoose.connect(MONGODB_URI, {
    useNewUrlParser: true,
    useUnifiedTopology: true,
  });

  mongoose.connection.on('connected', () => {
    console.log('Conectado ao MongoDB');
  });

  mongoose.connection.on('error', (err) => {
    console.error('Erro na conexão com o MongoDB:', err.message);
  });

  mongoose.connection.on('disconnected', () => {
    console.log('Desconectado do MongoDB');
  });

  process.on('SIGINT', () => {
    mongoose.connection.close(() => {
      console.log('Conexão com o MongoDB fechada devido ao término da aplicação');
      process.exit(0);
    });
  });
}

module.exports = connectToMongoDB;
