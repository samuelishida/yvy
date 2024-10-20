// index.js
import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './app'; // Certifique-se de que o caminho está correto para App.js
import './yvy.css'; // Importar o CSS para a aplicação
import 'bootstrap/dist/css/bootstrap.min.css';

// Cria a raiz do ReactDOM e renderiza a aplicação App dentro do elemento com id 'root'
const root = ReactDOM.createRoot(document.getElementById('root'));
root.render(
  <React.StrictMode>
    <App /> {/* Renderizando a aplicação principal */}
  </React.StrictMode>
);
