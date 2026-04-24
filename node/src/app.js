// App.js
import React from 'react';
import { BrowserRouter as Router, Route, Routes, Link } from 'react-router-dom';
import Home from './home';
import News from './news-view';
import Dashboard from './dashboard';

import './yvy.css'; // Importar CSS para o estilo da aplicação

const App = () => {
  return (
    <Router>
      <div>
        {/* Navbar para navegação entre páginas */}
        <nav className="navbar navbar-expand-lg navbar-light bg-light">
          <div className="container-fluid">
            <Link className="navbar-brand" to="/">Yvy</Link>
            <div className="navbar-nav">
              <ul className="navbar-nav ms-auto">
                <li className="nav-item">
                  <Link className="nav-link" to="/">Home</Link>
                </li>
                <li className="nav-item">
                  <Link className="nav-link" to="/Noticias">Notícias</Link>
                </li>
                <li className="nav-item">
                  <Link className="nav-link" to="/Dados">Dashboard</Link>
                </li>
              </ul>
            </div>
          </div>
        </nav>

        {/* Rotas da aplicação */}
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/Noticias" element={<News />} />
          <Route path="/Dados" element={<Dashboard />} />
        </Routes>
      </div>
    </Router>
  );
};

export default App;
