//! 像素打光核心算法 —— 由 Pixel-Art-Lighter v3.5.23 的 JS 实现 1:1 移植。
//!
//! 精度策略：原版 JS 的标量运算是 IEEE-754 double（对应 `f64`），但中间缓存
//! 用 `Float32Array` 存储（`lum` / `distance` / `field` / `dirs` 以及渲染缓存的
//! 反照率与法线）。这里刻意照抄这一分层——标量算 `f64`、落盘进 `Vec<f32>`——
//! 否则末位舍入会累积成 1 个色阶的偏差。`tests/golden.rs` 的 22 项对照即验此事。
//!
//! 与原版一样，逐像素运算被 rayon 并行化，因此速度随核心数线性提升。

use rayon::prelude::*;

pub const LUMA_R: f64 = 0.2126;
pub const LUMA_G: f64 = 0.7152;
pub const LUMA_B: f64 = 0.0722;

/// 与 Math.round 一致（.5 向 +∞ 取整）
#[inline]
pub fn js_round(x: f64) -> i32 {
    (x + 0.5).floor() as i32
}

#[inline]
pub fn clamp01(x: f64) -> f64 {
    if x < 0.0 {
        0.0
    } else if x > 1.0 {
        1.0
    } else {
        x
    }
}

#[inline]
pub fn linear_from_u8(v: u8) -> f64 {
    let v = v as f64 / 255.0;
    if v <= 0.04045 {
        v / 12.92
    } else {
        ((v + 0.055) / 1.055).powf(2.4)
    }
}

#[inline]
pub fn srgb_from_linear(v: f64) -> u8 {
    let s = if v <= 0.0031308 {
        12.92 * v
    } else {
        1.055 * v.powf(1.0 / 2.4) - 0.055
    };
    js_round(255.0 * s).clamp(0, 255) as u8
}

#[inline]
fn hypot3(a: f64, b: f64, c: f64) -> f64 {
    (a * a + b * b + c * c).sqrt()
}

#[inline]
fn unit3(v: [f64; 3]) -> [f64; 3] {
    let len = hypot3(v[0], v[1], v[2]);
    let len = if len == 0.0 { 1.0 } else { len };
    [v[0] / len, v[1] / len, v[2] / len]
}

#[inline]
fn luma(r: u8, g: u8, b: u8) -> f64 {
    (LUMA_R * r as f64 + LUMA_G * g as f64 + LUMA_B * b as f64) / 255.0
}

/// 4 邻域遍历，顺序与原版 adjacent() 完全一致：左、右、上、下
#[inline]
fn for_each_neighbor<F: FnMut(usize)>(i: usize, w: usize, h: usize, mut f: F) {
    let x = i % w;
    let y = i / w;
    if x > 0 {
        f(i - 1);
    }
    if x + 1 < w {
        f(i + 1);
    }
    if y > 0 {
        f(i - w);
    }
    if y + 1 < h {
        f(i + w);
    }
}

/// RGBA8 图像
#[derive(Clone)]
pub struct Img {
    pub w: usize,
    pub h: usize,
    pub data: Vec<u8>,
}

impl Img {
    pub fn new(w: usize, h: usize) -> Self {
        Self {
            w,
            h,
            data: vec![0u8; w * h * 4],
        }
    }

    pub fn from_rgba(w: usize, h: usize, data: Vec<u8>) -> Self {
        debug_assert_eq!(data.len(), w * h * 4);
        Self { w, h, data }
    }

    #[inline]
    pub fn n(&self) -> usize {
        self.w * self.h
    }

    #[inline]
    pub fn same_size(&self, w: usize, h: usize) -> bool {
        self.w == w && self.h == h
    }

    /// 边缘最常见的不透明颜色（原版 Detect BG）
    pub fn detect_bg(&self) -> Option<[u8; 3]> {
        use std::collections::HashMap;
        let mut counts: HashMap<(u8, u8, u8), usize> = HashMap::new();
        let mut take = |x: usize, y: usize| {
            let i = (y * self.w + x) * 4;
            if self.data[i + 3] != 255 {
                return;
            }
            *counts
                .entry((self.data[i], self.data[i + 1], self.data[i + 2]))
                .or_insert(0) += 1;
        };
        for x in 0..self.w {
            take(x, 0);
            take(x, self.h - 1);
        }
        for y in 1..self.h.saturating_sub(1) {
            take(0, y);
            take(self.w - 1, y);
        }
        counts
            .into_iter()
            .max_by_key(|(_, c)| *c)
            .map(|(k, _)| [k.0, k.1, k.2])
    }
}

// ---------------------------------------------------------------------------
// 光照渲染
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ViewMode {
    Final,
    Albedo,
    Normal,
    Mask,
}

