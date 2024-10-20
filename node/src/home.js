import React from 'react';
import News from './news-view'; // Certifique-se que 'news-view' está corretamente instalado e configurado

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
      
    </div>
    
  );
};

export default Home;
