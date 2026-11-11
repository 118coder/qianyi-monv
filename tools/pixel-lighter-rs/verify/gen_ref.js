// 从原版 HTML 中原样抽取算法函数，在 Node 里跑出参考结果。
// 目的：给 Rust 移植版提供逐字节对照的黄金数据。
// 注意：本脚本不修改算法代码，只注入它依赖的外部变量。
const fs = require('fs');
const path = require('path');

const HTML = process.argv[2];
const OUT = process.argv[3];
if (!HTML || !OUT) {
  console.error('用法: node gen_ref.js <html> <outdir>');
  process.exit(1);
}
const html = fs.readFileSync(HTML, 'utf8');

function slice(from, to) {
  const s = html.indexOf(from);
  if (s < 0) throw new Error('找不到起点: ' + from);
  const e = html.indexOf(to, s + from.length);
  if (e < 0) throw new Error('找不到终点: ' + to);
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
    renderPixels, generateTexture, applySurfaceHints,
  };
`;

let CUR = {};
function $shim(id) {
  if (id === 'hide-bg') return { checked: !!CUR.hideBg, value: '' };
  if (id === 'light-color') return { value: CUR.lightHex };
  if (id === 'bg-color') return { value: CUR.bgHex };
  return { value: String(CUR.sliders[id] ?? 0), checked: false };
}

const textures = { albedo: null, normal: null, mask: null };
const api = new Function('$', 'textures', wrapper)($shim, textures);

// ---------------------------------------------------------------- 测试图案
// 确定性伪随机
let seed = 123456789;
function rnd() {
  seed = (seed * 1103515245 + 12345) & 0x7fffffff;
  return seed / 0x7fffffff;
}

const W = 72;
const H = 56;
const BG = [43, 124, 167];

function makeAlbedo() {
  const data = new Uint8ClampedArray(W * H * 4);
  const put = (x, y, r, g, b, a) => {
    if (x < 0 || y < 0 || x >= W || y >= H) return;
    const i = (y * W + x) * 4;
    data[i] = r;
    data[i + 1] = g;
    data[i + 2] = b;
    data[i + 3] = a;
  };
  // 背景（模拟纯色底，用来测隐藏背景）
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) put(x, y, BG[0], BG[1], BG[2], 255);

  // 1. 一个带 1px 深色描边的"角色"色块，内部 4 级明暗（测聚类 + 细描边 + 合并）
  const cx = 22, cy = 26, rx = 13, ry = 17;
  for (let y = cy - ry; y <= cy + ry; y++) {
    for (let x = cx - rx; x <= cx + rx; x++) {
      const d = Math.hypot((x - cx) / rx, (y - cy) / ry);
      if (d > 1) continue;
      const edge = d > 0.86;
      const shade = d < 0.3 ? 236 : d < 0.55 ? 196 : d < 0.75 ? 150 : 104;
      if (edge) put(x, y, 34, 30, 42, 255);
      else put(x, y, shade, Math.round(shade * 0.82), Math.round(shade * 0.66), 255);
    }
  }

  // 2. 渐变块（测梯度 + 量化 + 切面）
  for (let y = 8; y < 44; y++) {
    for (let x = 40; x < 66; x++) {
      const v = Math.round(40 + ((x - 40) / 25) * 190 + Math.sin(y * 0.5) * 12);
      const c = Math.max(0, Math.min(255, v));
      put(x, y, c, c, Math.round(c * 0.9), 255);
    }
  }
  // 渐变块 1px 描边
  for (let x = 39; x <= 66; x++) {
    put(x, 7, 20, 20, 28, 255);
    put(x, 44, 20, 20, 28, 255);
  }
  for (let y = 7; y <= 44; y++) {
    put(39, y, 20, 20, 28, 255);
    put(66, y, 20, 20, 28, 255);
  }

  // 3. 两个同色分离方块（测聚类不串色）
  for (let y = 47; y < 53; y++) {
    for (let x = 4; x < 14; x++) put(x, y, 163, 73, 164, 255);
    for (let x = 18; x < 28; x++) put(x, y, 163, 73, 164, 255);
  }

  // 4. 噪点区（测距离场与小岛修正）
  for (let y = 2; y < 6; y++) {
    for (let x = 58; x < 70; x++) {
      const on = rnd() > 0.45;
      put(x, y, on ? 220 : 60, on ? 210 : 50, on ? 190 : 40, 255);
    }
  }

  // 5. 半透明与全透明像素
  for (let y = 46; y < 54; y++) {
    for (let x = 44; x < 56; x++) put(x, y, 255, 240, 200, 128);
  }
  for (let y = 0; y < 3; y++) for (let x = 0; x < 6; x++) put(x, y, 0, 0, 0, 0);

  return { w: W, h: H, data };
}

function toHex(c) {
  return '#' + c.map((v) => v.toString(16).padStart(2, '0')).join('');
}

const albedo = makeAlbedo();
fs.writeFileSync(path.join(OUT, 'input_72x56.raw'), Buffer.from(albedo.data.buffer));

const baseOpts = {
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
  bg: BG,
  hide: false,
};

function gen(kind, over) {
  const opts = Object.assign({}, baseOpts, { kind }, over || {});
  return api.generateTexture(albedo, opts);
}

const cases = [];
function dump(name, kind, over, extra) {
  const r = gen(kind, over);
  fs.writeFileSync(path.join(OUT, name + '.raw'), Buffer.from(r.data.buffer));
  cases.push(Object.assign({ name, kind }, over || {}, extra || {}));
}

// 四种预设 + 合并开关 + 切面开关 + 边宽
dump('normal_object', 'normal', {});
dump('normal_architecture', 'normal', { preset: 'architecture', edgeWidth: 1, facets: 20, strength: 100 });
dump('normal_terrain', 'normal', { preset: 'terrain', edgeWidth: 3, facets: 50, strength: 110 });
dump('normal_character', 'normal', { preset: 'character', edgeWidth: 2, facets: 15, strength: 65 });
dump('normal_nomerge', 'normal', { merge: false });
dump('normal_nofacets', 'normal', { facets: 0 });
dump('normal_gain150', 'normal', { normalStrength: 150 });
dump('normal_hidebg', 'normal', { hide: true, edgeWidth: 2 });
dump('mask_object', 'mask', { strength: 100, floor: 20, ceiling: 255, cavity: 35 });
dump('mask_soft', 'mask', { strength: 60, floor: 45, ceiling: 220, cavity: 0, merge: false });

// 二分定位用：逐项关掉 blur / merge / facets
dump('bis_plain', 'normal', { edgeWidth: 0, merge: false, facets: 0 });
dump('bis_blur', 'normal', { edgeWidth: 3, merge: false, facets: 0 });
dump('bis_blur1', 'normal', { edgeWidth: 1, merge: false, facets: 0 });
dump('bis_merge', 'normal', { edgeWidth: 3, merge: true, facets: 0 });
dump('bis_facets', 'normal', { edgeWidth: 3, merge: false, facets: 35 });

// ---------------------------------------------------------------- 光照
// 复刻 rebuild()：线性化底图 + 归一化法线
const normalTex = gen('normal', {});
const maskTex = gen('mask', {});

function lin(v) {
  v /= 255;
  return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
}

const albedoLinear = new Float32Array(W * H * 3);
for (let i = 0; i < W * H; i++) {
  for (let c = 0; c < 3; c++) albedoLinear[i * 3 + c] = lin(albedo.data[i * 4 + c]);
}

function computeNormals(n) {
  const out = new Float32Array(W * H * 3);
  for (let i = 0; i < W * H; i++) {
    const v = [
      (n.data[i * 4] / 255) * 2 - 1,
      (n.data[i * 4 + 1] / 255) * 2 - 1,
      (n.data[i * 4 + 2] / 255) * 2 - 1,
    ];
    const len = Math.hypot(v[0], v[1], v[2]) || 1;
    for (let c = 0; c < 3; c++) out[i * 3 + c] = v[c] / len;
  }
  return out;
}

const normals = computeNormals(normalTex);

const flatNormals = new Float32Array(W * H * 3);
for (let i = 0; i < W * H; i++) flatNormals[i * 3 + 2] = 1;

function renderLit(p) {
  CUR = {
    lightHex: toHex(p.light),
    bgHex: toHex(p.bg),
    hideBg: p.hide,
    sliders: {
      height: p.height,
      falloff: p.falloff,
      power: p.power,
      ambient: p.ambient,
      'mask-strength': p.maskMix,
    },
  };
  api.setState({ W, H, lx: p.lx, ly: p.ly, normals: p.normal ? normals : flatNormals, albedoLinear });
  textures.albedo = albedo;
  textures.normal = p.normal ? normalTex : null;
  textures.mask = p.mask ? maskTex : null;
  const target = {
    createImageData: (w, h) => ({ width: w, height: h, data: new Uint8ClampedArray(w * h * 4) }),
  };
  const out = api.renderPixels(target, p.view || 'lit');
  return out.data;
}

const litCases = [
  { name: 'lit_center', p: { lx: 36, ly: 28, height: 25, falloff: 70, power: 2.5, ambient: 15, maskMix: 100, light: [255, 255, 255], bg: BG, hide: false, normal: true, mask: true } },
  { name: 'lit_topleft_warm', p: { lx: 5, ly: 3, height: 120, falloff: 30, power: 6.5, ambient: 4, maskMix: 60, light: [255, 196, 120], bg: BG, hide: false, normal: true, mask: true } },
  { name: 'lit_nomask_blue', p: { lx: 80, ly: 70, height: 200, falloff: 200, power: 1.2, ambient: 40, maskMix: 0, light: [90, 140, 255], bg: BG, hide: true, normal: true, mask: false } },
  { name: 'lit_flathide', p: { lx: 10, ly: 50, height: 5, falloff: 10, power: 25, ambient: 0, maskMix: 100, light: [255, 255, 255], bg: BG, hide: true, normal: false, mask: false } },
];

for (const c of litCases) {
  const data = renderLit(c.p);
  fs.writeFileSync(path.join(OUT, c.name + '.raw'), Buffer.from(data.buffer));
}

// 视图模式参考
const views = [
  { name: 'view_albedo', view: 'albedo' },
  { name: 'view_normal', view: 'normal' },
  { name: 'view_mask', view: 'mask' },
];
for (const v of views) {
  const data = renderLit({ lx: 36, ly: 28, height: 25, falloff: 70, power: 2.5, ambient: 15, maskMix: 100, light: [255, 255, 255], bg: BG, hide: false, normal: true, mask: true, view: v.view });
  fs.writeFileSync(path.join(OUT, v.name + '.raw'), Buffer.from(data.buffer));
}

fs.writeFileSync(
  path.join(OUT, 'cases.json'),
  JSON.stringify({ w: W, h: H, bg: BG, gen: cases, lit: litCases.map((c) => Object.assign({ name: c.name }, c.p)) }, null, 2),
);

console.log('已生成参考数据 ->', OUT);
console.log('文件:', fs.readdirSync(OUT).length);