#[derive(Clone, Debug)]
pub struct LightSettings {
    /// 光源横坐标（像素坐标）
    pub lx: f64,
    /// 光源纵坐标（像素坐标）
    pub ly: f64,
    /// 光源高度（原版 Height 滑块，5..200）
    pub height: f64,
    /// 衰减半径（原版 Falloff 滑块，10..200）
    pub falloff: f64,
    /// 亮度（原版 Brightness 滑块，0..25）
    pub power: f64,
    /// 环境光，0..1（原版 Ambient 百分比 / 100）
    pub ambient: f64,
    /// 遮罩混合强度，0..1（原版 Light Mask 百分比 / 100）
    pub mask_mix: f64,
    /// 光色（sRGB）
    pub light: [u8; 3],
    pub hide_bg: bool,
    pub bg: [u8; 3],
}

impl Default for LightSettings {
    fn default() -> Self {
        Self {
            lx: 0.0,
            ly: 0.0,
            height: 25.0,
            falloff: 70.0,
            power: 2.5,
            ambient: 0.15,
            mask_mix: 1.0,
            light: [255, 255, 255],
            hide_bg: false,
            bg: [43, 124, 167],
        }
    }
}

impl LightSettings {
    #[inline]
    fn light_linear(&self) -> [f64; 3] {
        [
            linear_from_u8(self.light[0]),
            linear_from_u8(self.light[1]),
            linear_from_u8(self.light[2]),
        ]
    }
}

/// 预计算缓存：底图线性化 + 法线归一化。底图/法线变动时重建一次。
/// 注意：中间量用 f32 存储，与原版 Float32Array 对齐（否则会有 1 个色阶的偏差）。
pub struct RenderCache {
    pub w: usize,
    pub h: usize,
    /// 3 * N 线性化后的底图 RGB
    pub albedo_lin: Vec<f32>,
    /// 3 * N 归一化后的法线
    pub normals: Vec<f32>,
}

impl RenderCache {
    pub fn build(albedo: &Img, normal: Option<&Img>) -> Self {
        let w = albedo.w;
        let h = albedo.h;
        let n = w * h;

        let mut albedo_lin = vec![0.0f32; n * 3];
        albedo_lin
            .par_chunks_mut(3)
            .enumerate()
            .for_each(|(i, dst)| {
                let k = i * 4;
                dst[0] = linear_from_u8(albedo.data[k]) as f32;
                dst[1] = linear_from_u8(albedo.data[k + 1]) as f32;
                dst[2] = linear_from_u8(albedo.data[k + 2]) as f32;
            });

        let valid = normal.map_or(false, |t| t.same_size(w, h));
        let mut normals = vec![0.0f32; n * 3];
        normals.par_chunks_mut(3).enumerate().for_each(|(i, dst)| {
            let v: [f64; 3] = if valid {
                let t = normal.unwrap();
                let k = i * 4;
                [
                    (t.data[k] as f64 / 255.0) * 2.0 - 1.0,
                    (t.data[k + 1] as f64 / 255.0) * 2.0 - 1.0,
                    (t.data[k + 2] as f64 / 255.0) * 2.0 - 1.0,
                ]
            } else {
                [0.0, 0.0, 1.0]
            };
            let len = hypot3(v[0], v[1], v[2]);
            let len = if len == 0.0 { 1.0 } else { len };
            dst[0] = (v[0] / len) as f32;
            dst[1] = (v[1] / len) as f32;
            dst[2] = (v[2] / len) as f32;
        });

        Self {
            w,
            h,
            albedo_lin,
            normals,
        }
    }
}

