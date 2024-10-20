import React from 'react';

const News = () => {
  return (
    <div className="iframe-container">
      <iframe
        src="/news.html"
        width="100%"
        height="1000"
        style={{ border: 'none' }}
        title="Notícias"
      />
    </div>
  );
};

export default News;
