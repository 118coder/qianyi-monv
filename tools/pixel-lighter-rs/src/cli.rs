//! 命令行批量模式

use pixel_lighter::algorithm::*;
use pixel_lighter::io::{load_png, save_png};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Instant;

struct Cfg {
    input: Option<PathBuf>,
    input_dir: Option<PathBuf>,
    out: Option<PathBuf>,
    normal: Option<PathBuf>,
    mask: Option<PathBuf>,
    gen_normal: GenOptions,
    gen_mask: GenOptions,
    no_normal: bool,
    no_mask: bool,
    light: LightSettings,
    bench: u32,
}

impl Default for Cfg {
    fn default() -> Self {
        Self {
            input: None,
            input_dir: None,
            out: None,
            normal: None,
            mask: None,
            gen_normal: GenOptions {
                kind: GenKind::Normal,
                ..Default::default()
            },
            gen_mask: GenOptions {
                kind: GenKind::Mask,
                ..Default::default()
            },
            no_normal: false,
            no_mask: false,
            light: LightSettings::default(),
            bench: 0,
        }
    }
}

const HELP: &str = r#"像素打光器 · Rust 高性能版  —  命令行模式

用法:
  pixel-lighter.exe                        打开图形界面
  pixel-lighter.exe --input 图.png          处理单张
  pixel-lighter.exe --input-dir 目录        批量处理目录内所有 png

选项:
  --input <png>            输入底图
  --input-dir <目录>       批量模式
  --out <目录>             输出目录（默认与输入同目录）
  --normal <png>           使用已有法线图，而不是自动生成
  --mask <png>             使用已有遮罩，而不是自动生成
  --no-normal              不生成法线图
  --no-mask                不生成遮罩
  --preset <名称>          architecture | object | terrain | character（默认 object）
  --strength <0-200>       生成强度（默认按预设）
  --normal-strength <0-300> 法线强度
  --edge-width <0-6>       模糊边宽
  --facets <0-100>         切面数量
  --floor <0-255>          遮罩下限
  --ceiling <0-255>        遮罩上限
  --cavity <0-100>         凹槽压暗
  --no-merge               关闭描边合并
  --hide-bg                把背景色当作透明
  --lx <数值> --ly <数值>   光源位置（默认图中心）
  --height <5-200>         光源高度（默认 25）
  --falloff <10-200>       衰减半径（默认 70）
  --power <0-25>           亮度（默认 2.5）
  --ambient <0-100>        环境光百分比（默认 15）
  --mask-mix <0-100>       遮罩强度百分比（默认 100）
  --light <RRGGBB>         光色（默认 ffffff）
  --bg <RRGGBB>            背景色（默认自动检测）
  --bench <次数>           重复渲染测速
  --help                   显示本帮助

输出:
  <原名>-最终合成.png / <原名>-法线图.png / <原名>-光照遮罩.png
"#;