/// 等价于原版 renderPixels()，返回 RGBA 字节。
pub fn render_view(
    cache: &RenderCache,
    albedo: &Img,
    normal: Option<&Img>,
    mask: Option<&Img>,
    s: &LightSettings,
    view: ViewMode,
) -> Vec<u8> {
    let w = cache.w;
    let h = cache.h;
    let mut out = vec![0u8; w * h * 4];

    let light = s.light_linear();
    let z = s.height;
    let radius = s.falloff.max(0.000001);
    let power = s.power;
    let ambient = s.ambient;
    let mask_mix = s.mask_mix;
    let lx = s.lx;
    let ly = s.ly;

    let normal_ok = normal.map_or(false, |t| t.same_size(w, h));
    let mask_ok = mask.map_or(false, |t| t.same_size(w, h));

    out.par_chunks_mut(w * 4).enumerate().for_each(|(y, row)| {
        for x in 0..w {
            let i = y * w + x;
            let k = i * 4;
            let alpha = if s.hide_bg
                && albedo.data[k] == s.bg[0]
                && albedo.data[k + 1] == s.bg[1]
                && albedo.data[k + 2] == s.bg[2]
            {
                0
            } else {
                albedo.data[k + 3]
            };
            let o = &mut row[x * 4..x * 4 + 4];
            o[3] = alpha;
            if alpha == 0 {
                o[0] = 0;
                o[1] = 0;
                o[2] = 0;
                continue;
            }

            match view {
                ViewMode::Albedo => {
                    o[0] = albedo.data[k];
                    o[1] = albedo.data[k + 1];
                    o[2] = albedo.data[k + 2];
                }
                ViewMode::Normal => {
                    if normal_ok {
                        let t = normal.unwrap();
                        o[0] = t.data[k];
                        o[1] = t.data[k + 1];
                        o[2] = t.data[k + 2];
                    } else {
                        o[0] = 128;
                        o[1] = 128;
                        o[2] = 255;
                    }
                }
                ViewMode::Mask => {
                    let m = if mask_ok {
                        let t = mask.unwrap();
                        0.2126 * t.data[k] as f64
                            + 0.7152 * t.data[k + 1] as f64
                            + 0.0722 * t.data[k + 2] as f64
                    } else {
                        255.0
                    } / 255.0;
                    let v = js_round(m * 255.0).clamp(0, 255) as u8;
                    o[0] = v;
                    o[1] = v;
                    o[2] = v;
                }
                ViewMode::Final => {
                    let m = if mask_ok {
                        let t = mask.unwrap();
                        0.2126 * t.data[k] as f64
                            + 0.7152 * t.data[k + 1] as f64
                            + 0.0722 * t.data[k + 2] as f64
                    } else {
                        255.0
                    } / 255.0;

                    let dx = lx - x as f64;
                    let dy = y as f64 - ly;
                    let d = hypot3(dx, dy, z).max(0.000001);
                    let nd = &cache.normals[i * 3..i * 3 + 3];
                    let diffuse = ((nd[0] as f64 * dx + nd[1] as f64 * dy + nd[2] as f64 * z) / d)
                        .max(0.0);
                    let t = d / radius.max(0.000001);
                    let atten = 1.0 / (1.0 + t * t);
                    let direct = power * diffuse * atten * (1.0 - mask_mix + mask_mix * m);
                    for c in 0..3 {
                        let base = cache.albedo_lin[i * 3 + c] as f64;
                        o[c] = srgb_from_linear(base * (ambient + direct * light[c]));
                    }
                }
            }
        }
    });

    out
}

