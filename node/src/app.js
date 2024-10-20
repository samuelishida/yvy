// App.js
import React from 'react';
import { BrowserRouter as Router, Route, Routes, Link } from 'react-router-dom';
import Home from './home';
import News from './news';
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
            <button
              className="navbar-toggler"
              type="button"
              data-bs-toggle="collapse"
              data-bs-target="#navbarNav"
              aria-controls="navbarNav"
              aria-expanded="false"
              aria-label="Toggle navigation"
            >
              <span className="navbar-toggler-icon"></span>
            </button>
            <div className="collapse navbar-collapse" id="navbarNav">
              <ul className="navbar-nav ms-auto">
                <li className="nav-item">
                  <Link className="nav-link" to="/" onClick={() => window.innerWidth < 992 && document.querySelector('.navbar-toggler').click()}>Home</Link>
                </li>
                <li className="nav-item">
                  <Link className="nav-link" to="/Noticias" onClick={() => window.innerWidth < 992 && document.querySelector('.navbar-toggler').click()}>Notícias</Link>
                </li>
                <li className="nav-item">
                  <Link className="nav-link" to="/Dados" onClick={() => window.innerWidth < 992 && document.querySelector('.navbar-toggler').click()}>Dashboard</Link>
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