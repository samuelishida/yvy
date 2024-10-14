import React from 'react';

const Home = () => {
  return (
    <div className="iframe-container">
      <iframe
        src="/index.html"
        width="100%"
        height="1000"
        style={{ border: 'none' }}
        title="Yvy Home"
      />
    </div>
  );
};

export default Home;