// ---------------------------------------------------------------------------
// 法线图 / 光照遮罩 生成
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GenKind {
    Normal,
    Mask,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Preset {
    Architecture,
    Object,
    Terrain,
    Character,
}

impl Preset {
    pub fn from_index(i: usize) -> Self {
        match i {
            0 => Preset::Architecture,
            1 => Preset::Object,
            2 => Preset::Terrain,
            _ => Preset::Character,
        }
    }
    pub fn index(self) -> usize {
        match self {
            Preset::Architecture => 0,
            Preset::Object => 1,
            Preset::Terrain => 2,
            Preset::Character => 3,
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Preset::Architecture => "建筑",
            Preset::Object => "物体",
            Preset::Terrain => "地形",
            Preset::Character => "角色",
        }
    }
    /// 原版 presetDefaults
    pub fn defaults(self) -> (f64, f64, f64, f64, f64) {
        // (strength, facets, floor, ceiling, cavity)
        match self {
            Preset::Architecture => (100.0, 20.0, 30.0, 255.0, 25.0),
            Preset::Object => (100.0, 35.0, 20.0, 255.0, 35.0),
            Preset::Terrain => (110.0, 50.0, 35.0, 255.0, 20.0),
            Preset::Character => (65.0, 15.0, 30.0, 255.0, 20.0),
        }
    }
    pub fn default_edge_width(self) -> f64 {
        match self {
            Preset::Architecture => 1.0,
            Preset::Character => 2.0,
            _ => 3.0,
        }
    }
}

/// 凸起项系数（原版内联三元表达式）
#[inline]
fn convex_factor(p: Preset) -> f64 {
    match p {
        Preset::Architecture => 0.0,
        Preset::Terrain => 0.12,
        _ => 0.65,
    }
}

#[derive(Clone, Debug)]
pub struct GenOptions {
    pub kind: GenKind,
    pub preset: Preset,
    /// 强度 0..200
    pub strength: f64,
    /// 法线强度 0..300
    pub normal_strength: f64,
    /// 模糊遍数 0..6
    pub edge_width: f64,
    /// 切面数量 0..100
    pub facets: f64,
    /// 遮罩下限 0..255
    pub floor: f64,
    /// 遮罩上限 0..255
    pub ceiling: f64,
    /// 凹槽压暗 0..100
    pub cavity: f64,
    /// 合并描边
    pub merge: bool,
    pub bg: [u8; 3],
    pub hide: bool,
}

impl Default for GenOptions {
    fn default() -> Self {
        Self {
            kind: GenKind::Normal,
            preset: Preset::Object,
            strength: 100.0,
            normal_strength: 100.0,
            edge_width: 3.0,
            facets: 35.0,
            floor: 20.0,
            ceiling: 255.0,
            cavity: 35.0,
            merge: true,
            bg: [43, 124, 167],
            hide: false,
        }
    }
}

/// 生成过程中间结果，可用于同一底图下快速换参数（遮罩重算很快，这里不做缓存）
pub struct GenResult {
    pub img: Img,
    /// 前景掩码（不透明且非背景色）
    pub fg: Vec<bool>,
}

/// 等价于原版 generateTexture()
pub fn generate(albedo: &Img, o: &GenOptions) -> GenResult {
    let w = albedo.w;
    let h = albedo.h;
    let n = w * h;
    let a = &albedo.data;

    // --- 前景 + 亮度 ---
    let mut fg = vec![false; n];
    let mut lum = vec![0.0f32; n];
    fg.par_iter_mut()
        .zip(lum.par_iter_mut())
        .enumerate()
        .for_each(|(i, (fg_i, lum_i))| {
            let k = i * 4;
            *fg_i = a[k + 3] > 0
                && !(o.hide && a[k] == o.bg[0] && a[k + 1] == o.bg[1] && a[k + 2] == o.bg[2]);
            *lum_i = luma(a[k], a[k + 1], a[k + 2]) as f32;
        });

    let mut lo = f64::INFINITY;
    let mut hi = f64::NEG_INFINITY;
    for i in 0..n {
        if fg[i] {
            let l = lum[i] as f64;
            if l < lo {
                lo = l;
            }
            if l > hi {
                hi = l;
            }
        }
    }
    let range = hi - lo;
    let normalized = |i: usize| -> f64 {
        if range > 1e-5 {
            (lum[i] as f64 - lo) / range
        } else {
            0.75
        }
    };

    // --- 同色连通块 ---
    let mut labels: Vec<i32> = vec![-1; n];
    let mut clusters: Vec<Vec<u32>> = Vec::new();
    let mut cluster_value: Vec<f64> = Vec::new();
    let mut queue: Vec<u32> = Vec::with_capacity(n);
    for i in 0..n {
        if fg[i] && labels[i] < 0 {
            let id = clusters.len() as i32;
            let k = i * 4;
            let (cr, cg, cb) = (a[k], a[k + 1], a[k + 2]);
            queue.clear();
            queue.push(i as u32);
            labels[i] = id;
            let mut pixels: Vec<u32> = Vec::new();
            let mut head = 0usize;
            while head < queue.len() {
                let p = queue[head] as usize;
                head += 1;
                pixels.push(p as u32);
                for_each_neighbor(p, w, h, |nb| {
                    if fg[nb] && labels[nb] < 0 {
                        let m = nb * 4;
                        if a[m] == cr && a[m + 1] == cg && a[m + 2] == cb {
                            labels[nb] = id;
                            queue.push(nb as u32);
                        }
                    }
                });
            }
            clusters.push(pixels);
            cluster_value.push(lum[i] as f64);
        }
    }

    // --- 边界距离场（多源 BFS） ---
    let mut distance = vec![n as f32; n];
    let mut head = 0usize;
    let mut tail = 0usize;
    queue.clear();
    for i in 0..n {
        if !fg[i] {
            continue;
        }
        let x = i % w;
        let y = i / w;
        let mut boundary = x == 0 || x == w - 1 || y == 0 || y == h - 1;
        if !boundary {
            for_each_neighbor(i, w, h, |nb| {
                if !fg[nb] {
                    boundary = true;
                }
            });
        }
        if boundary {
            distance[i] = 1.0;
            queue.push(i as u32);
            tail += 1;
        }
    }
    while head < tail {
        let p = queue[head] as usize;
        head += 1;
        let dp = distance[p] as f64;
        for_each_neighbor(p, w, h, |nb| {
            if fg[nb] && distance[nb] as f64 > dp + 1.0 {
                distance[nb] = (dp + 1.0) as f32;
                queue.push(nb as u32);
                tail += 1;
            }
        });
    }

    // --- 细描边检测 ---
    let mut thin = vec![false; n];
    if o.merge {
        for (ci, cluster) in clusters.iter().enumerate() {
            if cluster_value[ci] > lo + range * 0.24 {
                continue;
            }
            let mut interior = 0usize;
            for &p in cluster.iter() {
                let p = p as usize;
                let x = p % w;
                let y = p / w;
                if x == 0 || x == w - 1 || y == 0 || y == h - 1 {
                    continue;
                }
                let lab = labels[p];
                let mut all_same = true;
                let mut cnt = 0;
                for_each_neighbor(p, w, h, |nb| {
                    cnt += 1;
                    if labels[nb] != lab {
                        all_same = false;
                    }
                });
                if cnt == 4 && all_same {
                    interior += 1;
                }
            }
            if (interior as f64) / (cluster.len() as f64) < 0.15 {
                for &p in cluster.iter() {
                    thin[p as usize] = true;
                }
            }
        }
    }

    let mut output = vec![0u8; n * 4];

    if o.kind == GenKind::Mask {
        let strength = o.strength / 100.0;
        let floor = o.floor / 255.0;
        let cavity = o.cavity / 100.0;
        for (ci, cluster) in clusters.iter().enumerate() {
            let value = cluster_value[ci];
            let t = if range > 1e-5 {
                (value - lo) / range
            } else {
                0.75
            };
            let mut receive = floor + (1.0 - floor) * t.powf(1.15);
            if cavity != 0.0 && t < 0.35 {
                let mut surrounded = 0usize;
                for &p in cluster.iter() {
                    let p = p as usize;
                    let lab = labels[p];
                    let mut higher = 0usize;
                    let mut total = 0usize;
                    for_each_neighbor(p, w, h, |nb| {
                        if fg[nb] && labels[nb] != lab {
                            total += 1;
                            if lum[nb] as f64 > value + range * 0.15 {
                                higher += 1;
                            }
                        }
                    });
                    if total > 0 && (higher as f64) / (total as f64) > 0.5 {
                        surrounded += 1;
                    }
                }
                let denom = (cluster.len() as f64).sqrt().max(1.0);
                let f = if denom > 0.0 {
                    (surrounded as f64 / denom).min(1.0)
                } else {
                    0.0
                };
                receive *= 1.0 - cavity * f;
            }
            receive = 1.0 - strength + strength * receive;
            let ceil = o.ceiling / 255.0;
            let rec = receive.min(ceil).max(0.0);
            let v = js_round(255.0 * rec).clamp(0, 255) as u8;
            for &p in cluster.iter() {
                let p = p as usize;
                output[p * 4] = v;
                output[p * 4 + 1] = v;
                output[p * 4 + 2] = v;
                output[p * 4 + 3] = a[p * 4 + 3];
            }
        }
    } else {
        let preset = o.preset;
        let scale = o.strength / 100.0;
        let mut field = vec![0.0f32; n];
        field.par_iter_mut().enumerate().for_each(|(i, f)| {
            if fg[i] {
                let cap = if preset == Preset::Character { 8.0 } else { 16.0 };
                let convex = (distance[i] as f64).min(cap).sqrt() * convex_factor(preset);
                let slope = match preset {
                    Preset::Architecture => 3.5,
                    Preset::Terrain => 4.0,
                    Preset::Character => 1.2,
                    Preset::Object => 2.1,
                };
                *f = (convex + normalized(i) * slope) as f32;
            }
        });

        let passes = o.edge_width.max(0.0).round() as usize;
        for _ in 0..passes {
            let mut blurred = vec![0.0f32; n];
            blurred.par_iter_mut().enumerate().for_each(|(i, b)| {
                if !fg[i] {
                    return;
                }
                let mut sum = field[i] as f64 * 2.0;
                let mut count = 2.0f64;
                for_each_neighbor(i, w, h, |nb| {
                    if fg[nb] {
                        sum += field[nb] as f64;
                        count += 1.0;
                    }
                });
                *b = (sum / count) as f32;
            });
            field = blurred;
        }

        let mut dirs = vec![0.0f32; n * 3];
        let normal_gain = o.normal_strength / 100.0;

        let quantize = |v: [f64; 3]| -> [f64; 3] {
            let v = unit3(v);
            let tilt = (v[0] * v[0] + v[1] * v[1]).sqrt();
            if tilt < 0.12 {
                return [0.0, 0.0, 1.0];
            }
            let angle = js_round(v[1].atan2(v[0]) / (std::f64::consts::PI / 4.0)) as f64
                * (std::f64::consts::PI / 4.0);
            let elevation = if preset == Preset::Architecture {
                (0.6 * scale).min(0.9)
            } else if tilt < 0.3 {
                0.24
            } else if tilt < 0.6 {
                0.48
            } else if tilt < 0.85 {
                0.72
            } else {
                0.9
            };
            [
                angle.cos() * elevation,
                angle.sin() * elevation,
                (1.0 - elevation * elevation).sqrt(),
            ]
        };

        // 梯度（借用 fg 判断，越界回落到自身）
        dirs.par_chunks_mut(3).enumerate().for_each(|(i, d)| {
            if !fg[i] {
                return;
            }
            let x = i % w;
            let y = i / w;
            let at = |nb: usize| -> f64 {
                if nb < n && fg[nb] {
                    field[nb] as f64
                } else {
                    field[i] as f64
                }
            };
            let dx = if x < w - 1 { at(i + 1) } else { field[i] as f64 }
                - if x > 0 { at(i - 1) } else { field[i] as f64 };
            let dy = if y < h - 1 { at(i + w) } else { field[i] as f64 }
                - if y > 0 { at(i - w) } else { field[i] as f64 };
            let nn = unit3([-dx * scale, dy * scale, 1.0]);
            d[0] = nn[0] as f32;
            d[1] = nn[1] as f32;
            d[2] = nn[2] as f32;
        });

        // 逐连通块统一方向
        for cluster in clusters.iter() {
            let mut sum = [0.0f64; 3];
            for &p in cluster.iter() {
                let p = p as usize;
                let dx = dirs[p * 3] as f64;
                let dy = dirs[p * 3 + 1] as f64;
                if preset == Preset::Architecture && (dx * dx + dy * dy).sqrt() < 0.06 {
                    continue;
                }
                for c in 0..3 {
                    sum[c] += dirs[p * 3 + c] as f64;
                }
            }
            if sum[2] == 0.0 {
                sum = [0.0, 0.0, 1.0];
            }
            let average = unit3(sum);

            // 按 90° 扇区分组（保留首次出现顺序，与原版 Map 迭代顺序一致）
            let split = o.facets > 0.0
                && (cluster.len() as f64) >= js_round(180.0 - o.facets * 1.1) as f64;
            let mut groups: Vec<(i64, Vec<u32>)> = Vec::new();
            if split {
                for &p in cluster.iter() {
                    let p = p as usize;
                    let dx = dirs[p * 3] as f64;
                    let dy = dirs[p * 3 + 1] as f64;
                    let tilt = (dx * dx + dy * dy).sqrt();
                    let key: i64 = if tilt > 0.35 {
                        js_round(dy.atan2(dx) / (std::f64::consts::PI / 2.0)) as i64
                    } else {
                        9
                    };
                    match groups.iter_mut().find(|(k, _)| *k == key) {
                        Some((_, v)) => v.push(p as u32),
                        None => groups.push((key, vec![p as u32])),
                    }
                }
            }
            let min_size = (cluster.len() as f64 * 0.16).max(16.0);
            let supported: Vec<&Vec<u32>> = groups
                .iter()
                .filter(|(_, g)| (g.len() as f64) >= min_size)
                .map(|(_, g)| g)
                .collect();

            let mut allow = false;
            if supported.len() >= 2 {
                let means: Vec<[f64; 3]> = supported
                    .iter()
                    .map(|g| {
                        let mut s = [0.0f64; 3];
                        for &p in g.iter() {
                            let p = p as usize;
                            for c in 0..3 {
                                s[c] += dirs[p * 3 + c] as f64;
                            }
                        }
                        unit3(s)
                    })
                    .collect();
                for i in 0..means.len() {
                    for j in 0..i {
                        let dot = means[i][0] * means[j][0]
                            + means[i][1] * means[j][1]
                            + means[i][2] * means[j][2];
                        if dot < 0.8 - o.facets * 0.001 {
                            allow = true;
                        }
                    }
                }
            }

            let base = quantize(average);
            for &p in cluster.iter() {
                let p = p as usize;
                dirs[p * 3] = base[0] as f32;
                dirs[p * 3 + 1] = base[1] as f32;
                dirs[p * 3 + 2] = base[2] as f32;
            }

            if allow {
                for g in supported {
                    let mut s = [0.0f64; 3];
                    for &p in g.iter() {
                        let p = p as usize;
                        let x = p % w;
                        let y = p / w;
                        let at = |nb: usize| -> f64 {
                            if nb < n && fg[nb] {
                                field[nb] as f64
                            } else {
                                field[p] as f64
                            }
                        };
                        let dx = if x < w - 1 { at(p + 1) } else { field[p] as f64 }
                            - if x > 0 { at(p - 1) } else { field[p] as f64 };
                        let dy = if y < h - 1 { at(p + w) } else { field[p] as f64 }
                            - if y > 0 { at(p - w) } else { field[p] as f64 };
                        let v = unit3([-dx * scale, dy * scale, 1.0]);
                        for c in 0..3 {
                            s[c] += v[c];
                        }
                    }
                    let v = quantize(s);
                    for &p in g.iter() {
                        let p = p as usize;
                        dirs[p * 3] = v[0] as f32;
                        dirs[p * 3 + 1] = v[1] as f32;
                        dirs[p * 3 + 2] = v[2] as f32;
                    }
                }
            }
        }

        // 描边像素继承邻近方向
        if o.merge {
            let mut assigned = vec![false; n];
            queue.clear();
            let mut qhead = 0usize;
            for i in 0..n {
                if fg[i] && !thin[i] {
                    assigned[i] = true;
                    queue.push(i as u32);
                }
            }
            while qhead < queue.len() {
                let p = queue[qhead] as usize;
                qhead += 1;
                let src = [dirs[p * 3], dirs[p * 3 + 1], dirs[p * 3 + 2]];
                for_each_neighbor(p, w, h, |nb| {
                    if fg[nb] && !assigned[nb] {
                        assigned[nb] = true;
                        dirs[nb * 3] = src[0];
                        dirs[nb * 3 + 1] = src[1];
                        dirs[nb * 3 + 2] = src[2];
                        queue.push(nb as u32);
                    }
                });
            }
        }

        // 孤立 1~2 像素小岛修正
        let mut seen = vec![false; n];
        for i in 0..n {
            if !fg[i] || seen[i] {
                continue;
            }
            let mut group: Vec<u32> = Vec::new();
            queue.clear();
            queue.push(i as u32);
            seen[i] = true;
            let mut qhead = 0usize;
            let sx = dirs[i * 3] as f64;
            let sy = dirs[i * 3 + 1] as f64;
            while qhead < queue.len() {
                let p = queue[qhead] as usize;
                qhead += 1;
                group.push(p as u32);
                for_each_neighbor(p, w, h, |nb| {
                    if fg[nb]
                        && !seen[nb]
                        && (dirs[nb * 3] as f64 - sx).abs() < 0.001
                        && (dirs[nb * 3 + 1] as f64 - sy).abs() < 0.001
                    {
                        seen[nb] = true;
                        queue.push(nb as u32);
                    }
                });
            }
            if group.len() <= 2 {
                let mut donor: Option<usize> = None;
                'outer: for &p in group.iter() {
                    let p = p as usize;
                    let mut found: Option<usize> = None;
                    for_each_neighbor(p, w, h, |nb| {
                        if found.is_none() && fg[nb] && !group.contains(&(nb as u32)) {
                            found = Some(nb);
                        }
                    });
                    if let Some(f) = found {
                        donor = Some(f);
                        break 'outer;
                    }
                }
                if let Some(d) = donor {
                    let src = [dirs[d * 3], dirs[d * 3 + 1], dirs[d * 3 + 2]];
                    for &p in group.iter() {
                        let p = p as usize;
                        dirs[p * 3] = src[0];
                        dirs[p * 3 + 1] = src[1];
                        dirs[p * 3 + 2] = src[2];
                    }
                }
            }
        }

        // 编码为法线贴图
        output
            .par_chunks_mut(4)
            .enumerate()
            .for_each(|(i, o4)| {
                let nn = if fg[i] {
                    unit3([
                        dirs[i * 3] as f64 * normal_gain,
                        dirs[i * 3 + 1] as f64 * normal_gain,
                        dirs[i * 3 + 2] as f64,
                    ])
                } else {
                    [0.0, 0.0, 1.0]
                };
                for c in 0..3 {
                    o4[c] = js_round((nn[c] + 1.0) * 127.5).clamp(0, 255) as u8;
                }
                o4[3] = a[i * 4 + 3];
            });
    }

    for i in 0..n {
        output[i * 4 + 3] = a[i * 4 + 3];
    }

    GenResult {
        img: Img::from_rgba(w, h, output),
        fg,
    }
}

