//! 黄金对照测试：与从原版 JavaScript 抽取出的算法输出逐字节比对。
//! 参考数据由 verify/gen_ref.js 生成。

use pixel_lighter::algorithm::*;
use std::fs;
use std::path::PathBuf;

const W: usize = 72;
const H: usize = 56;
const BG: [u8; 3] = [43, 124, 167];

fn ref_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("verify/ref")
}

fn load_raw(name: &str) -> Vec<u8> {
    let p = ref_dir().join(format!("{name}.raw"));
    fs::read(&p).unwrap_or_else(|e| panic!("读取 {} 失败: {e}", p.display()))
}

fn load_albedo() -> Img {
    Img::from_rgba(W, H, load_raw("input_72x56"))
}

struct Report {
    fails: Vec<String>,
    passed: usize,
}

impl Report {
    fn check(&mut self, name: &str, got: &[u8], expect: &[u8]) {
        assert_eq!(got.len(), expect.len(), "{name}: 长度不一致");
        let mut diff_bytes = 0usize;
        let mut maxd = 0i32;
        let mut pixels = std::collections::BTreeSet::new();
        let mut samples = Vec::new();
        for (i, (a, b)) in got.iter().zip(expect.iter()).enumerate() {
            let d = (*a as i32 - *b as i32).abs();
            if d != 0 {
                diff_bytes += 1;
                maxd = maxd.max(d);
                let px = i / 4;
                pixels.insert(px);
                if samples.len() < 8 {
                    samples.push(format!(
                        "px({},{})c{} R={} J={}",
                        px % W,
                        px / W,
                        i % 4,
                        a,
                        b
                    ));
                }
            }
        }
        if diff_bytes == 0 {
            self.passed += 1;
            println!("  [通过] {name}");
        } else {
            println!(
                "  [失败] {name}: {} 字节 / {} 像素不一致，最大差 {}",
                diff_bytes,
                pixels.len(),
                maxd
            );
            println!("         {}", samples.join("  "));
            self.fails.push(name.to_string());
        }
    }
}

fn base(kind: GenKind, preset: Preset) -> GenOptions {
    let (strength, facets, floor, ceiling, cavity) = preset.defaults();
    GenOptions {
        kind,
        preset,
        strength,
        normal_strength: 100.0,
        edge_width: preset.default_edge_width(),
        facets,
        floor,
        ceiling,
        cavity,
        merge: true,
        bg: BG,
        hide: false,
    }
}

