import React from 'react';
import { BrowserRouter as Router, Routes, Route } from 'react-router-dom';
import Navbar from './components/Navbar';
import Home from './components/Home';
import Dashboard from './components/Dashboard';
import News from './components/News';
import MapasTemáticos from './components/MapasTemáticos';
import './App.css';

function App() {
  return (
    <Router>
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
  );
}

export default App;