/// 原版 modifiedTexture 里的法线强度增益（保持 z 不变后重新归一化）
pub fn apply_normal_strength(img: &mut Img, fg: &[bool], strength: f64) {
    if (strength - 100.0).abs() < f64::EPSILON {
        return;
    }
    let gain = strength / 100.0;
    img.data
        .par_chunks_mut(4)
        .enumerate()
        .for_each(|(p, d)| {
            if !fg.get(p).copied().unwrap_or(false) {
                return;
            }
            let x = ((d[0] as f64 / 255.0) * 2.0 - 1.0) * gain;
            let y = ((d[1] as f64 / 255.0) * 2.0 - 1.0) * gain;
            let z = (d[2] as f64 / 255.0) * 2.0 - 1.0;
            let len = hypot3(x, y, z);
            let len = if len == 0.0 { 1.0 } else { len };
            d[0] = js_round((x / len + 1.0) * 127.5).clamp(0, 255) as u8;
            d[1] = js_round((y / len + 1.0) * 127.5).clamp(0, 255) as u8;
            d[2] = js_round((z / len + 1.0) * 127.5).clamp(0, 255) as u8;
        });
}

// ---------------------------------------------------------------------------
// 手动方向覆盖（原版 applySurfaceHints 的等价简化版）
// ---------------------------------------------------------------------------

