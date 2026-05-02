import React, { createContext, useContext, useState, useCallback } from 'react';

const translations = {
  pt: {
    nav: {
      home: 'Início',
      news: 'Notícias',
      dashboard: 'Dashboard',
      thematicMaps: 'Mapas Temáticos',
      brandSub: 'Observabilidade Ambiental · Brasil',
    },
    home: {
      mapTitle: 'Mapa de Desmatamento & Queimadas',
      prodes: 'PRODES',
      firmsFire: 'Queimadas FIRMS',
      prodesSource: 'PRODES · INPE',
      loading: 'Carregando mapa...',
      error: 'Erro',
      layerDeforestation: 'Desmatamento',
      layerFires: 'Focos de Calor',
      layerSatellite: 'Satélite',
      layerIndigenous: 'Terras Indígenas',
      layerConservation: 'Unid. Conservação',
      deforestation: 'Desmatamento',
      regeneration: 'Regeneração',
      forest: 'Floresta',
      hydrography: 'Hidrografia',
      nonForest: 'Não floresta',
      unknown: 'Desconhecido',
      source: 'Fonte',
      heatFocus: '🔥 Foco de Calor',
      confidence: 'Confiança',
      date: 'Data',
      satellite: 'Satélite',
      brightnessTemp: 'Temp. Brilho',
      sourceNasa: 'Fonte: NASA FIRMS',
      airQuality: 'Qualidade do Ar',
      feelsLike: 'Sensação térmica',
      humidity: 'Umidade',
      temperature: 'Temperatura',
      recentFires: 'Queimadas Recentes',
      last3Days: 'Últimos 3 dias',
      totalOnMap: 'Total no mapa',
      viewOnFirms: '↗ Ver no FIRMS',
      sync: 'Sincronizado',
      focosByBiome: 'Focos por bioma',
      liveAlerts: 'Alertas ao vivo',
      active: 'ATIVOS',
      noAlerts: 'Nenhum alerta ativo',
      alertCluster: 'Cluster de alta confiança',
      alertNightFire: 'Avanço de queimada noturna',
      alertIndigenousLand: 'Foco em Terra Indígena',
      alertProdes: 'Polígono PRODES atualizado',
      alertPm25: 'PM2.5 acima do limiar',
      alertConservationUnit: 'Foco em Unidade de Conservação',
      focuses: 'focos',
      km2: 'km²',
    },
    news: {
      readMore: 'Ler mais',
      loadingMore: 'Carregando mais notícias...',
      errorLoading: 'Erro ao carregar notícias. Tente novamente mais tarde.',
    },
    dashboard: {
      title: 'Dashboard de Desmatamento',
      subtitle: 'Dados PRODES · INPE — Cobertura florestal do Brasil',
      mongoLive: 'SQLite · Ao vivo',
      loading: 'Carregando dados do banco...',
      connectionError: 'Erro ao conectar ao backend',
      errorHint: 'Verifique se o backend está rodando e os dados foram ingeridos com',
      noData: 'Nenhum dado encontrado',
      noDataHint: 'O banco está vazio. Execute o script de ingestão para carregar os dados PRODES:',
      recordsLoaded: 'Registros carregados',
      distinctCategories: 'Categorias distintas',
      dominantCategory: 'Categoria dominante',
      dataSource: 'Fonte dos dados',
      distributionByCategory: 'Distribuição por Categoria',
      points: 'pontos',
      deforestationMap: 'Mapa de Desmatamento — TerraBrasilis',
      openFullScreen: '↗ Abrir em tela cheia',
    },
    maps: {
      globalForests: 'Florestas Globais',
      deforestation: 'Desmatamento',
      airQuality: 'Qualidade do Ar',
      temperature: 'Temperatura',
      storms: 'Tempestades',
      seaLevel: 'Nível do Mar',
    },
  },
  en: {
    nav: {
      home: 'Home',
      news: 'News',
      dashboard: 'Dashboard',
      thematicMaps: 'Thematic Maps',
      brandSub: 'Environmental Observability · Brazil',
    },
    home: {
      mapTitle: 'Deforestation & Wildfires Map',
      prodes: 'PRODES',
      firmsFire: 'Wildfires FIRMS',
      prodesSource: 'PRODES · INPE',
      loading: 'Loading map...',
      error: 'Error',
      layerDeforestation: 'Deforestation',
      layerFires: 'Heat Spots',
      layerSatellite: 'Satellite',
      layerIndigenous: 'Indigenous Lands',
      layerConservation: 'Conservation Units',
      deforestation: 'Deforestation',
      regeneration: 'Regeneration',
      forest: 'Forest',
      hydrography: 'Hydrography',
      nonForest: 'Non-forest',
      unknown: 'Unknown',
      source: 'Source',
      heatFocus: '🔥 Heat Focus',
      confidence: 'Confidence',
      date: 'Date',
      satellite: 'Satellite',
      brightnessTemp: 'Brightness Temp',
      sourceNasa: 'Source: NASA FIRMS',
      airQuality: 'Air Quality',
      feelsLike: 'Feels like',
      humidity: 'Humidity',
      temperature: 'Temperature',
      recentFires: 'Recent Wildfires',
      last3Days: 'Last 3 days',
      totalOnMap: 'Total on map',
      viewOnFirms: '↗ View on FIRMS',
      sync: 'Synced',
      focosByBiome: 'Fires by Biome',
      liveAlerts: 'Live Alerts',
      active: 'ACTIVE',
      noAlerts: 'No active alerts',
      alertCluster: 'High-confidence Cluster',
      alertNightFire: 'Nighttime Fire Advance',
      alertIndigenousLand: 'Fire in Indigenous Land',
      alertProdes: 'PRODES Polygon Updated',
      alertPm25: 'PM2.5 Above Threshold',
      alertConservationUnit: 'Fire in Conservation Unit',
      focuses: 'fires',
      km2: 'km²',
    },
    news: {
      readMore: 'Read more',
      loadingMore: 'Loading more news...',
      errorLoading: 'Error loading news. Please try again later.',
    },
    dashboard: {
      title: 'Deforestation Dashboard',
      subtitle: 'PRODES · INPE Data — Brazil Forest Coverage',
      mongoLive: 'SQLite · Live',
      loading: 'Loading data from database...',
      connectionError: 'Error connecting to backend',
      errorHint: 'Make sure the backend is running and data has been ingested with',
      noData: 'No data found',
      noDataHint: 'The database is empty. Run the ingestion script to load PRODES data:',
      recordsLoaded: 'Loaded records',
      distinctCategories: 'Distinct categories',
      dominantCategory: 'Dominant category',
      dataSource: 'Data source',
      distributionByCategory: 'Distribution by Category',
      points: 'points',
      deforestationMap: 'Deforestation Map — TerraBrasilis',
      openFullScreen: '↗ Open full screen',
    },
    maps: {
      globalForests: 'Global Forests',
      deforestation: 'Deforestation',
      airQuality: 'Air Quality',
      temperature: 'Temperature',
      storms: 'Storms',
      seaLevel: 'Sea Level',
    },
  },
};

const I18nContext = createContext();

export function I18nProvider({ children }) {
  const [lang, setLang] = useState(() => {
    try {
      return localStorage.getItem('yvy-lang') || 'pt';
    } catch {
      return 'pt';
    }
  });

  const switchLang = useCallback((newLang) => {
    setLang(newLang);
    try {
      localStorage.setItem('yvy-lang', newLang);
    } catch {}
  }, []);

  const t = useCallback(
    (path) => {
      const keys = path.split('.');
      let val = translations[lang];
      for (const key of keys) {
        val = val?.[key];
      }
      if (val === undefined) {
        let fallback = translations['pt'];
        for (const key of keys) {
          fallback = fallback?.[key];
        }
        return fallback || path;
      }
      return val;
    },
    [lang],
  );

  return (
    <I18nContext.Provider value={{ lang, switchLang, t }}>
      {children}
    </I18nContext.Provider>
  );
}

export function useI18n() {
  const ctx = useContext(I18nContext);
  if (!ctx) throw new Error('useI18n must be used within I18nProvider');
  return ctx;
}