pub fn run(args: &[String]) -> i32 {
    let mut lines: Vec<String> = Vec::new();
    let mut cfg = Cfg::default();
    let mut i = 0usize;
    let mut err: Option<String> = None;

    macro_rules! next {
        () => {{
            i += 1;
            match args.get(i) {
                Some(v) => v.clone(),
                None => {
                    err = Some(format!("参数 {} 缺少取值", args[i - 1]));
                    String::new()
                }
            }
        }};
    }
    macro_rules! num {
        () => {{
            let v = next!();
            match v.parse::<f64>() {
                Ok(n) => n,
                Err(_) => {
                    err = Some(format!("参数取值不是数字: {v}"));
                    0.0
                }
            }
        }};
    }

    while i < args.len() {
        let a = args[i].to_lowercase();
        match a.as_str() {
            "--help" | "-h" | "/?" => {
                emit(&mut lines, HELP.to_string());
                flush(lines, None);
                return 0;
            }
            "--input" | "-i" => cfg.input = Some(PathBuf::from(next!())),
            "--input-dir" | "-d" => cfg.input_dir = Some(PathBuf::from(next!())),
            "--out" | "-o" => cfg.out = Some(PathBuf::from(next!())),
            "--normal" => cfg.normal = Some(PathBuf::from(next!())),
            "--mask" => cfg.mask = Some(PathBuf::from(next!())),
            "--no-normal" => cfg.no_normal = true,
            "--no-mask" => cfg.no_mask = true,
            "--preset" => {
                let v = next!().to_lowercase();
                let p = match v.as_str() {
                    "architecture" | "建筑" => Preset::Architecture,
                    "object" | "物体" => Preset::Object,
                    "terrain" | "地形" => Preset::Terrain,
                    "character" | "角色" => Preset::Character,
                    _ => {
                        err = Some(format!("未知预设: {v}"));
                        Preset::Object
                    }
                };
                let (s, f, fl, ce, ca) = p.defaults();
                cfg.gen_normal.preset = p;
                cfg.gen_normal.strength = s;
                cfg.gen_normal.facets = f;
                cfg.gen_normal.floor = fl;
                cfg.gen_normal.ceiling = ce;
                cfg.gen_normal.cavity = ca;
                cfg.gen_normal.edge_width = p.default_edge_width();
            }
            "--strength" => {
                let v = num!();
                cfg.gen_normal.strength = v;
                cfg.gen_mask.strength = v;
            }
            "--normal-strength" => cfg.gen_normal.normal_strength = num!(),
            "--edge-width" => cfg.gen_normal.edge_width = num!(),
            "--facets" => cfg.gen_normal.facets = num!(),
            "--floor" => {
                let v = num!();
                cfg.gen_normal.floor = v;
                cfg.gen_mask.floor = v;
            }
            "--ceiling" => {
                let v = num!();
                cfg.gen_normal.ceiling = v;
                cfg.gen_mask.ceiling = v;
            }
            "--cavity" => {
                let v = num!();
                cfg.gen_normal.cavity = v;
                cfg.gen_mask.cavity = v;
            }
            "--no-merge" => {
                cfg.gen_normal.merge = false;
                cfg.gen_mask.merge = false;
            }
            "--hide-bg" => {
                cfg.gen_normal.hide = true;
                cfg.gen_mask.hide = true;
                cfg.light.hide_bg = true;
            }
            "--lx" => cfg.light.lx = num!(),
            "--ly" => cfg.light.ly = num!(),
            "--height" => cfg.light.height = num!(),
            "--falloff" => cfg.light.falloff = num!(),
            "--power" => cfg.light.power = num!(),
            "--ambient" => cfg.light.ambient = num!() / 100.0,
            "--mask-mix" => cfg.light.mask_mix = num!() / 100.0,
            "--light" => {
                let v = next!();
                match parse_hex(&v) {
                    Some(c) => cfg.light.light = c,
                    None => err = Some(format!("光色格式不对: {v}")),
                }
            }
            "--bg" => {
                let v = next!();
                match parse_hex(&v) {
                    Some(c) => {
                        cfg.light.bg = c;
                        cfg.gen_normal.bg = c;
                        cfg.gen_mask.bg = c;
                    }
                    None => err = Some(format!("背景色格式不对: {v}")),
                }
            }
            "--bench" => cfg.bench = num!().max(1.0) as u32,
            other => err = Some(format!("未知参数: {other}")),
        }
        if err.is_some() {
            break;
        }
        i += 1;
    }

    if let Some(e) = err {
        emit(&mut lines, format!("错误：{e}\n\n{HELP}"));
        flush(lines, None);
        return 2;
    }

    let files: Vec<PathBuf> = if let Some(d) = &cfg.input_dir {
        let mut v: Vec<PathBuf> = Vec::new();
        if let Ok(rd) = std::fs::read_dir(d) {
            for e in rd.flatten() {
                let p = e.path();
                if !p
                    .extension()
                    .map(|x| x.eq_ignore_ascii_case("png"))
                    .unwrap_or(false)
                {
                    continue;
                }
                let stem = p
                    .file_stem()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_default();
                if stem.ends_with("-最终合成")
                    || stem.ends_with("-法线图")
                    || stem.ends_with("-光照遮罩")
                {
                    continue;
                }
                v.push(p);
            }
        }
        v.sort();
        v
    } else if let Some(p) = &cfg.input {
        vec![p.clone()]
    } else {
        emit(&mut lines, format!("缺少 --input 或 --input-dir\n\n{HELP}"));
        flush(lines, None);
        return 2;
    };

    if files.is_empty() {
        emit(&mut lines, "没有找到可处理的 png。".into());
        flush(lines, None);
        return 1;
    }

    let mut failed = 0;
    for f in &files {
        match process(f, &cfg, &mut lines) {
            Ok(_) => {}
            Err(e) => {
                failed += 1;
                emit(&mut lines, format!("[失败] {}：{e}", f.display()));
            }
        }
    }
    emit(
        &mut lines,
        format!("共 {} 个文件，成功 {}，失败 {}", files.len(), files.len() - failed, failed),
    );
    flush(lines, cfg.out.as_deref());
    if failed > 0 {
        1
    } else {
        0
    }
}