/// 8 方向 + 正面，名称与原版一致
pub const DIRECTIONS: [(&str, &str); 9] = [
    ("front", "正面"),
    ("right", "右"),
    ("down-right", "右下"),
    ("down", "下"),
    ("down-left", "左下"),
    ("left", "左"),
    ("up-left", "左上"),
    ("up", "上"),
    ("up-right", "右上"),
];

/// 按原版 directional 分支计算一个方向的法线颜色
pub fn directional_normal(dir: &str, tilt_deg: f64, gain: f64) -> [u8; 3] {
    let tilt = if dir == "front" {
        0.0
    } else {
        tilt_deg * std::f64::consts::PI / 180.0
    };
    let s = tilt.sin() * gain;
    let diagonal = dir.contains('-');
    let factor = if diagonal { std::f64::consts::SQRT_2 / 2.0 } else { 1.0 };
    let sum = [
        (if dir.contains("left") {
            -s
        } else if dir.contains("right") {
            s
        } else {
            0.0
        }) * factor,
        (if dir.contains("up") {
            s
        } else if dir.contains("down") {
            -s
        } else {
            0.0
        }) * factor,
        tilt.cos(),
    ];
    let len = hypot3(sum[0], sum[1], sum[2]);
    let len = if len == 0.0 { 1.0 } else { len };
    [
        js_round((sum[0] / len + 1.0) * 127.5).clamp(0, 255) as u8,
        js_round((sum[1] / len + 1.0) * 127.5).clamp(0, 255) as u8,
        js_round((sum[2] / len + 1.0) * 127.5).clamp(0, 255) as u8,
    ]
}

