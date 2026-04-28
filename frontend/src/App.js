import React from 'react';
import { BrowserRouter as Router, Routes, Route } from 'react-router-dom';
import { I18nProvider } from './i18n';
import Navbar from './components/Navbar';
import Home from './components/Home';
import Dashboard from './components/Dashboard';
import News from './components/News';
import MapasTemáticos from './components/MapasTemáticos';
import './App.css';

function App() {
  return (
    <I18nProvider>
      <Router>
        <div className="bg-atmosphere" aria-hidden="true" />
        <div className="bg-grid" aria-hidden="true" />
        <div className="app">
          <Navbar />
          <main className="main-content">
            <Routes>
              <Route path="/" element={<Home />} />
              <Route path="/dashboard" element={<Dashboard />} />
              <Route path="/news" element={<News />} />
              <Route path="/mapas-tematicos" element={<MapasTemáticos />} />
            </Routes>
          </main>
        </div>
      </Router>
    </I18nProvider>
  );
}

export default App;