fn process(path: &Path, cfg: &Cfg, lines: &mut Vec<String>) -> Result<(), String> {
    let t_all = Instant::now();
    let albedo = load_png(path)?;
    let (w, h) = (albedo.w, albedo.h);
    emit(lines, format!("处理 {} ({}×{})", path.display(), w, h));

    let mut light = cfg.light.clone();
    if light.lx == 0.0 && light.ly == 0.0 {
        light.lx = w as f64 / 2.0;
        light.ly = h as f64 / 2.0;
    }
    if light.bg == [43, 124, 167] {
        if let Some(bg) = albedo.detect_bg() {
            light.bg = bg;
        }
    }

    // 法线
    let normal = if cfg.no_normal {
        None
    } else if let Some(p) = &cfg.normal {
        Some(load_png(p)?)
    } else {
        let t = Instant::now();
        let r = generate(&albedo, &cfg.gen_normal);
        emit(
            lines,
            format!("  法线图生成 {:.1} ms", t.elapsed().as_secs_f64() * 1000.0),
        );
        Some(r.img)
    };

    // 遮罩
    let mask = if cfg.no_mask {
        None
    } else if let Some(p) = &cfg.mask {
        Some(load_png(p)?)
    } else {
        let t = Instant::now();
        let r = generate(&albedo, &cfg.gen_mask);
        emit(
            lines,
            format!("  遮罩生成 {:.1} ms", t.elapsed().as_secs_f64() * 1000.0),
        );
        Some(r.img)
    };

    let cache = RenderCache::build(&albedo, normal.as_ref());

    let t = Instant::now();
    let final_img = render_view(
        &cache,
        &albedo,
        normal.as_ref(),
        mask.as_ref(),
        &light,
        ViewMode::Final,
    );
    let render_ms = t.elapsed().as_secs_f64() * 1000.0;
    emit(
        lines,
        format!(
            "  打光渲染 {:.2} ms（{:.1} 万像素）",
            render_ms,
            (w * h) as f64 / 10000.0
        ),
    );

    if cfg.bench > 0 {
        let n = cfg.bench as usize;
        let t = Instant::now();
        for _ in 0..n {
            let _ = render_view(
                &cache,
                &albedo,
                normal.as_ref(),
                mask.as_ref(),
                &light,
                ViewMode::Final,
            );
        }
        let total = t.elapsed().as_secs_f64();
        let per = total / n as f64 * 1000.0;
        emit(
            lines,
            format!(
                "  压测 {} 次：单次 {:.2} ms，合计 {:.2} s，折算 {:.0} 万像素/秒",
                n,
                per,
                total,
                (w * h) as f64 * n as f64 / total / 10000.0
            ),
        );
    }

    let out_dir = cfg
        .out
        .clone()
        .or_else(|| path.parent().map(|p| p.to_path_buf()))
        .unwrap_or_else(|| PathBuf::from("."));
    std::fs::create_dir_all(&out_dir).map_err(|e| e.to_string())?;
    let stem = path
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "texture".into());

    save_png(w, h, &final_img, &out_dir.join(format!("{stem}-最终合成.png")))?;
    if let Some(n) = &normal {
        save_png(n.w, n.h, &n.data, &out_dir.join(format!("{stem}-法线图.png")))?;
    }
    if let Some(m) = &mask {
        save_png(m.w, m.h, &m.data, &out_dir.join(format!("{stem}-光照遮罩.png")))?;
    }
    emit(
        lines,
        format!(
            "  已输出到 {}，总耗时 {:.1} ms",
            out_dir.display(),
            t_all.elapsed().as_secs_f64() * 1000.0
        ),
    );
    Ok(())
}

fn parse_hex(s: &str) -> Option<[u8; 3]> {
    let s = s.trim_start_matches('#');
    if s.len() != 6 {
        return None;
    }
    let r = u8::from_str_radix(&s[0..2], 16).ok()?;
    let g = u8::from_str_radix(&s[2..4], 16).ok()?;
    let b = u8::from_str_radix(&s[4..6], 16).ok()?;
    Some([r, g, b])
}

fn emit(lines: &mut Vec<String>, s: String) {
    let _ = writeln!(std::io::stdout(), "{s}");
    lines.push(s);
}

fn flush(lines: Vec<String>, out: Option<&Path>) {
    let mut targets: Vec<PathBuf> = vec![PathBuf::from("pixel-lighter-cli.log")];
    if let Some(d) = out {
        targets.push(d.join("pixel-lighter-cli.log"));
    }
    for t in targets {
        if let Ok(mut f) = std::fs::File::create(&t) {
            for l in &lines {
                let _ = writeln!(f, "{l}");
            }
        }
    }
    let _ = std::io::stdout().flush();
}
