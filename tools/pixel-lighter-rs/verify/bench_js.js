// 用原版 JS 算法（从 HTML 原样抽取）跑基准，和 Rust 版对照。
// 用法: node verify/bench_js.js <raw> <宽> <高> [重复次数]
const fs = require('fs');
const path = require('path');

const HTML = 'G:/Program Files (x86)/Tencent/1229037592/FileRecv/Pixel-Art-Lighter-v3.5.23.html';
const RAW = process.argv[2];
const W = Number(process.argv[3]);
const H = Number(process.argv[4]);
const N = Number(process.argv[5] || 100);

const html = fs.readFileSync(HTML, 'utf8');
function slice(from, to) {
  const s = html.indexOf(from);
  const e = html.indexOf(to, s + from.length);
  if (s < 0 || e < 0) throw new Error('marker: ' + from);
  return html.slice(s, e);
}
const parts = [
  slice('function renderPixels(target, view)', 'function updateMapStatus()'),
  slice('function compatibleTexture(kind)', 'function clearTexture(kind)'),
  slice('function applySurfaceHints(output, foreground, hints, kind, gain = 1)', 'function generateTexture('),
  slice('function generateTexture(albedo, options)', 'const presetDefaults'),
];
const wrapper = `
  let W = 1, H = 1, lx = 0, ly = 0, normals = null, albedoLinear = null;
  const linear = (v) => { v /= 255; return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
  const srgb = (v) => Math.round(255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * Math.pow(v, 1 / 2.4) - 0.055));
  function rgb(hex) { return [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16)); }
  const sliderNumber = (id) => Number($(id).value);
  ${parts.join('\n')}
  return {
    setState(s) { W = s.W; H = s.H; lx = s.lx; ly = s.ly; normals = s.normals; albedoLinear = s.albedoLinear; },
    renderPixels, generateTexture,
  };
`;
const CUR = {
  lightHex: '#ffffff',
  bgHex: '#2b7ca7',
  hideBg: false,
  sliders: { height: 25, falloff: 70, power: 2.5, ambient: 15, 'mask-strength': 100 },
};
function $(id) {
  if (id === 'hide-bg') return { checked: false };
  if (id === 'light-color') return { value: CUR.lightHex };
  if (id === 'bg-color') return { value: CUR.bgHex };
  return { value: String(CUR.sliders[id] ?? 0) };
}
const textures = { albedo: null, normal: null, mask: null };
const api = new Function('$', 'textures', wrapper)($, textures);

const buf = fs.readFileSync(RAW);
const albedo = { w: W, h: H, data: new Uint8ClampedArray(buf.buffer, buf.byteOffset, buf.length) };

const opts = {
  kind: 'normal',
  preset: 'object',
  strength: 100,
  normalStrength: 100,
  edgeWidth: 3,
  facets: 35,
  floor: 20,
  ceiling: 255,
  cavity: 35,
  hints: null,
  merge: true,
  bg: [43, 124, 167],
  hide: false,
};

// 预热 JIT
api.generateTexture(albedo, opts);
api.generateTexture(albedo, { ...opts, kind: 'mask' });

function bench(label, fn, times) {
  const t0 = process.hrtime.bigint();
  for (let i = 0; i < times; i++) fn();
  const t1 = process.hrtime.bigint();
  const ms = Number(t1 - t0) / 1e6 / times;
  console.log(`  ${label}: ${ms.toFixed(2)} ms`);
  return ms;
}

console.log(`原版 JS 基准  ${W}×${H}  (${(W * H / 10000).toFixed(1)} 万像素)`);
const genN = bench('法线图生成', () => api.generateTexture(albedo, opts), 10);
const maskN = bench('遮罩生成', () => api.generateTexture(albedo, { ...opts, kind: 'mask' }), 10);

const normalTex = api.generateTexture(albedo, opts);
const maskTex = api.generateTexture(albedo, { ...opts, kind: 'mask' });
const albedoLinear = new Float32Array(W * H * 3);
for (let i = 0; i < W * H; i++) {
  for (let c = 0; c < 3; c++) {
    let v = albedo.data[i * 4 + c] / 255;
    albedoLinear[i * 3 + c] = v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
  }
}
const normals = new Float32Array(W * H * 3);
for (let i = 0; i < W * H; i++) {
  const v = [(normalTex.data[i * 4] / 255) * 2 - 1, (normalTex.data[i * 4 + 1] / 255) * 2 - 1, (normalTex.data[i * 4 + 2] / 255) * 2 - 1];
  const len = Math.hypot(v[0], v[1], v[2]) || 1;
  for (let c = 0; c < 3; c++) normals[i * 3 + c] = v[c] / len;
}
api.setState({ W, H, lx: W / 2, ly: H / 2, normals, albedoLinear });
textures.albedo = albedo;
textures.normal = normalTex;
textures.mask = maskTex;
const target = { createImageData: (w, h) => ({ width: w, height: h, data: new Uint8ClampedArray(w * h * 4) }) };
const litMs = bench('打光渲染', () => api.renderPixels(target, 'lit'), 50);
console.log(`  折算: ${(W * H / litMs / 1000).toFixed(1)} 百万像素/秒`);
console.log(JSON.stringify({ gen: genN, mask: maskN, lit: litMs }));