/// 把选区像素涂成指定法线
pub fn paint_normal(img: &mut Img, sel: &[bool], rgb: [u8; 3]) {
    img.data.par_chunks_mut(4).enumerate().for_each(|(p, d)| {
        if sel.get(p).copied().unwrap_or(false) {
            d[0] = rgb[0];
            d[1] = rgb[1];
            d[2] = rgb[2];
        }
    });
}

/// 把选区像素涂成指定遮罩亮度（relative=true 时做相对加减）
pub fn paint_mask(img: &mut Img, sel: &[bool], brightness: f64, relative: bool) {
    let value = js_round(255.0 * brightness / 100.0).clamp(0, 255) as u8;
    img.data.par_chunks_mut(4).enumerate().for_each(|(p, d)| {
        if !sel.get(p).copied().unwrap_or(false) {
            return;
        }
        let v = if relative {
            let original = 0.2126 * d[0] as f64 + 0.7152 * d[1] as f64 + 0.0722 * d[2] as f64;
            js_round((original + 255.0 * brightness / 100.0).clamp(0.0, 255.0)) as u8
        } else {
            value
        };
        d[0] = v;
        d[1] = v;
        d[2] = v;
    });
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn solid(w: usize, h: usize, c: [u8; 4]) -> Img {
        let mut img = Img::new(w, h);
        for p in 0..w * h {
            img.data[p * 4..p * 4 + 4].copy_from_slice(&c);
        }
        img
    }

    #[test]
    fn srgb_roundtrip() {
        for v in [0u8, 1, 32, 128, 200, 254, 255] {
            let l = linear_from_u8(v);
            let back = srgb_from_linear(l);
            assert!(
                (back as i32 - v as i32).abs() <= 1,
                "v={v} back={back}"
            );
        }
    }

    #[test]
    fn flat_normal_lit() {
        // 平法线：最终色 = albedo_lin * (ambient + direct*light)
        let albedo = solid(64, 64, [200, 100, 50, 255]);
        let normal = solid(64, 64, [128, 128, 255, 255]);
        let cache = RenderCache::build(&albedo, Some(&normal));
        let s = LightSettings {
            lx: 32.0,
            ly: 32.0,
            power: 0.6,
            falloff: 30.0,
            height: 20.0,
            ..Default::default()
        };
        let out = render_view(&cache, &albedo, Some(&normal), None, &s, ViewMode::Final);
        assert_eq!(out[3], 255);
        let center = out[(32 * 64 + 32) * 4] as i32;
        let corner = out[0] as i32;
        assert!(center < 255, "中心不应过曝，实际 {center}");
        assert!(center > corner, "center={center} corner={corner}");
    }

    #[test]
    fn generate_normal_flat_region() {
        // 纯色实心方块 -> 内部法线应接近 (128,128,255)
        let albedo = solid(64, 64, [180, 180, 180, 255]);
        let mut o = GenOptions::default();
        o.kind = GenKind::Normal;
        o.preset = Preset::Object;
        let r = generate(&albedo, &o);
        let c = (32 * 64 + 32) * 4;
        let n = [r.img.data[c], r.img.data[c + 1], r.img.data[c + 2]];
        assert!(
            (n[0] as i32 - 128).abs() <= 2 && (n[1] as i32 - 128).abs() <= 2,
            "interior normal = {n:?}"
        );
        assert!(n[2] > 240, "z = {}", n[2]);
    }

    #[test]
    fn generate_mask_bright_gt_dark() {
        // 左亮右暗，遮罩也应左高右低
        let mut albedo = Img::new(32, 8);
        for y in 0..8 {
            for x in 0..32 {
                let v = if x < 16 { 230u8 } else { 40u8 };
                let i = (y * 32 + x) * 4;
                albedo.data[i] = v;
                albedo.data[i + 1] = v;
                albedo.data[i + 2] = v;
                albedo.data[i + 3] = 255;
            }
        }
        let mut o = GenOptions::default();
        o.kind = GenKind::Mask;
        let r = generate(&albedo, &o);
        let left = r.img.data[(4 * 32 + 4) * 4];
        let right = r.img.data[(4 * 32 + 20) * 4];
        assert!(left > right, "left={left} right={right}");
    }

    #[test]
    fn transparent_stays_zero() {
        let albedo = solid(4, 4, [0, 0, 0, 0]);
        let cache = RenderCache::build(&albedo, None);
        let out = render_view(
            &cache,
            &albedo,
            None,
            None,
            &LightSettings::default(),
            ViewMode::Final,
        );
        assert!(out.iter().all(|&b| b == 0));
    }

    #[test]
    fn directional_normal_values() {
        let front = directional_normal("front", 45.0, 1.0);
        assert_eq!(front, [128, 128, 255]);
        let right = directional_normal("right", 45.0, 1.0);
        assert!(right[0] > 128, "右向 x 应大于 128，实际 {}", right[0]);
        assert_eq!(right[1], 128);
        let up = directional_normal("up", 45.0, 1.0);
        assert!(up[1] > 128, "上向 y 应大于 128，实际 {}", up[1]);
        // 左上属于对角方向，x 负 y 正
        let ul = directional_normal("up-left", 45.0, 1.0);
        assert!(ul[0] < 128 && ul[1] > 128);
    }
}
