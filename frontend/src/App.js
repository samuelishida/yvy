import React, { Suspense } from 'react';
import { BrowserRouter as Router, Routes, Route } from 'react-router-dom';
import { I18nProvider } from './i18n';
import Navbar from './components/Navbar';
import './App.css';

const Home          = React.lazy(() => import('./components/Home'));
const Dashboard     = React.lazy(() => import('./components/Dashboard'));
const News          = React.lazy(() => import('./components/News'));
const MapasTemáticos = React.lazy(() => import('./components/MapasTemáticos'));

function App() {
  return (
    <I18nProvider>
      <Router>
        <div className="bg-atmosphere" aria-hidden="true" />
        <div className="bg-grid" aria-hidden="true" />
        <div className="app">
          <Navbar />
          <main className="main-content">
            <Suspense fallback={<div className="page-loading" />}>
              <Routes>
                <Route path="/" element={<Home />} />
                <Route path="/dashboard" element={<Dashboard />} />
                <Route path="/news" element={<News />} />
                <Route path="/mapas-tematicos" element={<MapasTemáticos />} />
              </Routes>
            </Suspense>
          </main>
        </div>
      </Router>
    </I18nProvider>
  );
}

export default App;
