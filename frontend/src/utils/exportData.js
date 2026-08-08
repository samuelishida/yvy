// CSV / PNG export helpers (plan: dashboard-enhancement, Inc 10).
// No new dependency: CSV is hand-rolled; PNG serializes the recharts <svg>.

// Quote a CSV field; neutralize spreadsheet-injection prefixes (=, +, -, @)
// because biome/municipality names are user-visible strings from upstream data.
function csvField(value) {
  let s = value === null || value === undefined ? '' : String(value);
  if (/^[=+\-@]/.test(s)) s = "'" + s;
  return `"${s.replace(/"/g, '""')}"`;
}

export function toCsv(rows) {
  if (!rows || rows.length === 0) return '';
  const headers = Object.keys(rows[0]);
  const lines = [
    headers.map(csvField).join(','),
    ...rows.map((row) => headers.map((h) => csvField(row[h])).join(',')),
  ];
  // UTF-8 BOM so Excel renders "Amazônia" correctly.
  return '\uFEFF' + lines.join('\r\n');
}

export function downloadCsv(filename, rows) {
  if (!rows || rows.length === 0) return;
  const blob = new Blob([toCsv(rows)], { type: 'text/csv;charset=utf-8;' });
  triggerDownload(blob, filename);
}

// Serialize the recharts <svg> to PNG via canvas. Rejects silently (no throw)
// when the svg is missing. CSS-drawn bars are not captured — PNG is only
// offered where the chart is a real <svg> (recharts).
export function downloadSvgAsPng(svgEl, filename) {
  if (!svgEl) return;
  const clone = svgEl.cloneNode(true);
  const box = svgEl.getBoundingClientRect();
  clone.setAttribute('width', String(box.width || 800));
  clone.setAttribute('height', String(box.height || 400));
  const xml = new XMLSerializer().serializeToString(clone);
  const svg64 = btoa(unescape(encodeURIComponent(xml)));
  const img = new Image();
  img.onload = () => {
    const canvas = document.createElement('canvas');
    canvas.width = box.width || 800;
    canvas.height = box.height || 400;
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#0d1310';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(img, 0, 0);
    canvas.toBlob((blob) => {
      if (blob) triggerDownload(blob, filename);
    }, 'image/png');
  };
  img.src = 'data:image/svg+xml;base64,' + svg64;
}

function triggerDownload(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
