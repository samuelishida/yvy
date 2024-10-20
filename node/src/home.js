import React from 'react';
import News from 'news-view'; // Certifique-se que 'news-view' está corretamente instalado e configurado

const Home = () => {
  return (
    <div className="iframe-container">
      

      {/* Seção do iframe */}
      <iframe
        src="/hub.html"
        width="100%"
        height="1000"
        style={{ border: 'none' }}
        title="Yvy Home"
      />
      {/* Seção de Notícias */}
      <div className="news-section">
        <h2>Latest News</h2>
        <News />
      </div>
    </div>
    
  );
};

export default Home;