#[test]
fn golden_all() {
    let a = load_albedo();
    let mut r = Report {
        fails: Vec::new(),
        passed: 0,
    };

    // --- 法线图 ---
    let normals: Vec<(&str, GenOptions)> = vec![
        ("normal_object", base(GenKind::Normal, Preset::Object)),
        (
            "normal_architecture",
            GenOptions {
                edge_width: 1.0,
                facets: 20.0,
                ..base(GenKind::Normal, Preset::Architecture)
            },
        ),
        (
            "normal_terrain",
            GenOptions {
                strength: 110.0,
                edge_width: 3.0,
                facets: 50.0,
                ..base(GenKind::Normal, Preset::Terrain)
            },
        ),
        (
            "normal_character",
            GenOptions {
                strength: 65.0,
                edge_width: 2.0,
                facets: 15.0,
                ..base(GenKind::Normal, Preset::Character)
            },
        ),
        (
            "normal_nomerge",
            GenOptions {
                merge: false,
                ..base(GenKind::Normal, Preset::Object)
            },
        ),
        (
            "normal_nofacets",
            GenOptions {
                facets: 0.0,
                ..base(GenKind::Normal, Preset::Object)
            },
        ),
        (
            "normal_gain150",
            GenOptions {
                normal_strength: 150.0,
                ..base(GenKind::Normal, Preset::Object)
            },
        ),
        (
            "normal_hidebg",
            GenOptions {
                hide: true,
                edge_width: 2.0,
                ..base(GenKind::Normal, Preset::Object)
            },
        ),
        (
            "bis_plain",
            GenOptions {
                edge_width: 0.0,
                merge: false,
                facets: 0.0,
                ..base(GenKind::Normal, Preset::Object)
            },
        ),
        (
            "bis_blur",
            GenOptions {
                edge_width: 3.0,
                merge: false,
                facets: 0.0,
                ..base(GenKind::Normal, Preset::Object)
            },
        ),
        (
            "bis_blur1",
            GenOptions {
                edge_width: 1.0,
                merge: false,
                facets: 0.0,
                ..base(GenKind::Normal, Preset::Object)
            },
        ),
        (
            "bis_merge",
            GenOptions {
                edge_width: 3.0,
                merge: true,
                facets: 0.0,
                ..base(GenKind::Normal, Preset::Object)
            },
        ),
        (
            "bis_facets",
            GenOptions {
                edge_width: 3.0,
                merge: false,
                facets: 35.0,
                ..base(GenKind::Normal, Preset::Object)
            },
        ),
    ];
    for (name, o) in &normals {
        let res = generate(&a, o);
        r.check(name, &res.img.data, &load_raw(name));
    }

    // --- 遮罩 ---
    let masks: Vec<(&str, GenOptions)> = vec![
        (
            "mask_object",
            GenOptions {
                kind: GenKind::Mask,
                strength: 100.0,
                floor: 20.0,
                ceiling: 255.0,
                cavity: 35.0,
                ..base(GenKind::Mask, Preset::Object)
            },
        ),
        (
            "mask_soft",
            GenOptions {
                kind: GenKind::Mask,
                strength: 60.0,
                floor: 45.0,
                ceiling: 220.0,
                cavity: 0.0,
                merge: false,
                ..base(GenKind::Mask, Preset::Object)
            },
        ),
    ];
    for (name, o) in &masks {
        let res = generate(&a, o);
        r.check(name, &res.img.data, &load_raw(name));
    }

    // --- 光照与视图 ---
    let normal_img = generate(&a, &base(GenKind::Normal, Preset::Object)).img;
    let mask_img = generate(&a, &base(GenKind::Mask, Preset::Object)).img;
    let cache_nm = RenderCache::build(&a, Some(&normal_img));
    let cache_flat = RenderCache::build(&a, None);

    let cases: Vec<(&str, LightSettings, bool, bool, ViewMode)> = vec![
        (
            "lit_center",
            LightSettings {
                lx: 36.0,
                ly: 28.0,
                height: 25.0,
                falloff: 70.0,
                power: 2.5,
                ambient: 0.15,
                mask_mix: 1.0,
                light: [255, 255, 255],
                hide_bg: false,
                bg: BG,
            },
            true,
            true,
            ViewMode::Final,
        ),
        (
            "lit_topleft_warm",
            LightSettings {
                lx: 5.0,
                ly: 3.0,
                height: 120.0,
                falloff: 30.0,
                power: 6.5,
                ambient: 0.04,
                mask_mix: 0.6,
                light: [255, 196, 120],
                hide_bg: false,
                bg: BG,
            },
            true,
            true,
            ViewMode::Final,
        ),
        (
            "lit_nomask_blue",
            LightSettings {
                lx: 80.0,
                ly: 70.0,
                height: 200.0,
                falloff: 200.0,
                power: 1.2,
                ambient: 0.4,
                mask_mix: 0.0,
                light: [90, 140, 255],
                hide_bg: true,
                bg: BG,
            },
            true,
            false,
            ViewMode::Final,
        ),
        (
            "lit_flathide",
            LightSettings {
                lx: 10.0,
                ly: 50.0,
                height: 5.0,
                falloff: 10.0,
                power: 25.0,
                ambient: 0.0,
                mask_mix: 1.0,
                light: [255, 255, 255],
                hide_bg: true,
                bg: BG,
            },
            false,
            false,
            ViewMode::Final,
        ),
        (
            "view_albedo",
            LightSettings {
                lx: 36.0,
                ly: 28.0,
                ..Default::default()
            },
            true,
            true,
            ViewMode::Albedo,
        ),
        (
            "view_normal",
            LightSettings {
                lx: 36.0,
                ly: 28.0,
                ..Default::default()
            },
            true,
            true,
            ViewMode::Normal,
        ),
        (
            "view_mask",
            LightSettings {
                lx: 36.0,
                ly: 28.0,
                ..Default::default()
            },
            true,
            true,
            ViewMode::Mask,
        ),
    ];

    for (name, s, with_n, with_m, view) in &cases {
        let cache = if *with_n { &cache_nm } else { &cache_flat };
        let n = if *with_n { Some(&normal_img) } else { None };
        let m = if *with_m { Some(&mask_img) } else { None };
        let got = render_view(cache, &a, n, m, s, *view);
        r.check(name, &got, &load_raw(name));
    }

    println!("\n通过 {} 项，失败 {} 项", r.passed, r.fails.len());
    assert!(
        r.fails.is_empty(),
        "以下用例与原版不一致: {:?}",
        r.fails
    );
}
