//! 全中文图形界面

use eframe::egui;
use egui::{Align2, Color32, FontId, Pos2, Rect, Sense, Stroke, TextureId, Vec2};
use pixel_lighter::algorithm::*;
use pixel_lighter::io::{load_png, save_png};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

// ---------------------------------------------------------------- 配色
const BG_DARK: Color32 = Color32::from_rgb(16, 18, 22);
const PANEL_BG: Color32 = Color32::from_rgb(25, 28, 34);
const CARD_BG: Color32 = Color32::from_rgb(34, 38, 45);
const CARD_BG2: Color32 = Color32::from_rgb(43, 48, 57);
const BORDER: Color32 = Color32::from_rgb(55, 61, 72);
const TEXT: Color32 = Color32::from_rgb(228, 232, 240);
const TEXT_DIM: Color32 = Color32::from_rgb(148, 157, 172);
const ACCENT: Color32 = Color32::from_rgb(255, 190, 80);
const OK: Color32 = Color32::from_rgb(120, 205, 140);

/// 素材槽位
#[derive(Clone, Copy, PartialEq, Eq)]
enum Slot {
    Albedo,
    Normal,
    Mask,
}

impl Slot {
    fn index(self) -> usize {
        match self {
            Slot::Albedo => 0,
            Slot::Normal => 1,
            Slot::Mask => 2,
        }
    }
}

/// 撤销快照：只存法线图与遮罩。底图不走撤销——换底图是一个明确的主动作，
/// 而且换了底图旧的法线/遮罩尺寸对不上，回退反而会造成困惑。
#[derive(Clone)]
struct Snap {
    normal: Option<Img>,
    normal_name: String,
    mask: Option<Img>,
    mask_name: String,
    label: String,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ToastKind {
    Info,
    Ok,
    Err,
}

struct Toast {
    text: String,
    born: f64,
    kind: ToastKind,
}

pub struct App {
    albedo: Option<Img>,
    normal: Option<Img>,
    mask: Option<Img>,

    albedo_name: String,
    normal_name: String,
    mask_name: String,

    cache: Option<RenderCache>,
    tex: Option<egui::TextureHandle>,
    sel_tex: Option<egui::TextureHandle>,
    sel_dirty: bool,

    thumb_albedo: Option<egui::TextureHandle>,
    thumb_normal: Option<egui::TextureHandle>,
    thumb_mask: Option<egui::TextureHandle>,
    thumb_final: Option<egui::TextureHandle>,

    settings: LightSettings,
    gen_normal: GenOptions,
    gen_mask: GenOptions,
    view: ViewMode,

    zoom: f32,
    pan: Vec2,
    need_fit: bool,

    dirty: bool,
    auto_gen: bool,
    follow_mouse: bool,
    render_ms: f64,
    gen_ms: f64,

    brush_mode: bool,
    brush: f64,
    sel: Vec<bool>,
    sel_count: usize,
    last_paint: Option<(i32, i32)>,

    direction: usize,
    tilt: f64,
    mask_value: f64,
    mask_relative: bool,

    // 撤销 / 重做
    undo: Vec<Snap>,
    redo: Vec<Snap>,

    // 通知气泡
    pending: Vec<(String, ToastKind)>,
    toasts: Vec<Toast>,

    // 拖放
    slot_rects: [Option<Rect>; 3],
    dragging_files: bool,
    drop_hover: Option<Slot>,

    // 视图 / 交互
    show_left: bool,
    hover_px: Option<(i32, i32)>,
    last_export_dir: Option<PathBuf>,

    status: String,
    font_note: String,
}

impl App {
    pub fn new(cc: &eframe::CreationContext<'_>, initial: Option<PathBuf>) -> Self {
        let font_note = install_fonts(&cc.egui_ctx);
        cc.egui_ctx.set_theme(egui::ThemePreference::Dark);
        cc.egui_ctx.all_styles_mut(|style| {
            style.visuals.dark_mode = true;
            style.visuals.panel_fill = PANEL_BG;
            style.visuals.window_fill = PANEL_BG;
            style.visuals.extreme_bg_color = BG_DARK;
            style.visuals.override_text_color = Some(TEXT);
            style.visuals.widgets.inactive.bg_fill = Color32::from_rgb(48, 53, 62);
            style.visuals.widgets.inactive.weak_bg_fill = Color32::from_rgb(44, 49, 58);
            style.visuals.widgets.hovered.bg_fill = Color32::from_rgb(62, 69, 80);
            style.visuals.widgets.hovered.weak_bg_fill = Color32::from_rgb(58, 64, 75);
            style.visuals.widgets.active.bg_fill = Color32::from_rgb(76, 84, 97);
            style.visuals.widgets.inactive.corner_radius = 5.into();
            style.visuals.widgets.hovered.corner_radius = 5.into();
            style.visuals.widgets.active.corner_radius = 5.into();
            style.spacing.slider_width = 132.0;
            style.spacing.item_spacing = egui::vec2(8.0, 7.0);
            style.spacing.button_padding = egui::vec2(9.0, 4.0);
        });

        let preset = Preset::Object;
        let (s, f, fl, ce, ca) = preset.defaults();
        let gen_normal = GenOptions {
            kind: GenKind::Normal,
            preset,
            strength: s,
            normal_strength: 100.0,
            edge_width: preset.default_edge_width(),
            facets: f,
            floor: fl,
            ceiling: ce,
            cavity: ca,
            merge: true,
            bg: [43, 124, 167],
            hide: false,
        };
        let gen_mask = GenOptions {
            kind: GenKind::Mask,
            preset: Preset::Object,
            strength: 100.0,
            normal_strength: 100.0,
            edge_width: 3.0,
            facets: 0.0,
            floor: 20.0,
            ceiling: 255.0,
            cavity: 35.0,
            merge: true,
            bg: [43, 124, 167],
            hide: false,
        };

        let mut app = Self {
            albedo: None,
            normal: None,
            mask: None,
            albedo_name: String::new(),
            normal_name: String::new(),
            mask_name: String::new(),
            cache: None,
            tex: None,
            sel_tex: None,
            sel_dirty: false,
            thumb_albedo: None,
            thumb_normal: None,
            thumb_mask: None,
            thumb_final: None,
            settings: LightSettings::default(),
            gen_normal,
            gen_mask,
            view: ViewMode::Final,
            zoom: 1.0,
            pan: Vec2::ZERO,
            need_fit: true,
            dirty: false,
            auto_gen: true,
            follow_mouse: true,
            render_ms: 0.0,
            gen_ms: 0.0,
            brush_mode: false,
            brush: 3.0,
            sel: Vec::new(),
            sel_count: 0,
            last_paint: None,
            direction: 0,
            tilt: 45.0,
            mask_value: 100.0,
            mask_relative: false,
            undo: Vec::new(),
            redo: Vec::new(),
            pending: Vec::new(),
            toasts: Vec::new(),
            slot_rects: [None; 3],
            dragging_files: false,
            drop_hover: None,
            show_left: true,
            hover_px: None,
            last_export_dir: None,
            status: "① 打开一张像素画底图（PNG）  ② 左侧点「生成立体法线」  ③ 在画布上移动鼠标打光"
                .to_string(),
            font_note,
        };
        if let Some(p) = initial {
            app.load_albedo(&p);
        }
        app
    }

    // ------------------------------------------------------------- 文件读写

    fn load_albedo(&mut self, path: &Path) {
        match load_png(path) {
            Ok(img) => {
                self.albedo_name = file_label(path);
                self.albedo = Some(img);
                self.normal = None;
                self.normal_name.clear();
                self.thumb_normal = None;
                self.mask = None;
                self.mask_name.clear();
                self.thumb_mask = None;
                self.sel = Vec::new();
                self.sel_count = 0;
                self.sel_dirty = true;
                self.sel_tex = None;
                self.undo.clear();
                if let Some(a) = &self.albedo {
                    self.settings.lx = a.w as f64 / 2.0;
                    self.settings.ly = a.h as f64 / 2.0;
                    if let Some(bg) = a.detect_bg() {
                        self.settings.bg = bg;
                        self.gen_normal.bg = bg;
                        self.gen_mask.bg = bg;
                    }
                }
                self.need_fit = true;
                self.rebuild_cache();
                // 换底图后旧的法线/遮罩已被清空，撤销栈也就没有意义了
                self.undo.clear();
                self.redo.clear();
                // 同目录下若有配套贴图，自动带上
                let picked = self.try_load_siblings(path);
                self.status = if picked.is_empty() {
                    "底图已载入。下一步：左侧「生成立体法线」，然后在画布上拖动打光。".into()
                } else {
                    format!(
                        "底图已载入，并自动带上了 {}。",
                        picked.join("、")
                    )
                };
                let label = self.albedo_name.clone();
                if picked.is_empty() {
                    self.notify(format!("底图已换成 {label}"), ToastKind::Ok);
                } else {
                    self.notify(
                        format!("底图已换成 {label}，自动带上{}", picked.join("、")),
                        ToastKind::Ok,
                    );
                }
            }
            Err(e) => {
                self.status = format!("底图打开失败：{e}");
                self.notify(format!("打开失败：{e}"), ToastKind::Err);
            }
        }
    }

    /// 找同目录的 <名字>-法线图.png / <名字>-光照遮罩.png 等，尺寸对上就载入
    fn try_load_siblings(&mut self, path: &Path) -> Vec<String> {
        let mut picked = Vec::new();
        let Some(dir) = path.parent() else {
            return picked;
        };
        let stem = path
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default();
        let Some(a) = &self.albedo else {
            return picked;
        };
        let (aw, ah) = (a.w, a.h);

        let find = |names: Vec<String>| -> Option<Img> {
            for n in names {
                let p = dir.join(&n);
                if p.is_file() {
                    if let Ok(img) = load_png(&p) {
                        if img.w == aw && img.h == ah {
                            return Some(img);
                        }
                    }
                }
            }
            None
        };

        if let Some(img) = find(vec![
            format!("{stem}-法线图.png"),
            format!("{stem}-Normal.png"),
            format!("{stem}_normal.png"),
            format!("{stem}.normal.png"),
        ]) {
            self.normal = Some(img);
            self.normal_name = "同目录法线图".into();
            picked.push("法线图".to_string());
        }
        if let Some(img) = find(vec![
            format!("{stem}-光照遮罩.png"),
            format!("{stem}-Mask.png"),
            format!("{stem}_mask.png"),
            format!("{stem}.mask.png"),
        ]) {
            self.mask = Some(img);
            self.mask_name = "同目录遮罩".into();
            picked.push("光照遮罩".to_string());
        }
        if !picked.is_empty() {
            self.rebuild_cache();
        }
        picked
    }

    fn load_slot(&mut self, slot: Slot, path: &Path) {
        match load_png(path) {
            Ok(img) => {
                match slot {
                    Slot::Albedo => {
                        self.load_albedo(path);
                        return;
                    }
                    Slot::Normal => {
                        self.snapshot("导入法线图");
                        self.normal_name = file_label(path);
                        self.normal = Some(img);
                        self.thumb_normal = None;
                    }
                    Slot::Mask => {
                        self.snapshot("导入光照遮罩");
                        self.mask_name = file_label(path);
                        self.mask = Some(img);
                        self.thumb_mask = None;
                    }
                }
                self.rebuild_cache();
                self.status = format!("{} 已导入。", slot_title(slot));
                self.notify(
                    format!("{} 已导入：{}", slot_title(slot), file_label(path)),
                    ToastKind::Ok,
                );
            }
            Err(e) => {
                self.status = format!("{} 打开失败：{e}", slot_title(slot));
                self.notify(format!("打开失败：{e}"), ToastKind::Err);
            }
        }
    }

    fn rebuild_cache(&mut self) {
        if let Some(a) = &self.albedo {
            self.cache = Some(RenderCache::build(a, self.normal.as_ref()));
            self.dirty = true;
        } else {
            self.cache = None;
        }
    }

    fn rerender(&mut self, ctx: &egui::Context) {
        let t0 = Instant::now();
        let (w, h, data, final_data) = {
            let (Some(a), Some(cache)) = (self.albedo.as_ref(), self.cache.as_ref()) else {
                return;
            };
            let d = render_view(
                cache,
                a,
                self.normal.as_ref(),
                self.mask.as_ref(),
                &self.settings,
                self.view,
            );
            // 当前视图不是"最终合成"时，额外渲一张用于缩略图，保证预览始终是最终效果
            let f = if self.view == ViewMode::Final {
                None
            } else {
                Some(render_view(
                    cache,
                    a,
                    self.normal.as_ref(),
                    self.mask.as_ref(),
                    &self.settings,
                    ViewMode::Final,
                ))
            };
            (a.w, a.h, d, f)
        };
        self.render_ms = t0.elapsed().as_secs_f64() * 1000.0;

        let img = egui::ColorImage::from_rgba_unmultiplied([w, h], &data);
        match &mut self.tex {
            Some(t) => t.set(img, egui::TextureOptions::NEAREST),
            None => self.tex = Some(ctx.load_texture("canvas", img, egui::TextureOptions::NEAREST)),
        }
        self.dirty = false;

        // 四个模式的缩略图
        let final_ref: &[u8] = final_data.as_deref().unwrap_or(&data);
        let (tw, th, td) = make_thumb(w, h, final_ref, 160);
        put_thumb(&mut self.thumb_final, ctx, "thumb_final", tw, th, &td);
        if let Some(a) = &self.albedo {
            let (tw, th, td) = make_thumb(a.w, a.h, &a.data, 160);
            put_thumb(&mut self.thumb_albedo, ctx, "thumb_albedo", tw, th, &td);
        }
        match &self.normal {
            Some(n) => {
                let (tw, th, td) = make_thumb(n.w, n.h, &n.data, 160);
                put_thumb(&mut self.thumb_normal, ctx, "thumb_normal", tw, th, &td);
            }
            None => self.thumb_normal = None,
        }
        match &self.mask {
            Some(m) => {
                let (tw, th, td) = make_thumb(m.w, m.h, &m.data, 160);
                put_thumb(&mut self.thumb_mask, ctx, "thumb_mask", tw, th, &td);
            }
            None => self.thumb_mask = None,
        }
    }

    fn update_sel_texture(&mut self, ctx: &egui::Context) {
        let Some(a) = &self.albedo else { return };
        if !self.sel_dirty || self.sel.len() != a.w * a.h {
            return;
        }
        if self.sel_count == 0 {
            self.sel_tex = None;
            self.sel_dirty = false;
            return;
        }
        let mut data = vec![0u8; a.w * a.h * 4];
        for (i, on) in self.sel.iter().enumerate() {
            if *on {
                data[i * 4] = 90;
                data[i * 4 + 1] = 200;
                data[i * 4 + 2] = 255;
                data[i * 4 + 3] = 110;
            }
        }
        let img = egui::ColorImage::from_rgba_unmultiplied([a.w, a.h], &data);
        match &mut self.sel_tex {
            Some(t) => t.set(img, egui::TextureOptions::NEAREST),
            None => {
                self.sel_tex = Some(ctx.load_texture("sel", img, egui::TextureOptions::NEAREST))
            }
        }
        self.sel_dirty = false;
    }

    // ------------------------------------------------------------- 生成

    /// 记一次可撤销的改动（在真正修改法线/遮罩之前调用）
    fn snapshot(&mut self, label: &str) {
        self.undo.push(Snap {
            normal: self.normal.clone(),
            normal_name: self.normal_name.clone(),
            mask: self.mask.clone(),
            mask_name: self.mask_name.clone(),
            label: label.to_string(),
        });
        if self.undo.len() > 12 {
            self.undo.remove(0);
        }
        self.redo.clear();
    }

    fn do_undo(&mut self) {
        let Some(s) = self.undo.pop() else {
            self.notify("没有可撤销的操作了", ToastKind::Info);
            return;
        };
        self.redo.push(self.take_snap(&s.label));
        let label = s.label.clone();
        self.apply_snap(s);
        self.notify(format!("已撤销：{label}"), ToastKind::Info);
    }

    fn do_redo(&mut self) {
        let Some(s) = self.redo.pop() else {
            self.notify("没有可重做的操作了", ToastKind::Info);
            return;
        };
        self.undo.push(self.take_snap(&s.label));
        let label = s.label.clone();
        self.apply_snap(s);
        self.notify(format!("已重做：{label}"), ToastKind::Info);
    }

    fn take_snap(&self, label: &str) -> Snap {
        Snap {
            normal: self.normal.clone(),
            normal_name: self.normal_name.clone(),
            mask: self.mask.clone(),
            mask_name: self.mask_name.clone(),
            label: label.to_string(),
        }
    }

    fn apply_snap(&mut self, s: Snap) {
        self.normal = s.normal;
        self.normal_name = s.normal_name;
        self.mask = s.mask;
        self.mask_name = s.mask_name;
        if self.normal.is_none() {
            self.thumb_normal = None;
        }
        if self.mask.is_none() {
            self.thumb_mask = None;
        }
        self.rebuild_cache();
        self.dirty = true;
    }

    fn notify(&mut self, text: impl Into<String>, kind: ToastKind) {
        self.pending.push((text.into(), kind));
    }

    /// 把排队中的通知转成气泡（需要一个时间基准）
    fn flush_toasts(&mut self, now: f64) {
        if self.pending.is_empty() {
            return;
        }
        for (text, kind) in std::mem::take(&mut self.pending) {
            self.toasts.push(Toast {
                text,
                born: now,
                kind,
            });
        }
        if self.toasts.len() > 4 {
            let cut = self.toasts.len() - 4;
            self.toasts.drain(0..cut);
        }
    }

    /// 指针位置命中的素材卡（用于拖放定向替换）
    fn slot_at(&self, pos: Pos2) -> Option<Slot> {
        for (i, r) in self.slot_rects.iter().enumerate() {
            if let Some(r) = r {
                if r.contains(pos) {
                    return Some(match i {
                        0 => Slot::Albedo,
                        1 => Slot::Normal,
                        _ => Slot::Mask,
                    });
                }
            }
        }
        None
    }

    fn gen_normal_now(&mut self) {
        if self.albedo.is_none() {
            self.status = "还没有底图。".into();
            return;
        }
        let t0 = Instant::now();
        let r = {
            let a = self.albedo.as_ref().unwrap();
            generate(a, &self.gen_normal)
        };
        self.gen_ms = t0.elapsed().as_secs_f64() * 1000.0;
        self.snapshot("生成立体法线");
        self.normal = Some(r.img);
        self.normal_name = "自动生成".into();
        self.rebuild_cache();
        self.status = format!("法线图已生成（{:.1} ms）。", self.gen_ms);
        self.notify(
            format!("立体法线已生成 · {:.0} ms", self.gen_ms),
            ToastKind::Ok,
        );
    }

    fn gen_mask_now(&mut self) {
        if self.albedo.is_none() {
            self.status = "还没有底图。".into();
            return;
        }
        let t0 = Instant::now();
        let r = {
            let a = self.albedo.as_ref().unwrap();
            generate(a, &self.gen_mask)
        };
        self.gen_ms = t0.elapsed().as_secs_f64() * 1000.0;
        self.snapshot("生成光照遮罩");
        self.mask = Some(r.img);
        self.mask_name = "自动生成".into();
        self.dirty = true;
        self.status = format!("光照遮罩已生成（{:.1} ms）。", self.gen_ms);
        self.notify(
            format!("光照遮罩已生成 · {:.0} ms", self.gen_ms),
            ToastKind::Ok,
        );
    }

    fn apply_direction(&mut self) {
        if self.normal.is_none() {
            self.status = "先生成或导入法线图。".into();
            return;
        }
        if self.sel_count == 0 {
            self.status = "先在画布上刷出选区。".into();
            return;
        }
        self.snapshot("手动改朝向");
        let rgb = directional_normal(DIRECTIONS[self.direction].0, self.tilt, 1.0);
        let sel = std::mem::take(&mut self.sel);
        if let Some(normal) = &mut self.normal {
            paint_normal(normal, &sel, rgb);
        }
        self.sel = sel;
        self.rebuild_cache();
        self.status = format!(
            "已把 {} 个像素改成「{}」方向。",
            self.sel_count, DIRECTIONS[self.direction].1
        );
        self.notify(
            format!(
                "已把 {} 个像素改为「{}」",
                self.sel_count, DIRECTIONS[self.direction].1
            ),
            ToastKind::Ok,
        );
    }

    fn apply_mask_value(&mut self) {
        if self.mask.is_none() {
            self.status = "先生成或导入遮罩。".into();
            return;
        }
        if self.sel_count == 0 {
            self.status = "先在画布上刷出选区。".into();
            return;
        }
        self.snapshot("手动改遮罩亮度");
        let sel = std::mem::take(&mut self.sel);
        if let Some(mask) = &mut self.mask {
            paint_mask(mask, &sel, self.mask_value, self.mask_relative);
        }
        self.sel = sel;
        self.dirty = true;
        self.status = format!(
            "已把 {} 个像素的遮罩亮度改成 {}%。",
            self.sel_count, self.mask_value
        );
        self.notify(
            format!("已改 {} 个像素的遮罩亮度", self.sel_count),
            ToastKind::Ok,
        );
    }

    // ------------------------------------------------------------- 导出

    fn export_final(&mut self) {
        let (Some(a), Some(cache)) = (&self.albedo, &self.cache) else {
            self.status = "还没有底图。".into();
            return;
        };
        let data = render_view(
            cache,
            a,
            self.normal.as_ref(),
            self.mask.as_ref(),
            &self.settings,
            ViewMode::Final,
        );
        let (w, h) = (a.w, a.h);
        let suggested = format!("{}-最终合成.png", self.base_name());
        if let Some(path) = save_dialog(&suggested, self.last_export_dir.as_deref()) {
            match save_png(w, h, &data, &path) {
                Ok(_) => {
                    self.status = format!("已导出：{}", path.display());
                    self.remember_dir(&path);
                    self.notify(format!("已导出 {}", file_label(&path)), ToastKind::Ok);
                }
                Err(e) => {
                    self.status = format!("导出失败：{e}");
                    self.notify(format!("导出失败：{e}"), ToastKind::Err);
                }
            }
        }
    }

    fn remember_dir(&mut self, path: &Path) {
        if let Some(d) = path.parent() {
            self.last_export_dir = Some(d.to_path_buf());
        }
    }

    fn export_slot(&mut self, slot: Slot) {
        match slot {
            Slot::Albedo => {
                let Some(a) = &self.albedo else {
                    self.status = "还没有底图。".into();
                    return;
                };
                let (w, h, data) = (a.w, a.h, a.data.clone());
                let path = save_dialog(
                    &format!("{}-底图.png", self.base_name()),
                    self.last_export_dir.as_deref(),
                );
                if let Some(p) = path {
                    match save_png(w, h, &data, &p) {
                        Ok(_) => {
                            self.status = format!("已导出：{}", p.display());
                            self.remember_dir(&p);
                            self.notify(format!("已导出 {}", file_label(&p)), ToastKind::Ok);
                        }
                        Err(e) => {
                            self.status = format!("导出失败：{e}");
                            self.notify(format!("导出失败：{e}"), ToastKind::Err);
                        }
                    }
                }
            }
            Slot::Normal | Slot::Mask => {
                let (img, tag) = if slot == Slot::Normal {
                    (self.normal.as_ref(), "法线图")
                } else {
                    (self.mask.as_ref(), "光照遮罩")
                };
                let Some(img) = img else {
                    self.status = format!("还没有{}。", slot_title(slot));
                    return;
                };
                let (w, h, data) = (img.w, img.h, img.data.clone());
                let path = save_dialog(
                    &format!("{}-{}.png", self.base_name(), tag),
                    self.last_export_dir.as_deref(),
                );
                if let Some(p) = path {
                    match save_png(w, h, &data, &p) {
                        Ok(_) => {
                            self.status = format!("已导出：{}", p.display());
                            self.remember_dir(&p);
                            self.notify(format!("已导出 {}", file_label(&p)), ToastKind::Ok);
                        }
                        Err(e) => {
                            self.status = format!("导出失败：{e}");
                            self.notify(format!("导出失败：{e}"), ToastKind::Err);
                        }
                    }
                }
            }
        }
    }

    fn export_all(&mut self) {
        let Some(a) = &self.albedo else {
            self.status = "还没有底图。".into();
            return;
        };
        let Some(cache) = &self.cache else { return };
        let mut dlg = rfd::FileDialog::new().set_title("选择导出文件夹");
        if let Some(d) = &self.last_export_dir {
            dlg = dlg.set_directory(d);
        }
        let Some(dir) = dlg.pick_folder() else {
            return;
        };
        let data = render_view(
            cache,
            a,
            self.normal.as_ref(),
            self.mask.as_ref(),
            &self.settings,
            ViewMode::Final,
        );
        let (w, h) = (a.w, a.h);
        let base = self.base_name();
        let mut count = 0;
        if save_png(w, h, &data, &dir.join(format!("{base}-最终合成.png"))).is_ok() {
            count += 1;
        }
        if let Some(n) = &self.normal {
            if save_png(n.w, n.h, &n.data, &dir.join(format!("{base}-法线图.png"))).is_ok() {
                count += 1;
            }
        }
        if let Some(m) = &self.mask {
            if save_png(m.w, m.h, &m.data, &dir.join(format!("{base}-光照遮罩.png"))).is_ok() {
                count += 1;
            }
        }
        self.status = format!("已导出 {count} 张到 {}", dir.display());
        self.last_export_dir = Some(dir.clone());
        self.notify(format!("已导出 {count} 张到 {}", file_label(&dir)), ToastKind::Ok);
    }

    fn base_name(&self) -> String {
        stem_of(&self.albedo_name)
    }

    // ------------------------------------------------------------- 画布

    fn image_rect(&self, canvas: Rect, w: f32, h: f32) -> Rect {
        let size = egui::vec2(w * self.zoom, h * self.zoom);
        Rect::from_center_size(canvas.center() + self.pan, size)
    }

    fn fit(&mut self, canvas: Rect, w: f32, h: f32) {
        let z = ((canvas.width() - 48.0) / w).min((canvas.height() - 48.0) / h);
        self.zoom = z.clamp(0.05, 64.0);
        self.pan = Vec2::ZERO;
        self.need_fit = false;
    }

    fn paint_selection(&mut self, a: (i32, i32), b: (i32, i32)) {
        let Some(img) = &self.albedo else { return };
        let (w, h) = (img.w as i32, img.h as i32);
        let r = self.brush.max(1.0) as i32;
        let steps = (b.0 - a.0).abs().max((b.1 - a.1).abs()).max(1);
        for s in 0..=steps {
            let t = s as f32 / steps as f32;
            let cx = a.0 as f32 + (b.0 - a.0) as f32 * t;
            let cy = a.1 as f32 + (b.1 - a.1) as f32 * t;
            for dy in -r..=r {
                for dx in -r..=r {
                    if dx * dx + dy * dy > r * r {
                        continue;
                    }
                    let x = cx.round() as i32 + dx;
                    let y = cy.round() as i32 + dy;
                    if x < 0 || y < 0 || x >= w || y >= h {
                        continue;
                    }
                    let i = (y as usize) * img.w + x as usize;
                    if !self.sel[i] {
                        self.sel[i] = true;
                        self.sel_count += 1;
                    }
                }
            }
        }
        self.sel_dirty = true;
    }

    fn ensure_sel(&mut self) {
        let Some(a) = &self.albedo else { return };
        if self.sel.len() != a.w * a.h {
            self.sel = vec![false; a.w * a.h];
            self.sel_count = 0;
            self.sel_dirty = true;
        }
    }

    fn size_text(&self, slot: Slot) -> String {
        let t = match slot {
            Slot::Albedo => self.albedo.as_ref(),
            Slot::Normal => self.normal.as_ref(),
            Slot::Mask => self.mask.as_ref(),
        };
        t.map(|i| format!("{}×{}", i.w, i.h)).unwrap_or_default()
    }

    fn name_of(&self, slot: Slot) -> String {
        match slot {
            Slot::Albedo => self.albedo_name.clone(),
            Slot::Normal => self.normal_name.clone(),
            Slot::Mask => self.mask_name.clone(),
        }
    }

    fn has(&self, slot: Slot) -> bool {
        match slot {
            Slot::Albedo => self.albedo.is_some(),
            Slot::Normal => self.normal.is_some(),
            Slot::Mask => self.mask.is_some(),
        }
    }

    fn thumb_id(&self, slot: Slot) -> Option<TextureId> {
        match slot {
            Slot::Albedo => self.thumb_albedo.as_ref().map(|t| t.id()),
            Slot::Normal => self.thumb_normal.as_ref().map(|t| t.id()),
            Slot::Mask => self.thumb_mask.as_ref().map(|t| t.id()),
        }
    }

    fn aspect(&self, slot: Slot) -> f32 {
        let t = match slot {
            Slot::Albedo => self.albedo.as_ref(),
            Slot::Normal => self.normal.as_ref(),
            Slot::Mask => self.mask.as_ref(),
        };
        t.map(|i| i.w as f32 / i.h.max(1) as f32).unwrap_or(1.0)
    }
}

// ================================================================ UI

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();

        // 是否正有文件悬在窗口上（用于整窗高亮提示）
        self.dragging_files = ctx.input(|i| !i.raw.hovered_files.is_empty());
        let drop_pos = ctx.input(|i| i.pointer.hover_pos().or_else(|| i.pointer.latest_pos()));
        self.drop_hover = if self.dragging_files {
            drop_pos.and_then(|p| self.slot_at(p))
        } else {
            None
        };

        // 拖拽文件到窗口
        let dropped: Vec<PathBuf> = ctx.input(|i| {
            i.raw
                .dropped_files
                .iter()
                .map(|f| f.path().to_path_buf())
                .collect()
        });
        if !dropped.is_empty() {
            // 指针压在哪个素材卡上就替代谁；否则按文件名判断，兜底永远是「换底图」
            let forced = drop_pos.and_then(|p| self.slot_at(p));
            for p in dropped {
                self.handle_drop(&p, forced);
            }
        }

        self.shortcuts(&ctx);

        self.top_bar(ui);
        self.status_bar(ui);
        self.view_bar(ui);
        if self.show_left {
            self.left_panel(ui);
        }
        self.central(ui);

        if self.dirty {
            self.rerender(&ctx);
        }
        self.update_sel_texture(&ctx);
        self.draw_drop_hint(&ctx);

        let now = ctx.input(|i| i.time);
        self.flush_toasts(now);
        self.draw_toasts(&ctx, now);
    }
}

impl App {
    /// 拖入一个文件：决定目标槽位并载入
    fn handle_drop(&mut self, path: &Path, forced: Option<Slot>) {
        let name = path
            .file_name()
            .map(|s| s.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        let slot = match forced {
            Some(s) => s,
            None => {
                if name.contains("normal") || name.contains("法线") {
                    Slot::Normal
                } else if name.contains("mask")
                    || name.contains("遮罩")
                    || name.contains("光照")
                    || name.contains("light")
                {
                    Slot::Mask
                } else {
                    // 关键行为：不管画布上有没有图，普通图片一律替换底图
                    Slot::Albedo
                }
            }
        };
        match slot {
            Slot::Albedo => self.load_albedo(path),
            _ => self.load_slot(slot, path),
        }
    }

    fn shortcuts(&mut self, ctx: &egui::Context) {
        let (
            open,
            save_final,
            save_all,
            undo,
            redo,
            fit,
            one_to_one,
            cycle_view,
            brush_dn,
            brush_up,
            esc,
            tab,
        ) = ctx.input_mut(|i| {
            let ctrl = i.modifiers.command;
            let shift = i.modifiers.shift;
            (
                ctrl && i.key_pressed(egui::Key::O),
                ctrl && !shift && i.key_pressed(egui::Key::S),
                ctrl && shift && i.key_pressed(egui::Key::S),
                ctrl && !shift && i.key_pressed(egui::Key::Z),
                ctrl && ((shift && i.key_pressed(egui::Key::Z)) || i.key_pressed(egui::Key::Y)),
                !ctrl && i.key_pressed(egui::Key::F),
                !ctrl && i.key_pressed(egui::Key::Num1),
                !ctrl && i.key_pressed(egui::Key::V),
                !ctrl && i.key_pressed(egui::Key::OpenBracket),
                !ctrl && i.key_pressed(egui::Key::CloseBracket),
                i.key_pressed(egui::Key::Escape),
                i.consume_key(egui::Modifiers::NONE, egui::Key::Tab),
            )
        });

        if tab {
            self.show_left = !self.show_left;
        }
        if open {
            if let Some(p) = open_dialog() {
                self.load_albedo(&p);
            }
        }
        if self.albedo.is_some() {
            if save_final {
                self.export_final();
            }
            if save_all {
                self.export_all();
            }
            if fit {
                self.need_fit = true;
            }
            if one_to_one {
                self.zoom = 1.0;
                self.pan = Vec2::ZERO;
            }
            if cycle_view {
                self.view = match self.view {
                    ViewMode::Final => ViewMode::Albedo,
                    ViewMode::Albedo => ViewMode::Normal,
                    ViewMode::Normal => ViewMode::Mask,
                    ViewMode::Mask => ViewMode::Final,
                };
                self.dirty = true;
            }
        }
        if undo {
            self.do_undo();
        }
        if redo {
            self.do_redo();
        }
        if brush_dn {
            self.brush = (self.brush - 1.0).max(1.0);
        }
        if brush_up {
            self.brush = (self.brush + 1.0).min(20.0);
        }
        if esc {
            self.brush_mode = false;
        }
    }

    /// 拖放时整窗高亮，告诉用户松手会发生什么
    fn draw_drop_hint(&self, ctx: &egui::Context) {
        if !self.dragging_files {
            return;
        }
        let screen = ctx.viewport_rect();
        let p = ctx.layer_painter(egui::LayerId::new(
            egui::Order::Foreground,
            egui::Id::unique(&"drophint"),
        ));
        p.rect_filled(screen, 0.0, Color32::from_rgba_unmultiplied(8, 10, 14, 185));

        let targeted = self.drop_hover.map(|s| slot_title(s));
        let (title, sub) = match targeted {
            Some(t) => (format!("松开鼠标 → 替换「{t}」"), "文件会覆盖这一张".to_string()),
            None => (
                "松开鼠标 → 替换底图".to_string(),
                "其它两张贴图会按新底图重新检测；也可拖到左侧素材卡上定向替换".to_string(),
            ),
        };

        let box_size = egui::vec2(560.0, 150.0);
        let area = Rect::from_center_size(screen.center(), box_size);
        p.rect_filled(area, 12.0, Color32::from_rgba_unmultiplied(26, 30, 38, 245));
        p.rect_stroke(
            area,
            12.0,
            Stroke::new(1.6, ACCENT),
            egui::StrokeKind::Inside,
        );
        p.text(
            area.center() - egui::vec2(0.0, 18.0),
            Align2::CENTER_CENTER,
            title,
            FontId::proportional(22.0),
            ACCENT,
        );
        p.text(
            area.center() + egui::vec2(0.0, 18.0),
            Align2::CENTER_CENTER,
            sub,
            FontId::proportional(13.0),
            Color32::from_rgb(170, 178, 192),
        );
    }

    fn draw_toasts(&self, ctx: &egui::Context, now: f64) {
        if self.toasts.is_empty() {
            return;
        }
        ctx.request_repaint_after(std::time::Duration::from_millis(70));
        egui::Area::new(egui::Id::unique(&"toasts"))
            .anchor(egui::Align2::RIGHT_BOTTOM, egui::vec2(-18.0, -124.0))
            .order(egui::Order::Foreground)
            .interactable(false)
            .show(ctx, |ui| {
                ui.with_layout(egui::Layout::bottom_up(egui::Align::RIGHT), |ui| {
                    for t in self.toasts.iter().rev() {
                        let age = now - t.born;
                        let a = if age > LIFE - 0.7 {
                            ((LIFE - age) / 0.7).clamp(0.0, 1.0) as f32
                        } else {
                            1.0
                        };
                        let (accent, bg) = match t.kind {
                            ToastKind::Ok => (OK, Color32::from_rgb(28, 44, 35)),
                            ToastKind::Err => (Color32::from_rgb(226, 108, 108), Color32::from_rgb(52, 30, 32)),
                            ToastKind::Info => (Color32::from_rgb(122, 160, 220), Color32::from_rgb(32, 36, 44)),
                        };
                        egui::Frame::new()
                            .fill(bg.gamma_multiply(a))
                            .corner_radius(6.0)
                            .stroke(Stroke::new(1.0, accent.gamma_multiply(a * 0.85)))
                            .inner_margin(egui::Margin::symmetric(11, 6))
                            .show(ui, |ui| {
                                ui.label(
                                    egui::RichText::new(&t.text)
                                        .size(12.5)
                                        .color(TEXT.gamma_multiply(a)),
                                );
                            });
                    }
                });
            });
    }
}

const LIFE: f64 = 3.4;

impl App {
    fn top_bar(&mut self, ui: &mut egui::Ui) {
        egui::Panel::top("top")
            .frame(
                egui::Frame::new()
                    .fill(PANEL_BG)
                    .inner_margin(egui::Margin::symmetric(14, 9)),
            )
            .show(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.label(
                        egui::RichText::new("像素打光器")
                            .size(19.0)
                            .strong()
                            .color(ACCENT),
                    );
                    ui.label(
                        egui::RichText::new("Rust 高性能版")
                            .size(11.5)
                            .color(TEXT_DIM),
                    );
                    ui.add_space(10.0);
                    ui.separator();
                    ui.add_space(6.0);

                    if ui
                        .add(egui::Button::new(
                            egui::RichText::new("打开底图").size(13.5).strong(),
                        ))
                        .clicked()
                    {
                        if let Some(p) = open_dialog() {
                            self.load_albedo(&p);
                        }
                    }
                    let has = self.albedo.is_some();
                    ui.add_enabled_ui(has, |ui| {
                        if ui
                            .add(egui::Button::new(
                                egui::RichText::new("导出最终图").size(13.5),
                            ))
                            .clicked()
                        {
                            self.export_final();
                        }
                        if ui
                            .button("导出全部")
                            .on_hover_text("一次性导出 最终合成 / 法线图 / 光照遮罩 三张 PNG")
                            .clicked()
                        {
                            self.export_all();
                        }
                        if ui.button("重置打光").clicked() {
                            let bg = self.settings.bg;
                            let (lx, ly) = match &self.albedo {
                                Some(a) => (a.w as f64 / 2.0, a.h as f64 / 2.0),
                                None => (0.0, 0.0),
                            };
                            self.settings = LightSettings {
                                bg,
                                lx,
                                ly,
                                ..Default::default()
                            };
                            self.dirty = true;
                            self.notify("打光参数已恢复默认", ToastKind::Info);
                        }
                    });

                    ui.add_space(4.0);
                    let undo_tip = self
                        .undo
                        .last()
                        .map(|s| format!("撤销「{}」（Ctrl+Z）", s.label))
                        .unwrap_or_else(|| "还没有可撤销的操作".to_string());
                    let redo_tip = self
                        .redo
                        .last()
                        .map(|s| format!("重做「{}」（Ctrl+Y）", s.label))
                        .unwrap_or_else(|| "还没有可重做的操作".to_string());
                    if ui
                        .add_enabled(!self.undo.is_empty(), egui::Button::new("撤销"))
                        .on_hover_text(undo_tip)
                        .clicked()
                    {
                        self.do_undo();
                    }
                    if ui
                        .add_enabled(!self.redo.is_empty(), egui::Button::new("重做"))
                        .on_hover_text(redo_tip)
                        .clicked()
                    {
                        self.do_redo();
                    }

                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        let chip = format!("打光渲染 {:.2} ms", self.render_ms);
                        ui.label(egui::RichText::new(chip).size(11.5).color(OK));
                        ui.label(
                            egui::RichText::new("滚轮缩放 · 中键平移 · 空格适应 · Ctrl+S 导出")
                                .size(11.0)
                                .color(TEXT_DIM),
                        );
                        if ui
                            .add(egui::Button::new(
                                egui::RichText::new(if self.show_left {
                                    "收起侧栏"
                                } else {
                                    "展开侧栏"
                                })
                                .size(12.0),
                            ))
                            .on_hover_text("快捷键 Tab")
                            .clicked()
                        {
                            self.show_left = !self.show_left;
                        }
                    });
                });
            });
    }

    fn status_bar(&mut self, ui: &mut egui::Ui) {
        egui::Panel::bottom("status")
            .frame(
                egui::Frame::new()
                    .fill(PANEL_BG)
                    .inner_margin(egui::Margin::symmetric(14, 5)),
            )
            .show(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.label(egui::RichText::new(&self.status).size(12.0).color(TEXT_DIM));
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        let n = self.albedo.as_ref().map(|a| a.w * a.h).unwrap_or(0);
                        let mut right = String::new();
                        if n > 0 {
                            right = format!("{} 像素", n);
                        }
                        if !self.font_note.is_empty() {
                            right = format!("{right}   {}", self.font_note);
                        }
                        ui.label(egui::RichText::new(right).size(11.0).color(TEXT_DIM));
                    });
                });
            });
    }

    /// 四个模式的缩略图切换条
    fn view_bar(&mut self, ui: &mut egui::Ui) {
        egui::Panel::bottom("viewbar")
            .exact_size(104.0)
            .resizable(false)
            .frame(
                egui::Frame::new()
                    .fill(Color32::from_rgb(21, 24, 29))
                    .inner_margin(egui::Margin::symmetric(14, 8)),
            )
            .show(ui, |ui| {
                ui.horizontal(|ui| {
                    let has_albedo = self.albedo.is_some();
                    let arts = self.aspect(Slot::Albedo);
                    let items = [
                        (
                            ViewMode::Final,
                            "最终合成",
                            self.thumb_final.as_ref().map(|t| t.id()),
                            arts,
                            has_albedo,
                            false,
                        ),
                        (
                            ViewMode::Albedo,
                            "底图",
                            self.thumb_albedo.as_ref().map(|t| t.id()),
                            arts,
                            has_albedo,
                            false,
                        ),
                        (
                            ViewMode::Normal,
                            "法线",
                            self.thumb_normal.as_ref().map(|t| t.id()),
                            self.aspect(Slot::Normal),
                            self.normal.is_some(),
                            true,
                        ),
                        (
                            ViewMode::Mask,
                            "遮罩",
                            self.thumb_mask.as_ref().map(|t| t.id()),
                            self.aspect(Slot::Mask),
                            self.mask.is_some(),
                            true,
                        ),
                    ];
                    let mut pick: Option<ViewMode> = None;
                    let mut want_gen: Option<Slot> = None;
                    for (mode, label, tid, aspect, has, generatable) in items {
                        let hint = if generatable && !has && has_albedo {
                            "点此生成"
                        } else {
                            ""
                        };
                        let resp = view_card(ui, tid, aspect, label, self.view == mode, has_albedo, hint);
                        if resp.clicked() {
                            if generatable && !has && has_albedo {
                                want_gen = Some(if mode == ViewMode::Normal {
                                    Slot::Normal
                                } else {
                                    Slot::Mask
                                });
                            } else {
                                pick = Some(mode);
                            }
                        }
                        if !has_albedo {
                            resp.on_hover_text("先打开一张底图");
                        } else if generatable && !has {
                            resp.on_hover_text(format!(
                                "还没有{}，点一下直接生成",
                                slot_title(if mode == ViewMode::Normal {
                                    Slot::Normal
                                } else {
                                    Slot::Mask
                                })
                            ));
                        } else {
                            resp.on_hover_text(format!("切到「{label}」视图（快捷键 V 循环）"));
                        }
                    }
                    if let Some(s) = want_gen {
                        match s {
                            Slot::Normal => self.gen_normal_now(),
                            Slot::Mask => self.gen_mask_now(),
                            Slot::Albedo => {}
                        }
                        self.view = if s == Slot::Normal {
                            ViewMode::Normal
                        } else {
                            ViewMode::Mask
                        };
                    }
                    if let Some(m) = pick {
                        self.view = m;
                        self.dirty = true;
                    }

                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        ui.add_enabled_ui(has_albedo, |ui| {
                            if ui.button("适应").on_hover_text("缩放到刚好放得下").clicked() {
                                self.need_fit = true;
                            }
                            if ui.button("1:1").on_hover_text("原始像素大小").clicked() {
                                self.zoom = 1.0;
                                self.pan = Vec2::ZERO;
                            }
                            if ui.button("＋").clicked() {
                                self.zoom = (self.zoom * 1.25).clamp(0.05, 64.0);
                            }
                            if ui.button("－").clicked() {
                                self.zoom = (self.zoom / 1.25).clamp(0.05, 64.0);
                            }
                            ui.label(
                                egui::RichText::new(format!("{:.0}%", self.zoom * 100.0))
                                    .size(12.0)
                                    .color(TEXT_DIM),
                            );
                        });
                    });
                });
            });
    }

    fn left_panel(&mut self, ui: &mut egui::Ui) {
        egui::Panel::left("left")
            .exact_size(368.0)
            .resizable(false)
            .frame(
                egui::Frame::new()
                    .fill(PANEL_BG)
                    .inner_margin(egui::Margin::symmetric(10, 8)),
            )
            .show(ui, |ui| {
                egui::ScrollArea::vertical()
                    .auto_shrink([false, false])
                    .show(ui, |ui| {
                        section_title(ui, "① 素材（导入 / 导出）");
                        self.material_card(ui, Slot::Albedo);
                        self.material_card(ui, Slot::Normal);
                        self.material_card(ui, Slot::Mask);

                        ui.add_space(10.0);
                        self.section_light(ui);

                        ui.add_space(10.0);
                        section_title(ui, "③ 生成立体法线");
                        self.card_gen_normal(ui);

                        ui.add_space(10.0);
                        section_title(ui, "④ 生成光照遮罩");
                        self.card_gen_mask(ui);

                        ui.add_space(10.0);
                        self.section_manual(ui);
                        ui.add_space(12.0);
                    });
            });
    }

    fn material_card(&mut self, ui: &mut egui::Ui, slot: Slot) {
        let has = self.has(slot);
        let name = self.name_of(slot);
        let size = self.size_text(slot);
        let tid = self.thumb_id(slot);
        let aspect = self.aspect(slot);
        let title = slot_title(slot);
        let idx = slot.index();

        let (_, rect) = card_with_rect(ui, |ui| {
            ui.horizontal(|ui| {
                let (r, _) = ui.allocate_exact_size(egui::vec2(46.0, 46.0), Sense::hover());
                let p = ui.painter();
                p.rect_filled(r, 4.0, BG_DARK);
                p.rect_stroke(
                    r,
                    4.0,
                    Stroke::new(1.0, BORDER),
                    egui::StrokeKind::Inside,
                );
                match tid {
                    Some(t) if has => {
                        let inner = r.shrink(2.0);
                        p.image(
                            t,
                            fit_into(inner, aspect),
                            Rect::from_min_max(Pos2::ZERO, Pos2::new(1.0, 1.0)),
                            Color32::WHITE,
                        );
                    }
                    _ => {
                        p.text(
                            r.center(),
                            Align2::CENTER_CENTER,
                            "空",
                            FontId::proportional(12.0),
                            TEXT_DIM,
                        );
                    }
                }
                ui.vertical(|ui| {
                    ui.label(
                        egui::RichText::new(title)
                            .size(13.0)
                            .strong()
                            .color(if has { TEXT } else { TEXT_DIM }),
                    );
                    let sub = if has {
                        format!("{name}  {size}")
                    } else {
                        "未载入".to_string()
                    };
                    ui.label(egui::RichText::new(sub).size(10.5).color(TEXT_DIM));
                });
            });

            ui.add_space(2.0);
            ui.horizontal(|ui| {
                if ui
                    .button(if has { "重新导入" } else { "导入" })
                    .on_hover_text("从 PNG 导入这张贴图")
                    .clicked()
                {
                    if let Some(p) = open_dialog() {
                        self.load_slot(slot, &p);
                    }
                }
                if ui
                    .add_enabled(has, egui::Button::new("导出"))
                    .on_hover_text("把这张贴图另存为 PNG")
                    .clicked()
                {
                    self.export_slot(slot);
                }
                if slot != Slot::Albedo
                    && ui
                        .add_enabled(self.albedo.is_some(), egui::Button::new("自动生成"))
                        .clicked()
                {
                    if slot == Slot::Normal {
                        self.gen_normal_now();
                    } else {
                        self.gen_mask_now();
                    }
                }
                if slot != Slot::Albedo
                    && ui
                        .add_enabled(has, egui::Button::new("清除"))
                        .clicked()
                {
                    self.snapshot("清除贴图");
                    match slot {
                        Slot::Normal => {
                            self.normal = None;
                            self.normal_name.clear();
                            self.thumb_normal = None;
                            self.rebuild_cache();
                        }
                        Slot::Mask => {
                            self.mask = None;
                            self.mask_name.clear();
                            self.thumb_mask = None;
                            self.dirty = true;
                        }
                        Slot::Albedo => {}
                    }
                    self.notify(format!("已清除{}", slot_title(slot)), ToastKind::Info);
                }
            });
        });

        self.slot_rects[idx] = Some(rect);
        // 拖放时高亮将要被替换的那张卡
        if self.drop_hover == Some(slot) {
            ui.painter().rect_stroke(
                rect.expand(1.5),
                7.0,
                Stroke::new(2.0, ACCENT),
                egui::StrokeKind::Outside,
            );
        }
    }

    fn section_light(&mut self, ui: &mut egui::Ui) {
        section_title(ui, "② 打光参数");
        let mut changed = false;
        card(ui, |ui| {
            changed |= param_row(
                ui,
                "亮度",
                &mut self.settings.power,
                0.0..=25.0,
                1,
                "",
                "光源的总强度。越大越亮，过大时亮部会过曝变白。",
            );
            changed |= param_row(
                ui,
                "光圈半径",
                &mut self.settings.falloff,
                10.0..=200.0,
                0,
                " px",
                "光照能覆盖的范围。半径越大，明暗过渡越平缓；越小，越像聚光灯。",
            );
            changed |= param_row(
                ui,
                "光源高度",
                &mut self.settings.height,
                5.0..=200.0,
                0,
                " px",
                "光源离画面有多高。数值大接近均匀的平行光，数值小像贴着画面的手电筒。",
            );
            let mut amb = (self.settings.ambient * 100.0).round();
            if param_row(
                ui,
                "环境光",
                &mut amb,
                0.0..=100.0,
                0,
                "%",
                "没有被直射到的部分保留多少底图亮度。0% 时背光面全黑。",
            ) {
                self.settings.ambient = amb / 100.0;
                changed = true;
            }
            let mut mix = (self.settings.mask_mix * 100.0).round();
            if param_row(
                ui,
                "遮罩影响",
                &mut mix,
                0.0..=100.0,
                0,
                "%",
                "光照遮罩对受光的影响程度。0% 等于不使用遮罩。",
            ) {
                self.settings.mask_mix = mix / 100.0;
                changed = true;
            }

            ui.horizontal(|ui| {
                ui.label(egui::RichText::new("光色").size(12.0).color(TEXT_DIM));
                if ui
                    .color_edit_button_srgb(&mut self.settings.light)
                    .on_hover_text("直射光的颜色，暖色可做夕阳感")
                    .changed()
                {
                    changed = true;
                }
                ui.add_space(8.0);
                ui.label(egui::RichText::new("背景色").size(12.0).color(TEXT_DIM));
                if ui
                    .color_edit_button_srgb(&mut self.settings.bg)
                    .on_hover_text("用于「隐藏背景」时判断哪些像素算背景")
                    .changed()
                {
                    changed = true;
                }
                if ui
                    .add_enabled(self.albedo.is_some(), egui::Button::new("检测"))
                    .on_hover_text("自动识别底图边缘最常见的颜色作为背景色")
                    .clicked()
                {
                    if let Some(bg) = self.albedo.as_ref().and_then(|a| a.detect_bg()) {
                        self.settings.bg = bg;
                        self.gen_normal.bg = bg;
                        self.gen_mask.bg = bg;
                        changed = true;
                    }
                }
            });
            ui.horizontal(|ui| {
                if ui
                    .checkbox(&mut self.settings.hide_bg, "隐藏背景色")
                    .on_hover_text("把背景色当作透明，只给主体打光")
                    .changed()
                {
                    changed = true;
                }
                if ui
                    .checkbox(&mut self.follow_mouse, "光源跟随鼠标")
                    .on_hover_text("关闭后只有按住左键拖动才移动光源")
                    .changed()
                {
                    changed = true;
                }
            });
            ui.label(
                egui::RichText::new(format!(
                    "光源坐标  {:.0}, {:.0}",
                    self.settings.lx, self.settings.ly
                ))
                .size(10.5)
                .color(TEXT_DIM),
            );
        });
        if changed {
            self.dirty = true;
        }
    }

    fn card_gen_normal(&mut self, ui: &mut egui::Ui) {
        let mut changed = false;
        card(ui, |ui| {
            ui.horizontal(|ui| {
                ui.label(egui::RichText::new("预设").size(12.0).color(TEXT_DIM));
                let mut idx = self.gen_normal.preset.index();
                egui::ComboBox::from_id_salt("preset")
                    .width(120.0)
                    .selected_text(self.gen_normal.preset.label())
                    .show_ui(ui, |ui| {
                        for p in [
                            Preset::Architecture,
                            Preset::Object,
                            Preset::Terrain,
                            Preset::Character,
                        ] {
                            ui.selectable_value(&mut idx, p.index(), p.label());
                        }
                    });
                let np = Preset::from_index(idx);
                if np != self.gen_normal.preset {
                    self.gen_normal.preset = np;
                    let (s, f, fl, ce, ca) = np.defaults();
                    self.gen_normal.strength = s;
                    self.gen_normal.facets = f;
                    self.gen_normal.floor = fl;
                    self.gen_normal.ceiling = ce;
                    self.gen_normal.cavity = ca;
                    self.gen_normal.edge_width = np.default_edge_width();
                    changed = true;
                }
                ui.label(
                    egui::RichText::new("建筑偏硬朗 · 物体通用 · 地形起伏 · 角色柔和")
                        .size(10.0)
                        .color(TEXT_DIM),
                );
            });

            changed |= param_row(
                ui,
                "起伏强度",
                &mut self.gen_normal.strength,
                0.0..=200.0,
                0,
                "%",
                "整体立体感的强弱。100% 是预设推荐值。",
            );
            changed |= param_row(
                ui,
                "法线强度",
                &mut self.gen_normal.normal_strength,
                0.0..=300.0,
                0,
                "%",
                "法线倾斜的夸张程度。调高打光时明暗对比更强烈。",
            );
            changed |= param_row(
                ui,
                "柔化遍数",
                &mut self.gen_normal.edge_width,
                0.0..=6.0,
                0,
                " 遍",
                "对高度场做模糊的遍数。0 最锐利，越大越圆润。",
            );
            changed |= param_row(
                ui,
                "分面数量",
                &mut self.gen_normal.facets,
                0.0..=100.0,
                0,
                "",
                "把大块区域切分成不同朝向的小面。0 = 每块只有一个朝向。",
            );
            ui.horizontal(|ui| {
                if ui
                    .checkbox(&mut self.gen_normal.merge, "合并描边")
                    .on_hover_text("让 1 像素描边跟随旁边的朝向，避免黑线乱翘")
                    .changed()
                {
                    changed = true;
                }
                ui.checkbox(&mut self.auto_gen, "调参即时预览")
                    .on_hover_text("关闭后改参数需要手动点生成");
            });

            ui.add_space(2.0);
            ui.horizontal(|ui| {
                if ui
                    .add_enabled(
                        self.albedo.is_some(),
                        egui::Button::new(egui::RichText::new("生成立体法线").strong()),
                    )
                    .clicked()
                {
                    self.gen_normal_now();
                }
                ui.label(
                    egui::RichText::new("让平面的像素画有“鼓起来”的立体感")
                        .size(10.5)
                        .color(TEXT_DIM),
                );
            });
        });
        if changed {
            if self.auto_gen && self.albedo.is_some() {
                self.gen_normal_now();
            } else {
                self.status = "参数已改动，点「生成立体法线」应用。".into();
            }
        }
    }

    fn card_gen_mask(&mut self, ui: &mut egui::Ui) {
        let mut changed = false;
        card(ui, |ui| {
            changed |= param_row(
                ui,
                "强度",
                &mut self.gen_mask.strength,
                0.0..=200.0,
                0,
                "%",
                "遮罩整体对比度。100% 是标准值。",
            );
            changed |= param_row(
                ui,
                "最暗处",
                &mut self.gen_mask.floor,
                0.0..=255.0,
                0,
                "",
                "最暗区域还能接收多少光。数值越大，暗部越不会全黑。",
            );
            changed |= param_row(
                ui,
                "最亮处",
                &mut self.gen_mask.ceiling,
                0.0..=255.0,
                0,
                "",
                "最亮区域的上限。调低可以避免亮部过曝。",
            );
            changed |= param_row(
                ui,
                "凹槽压暗",
                &mut self.gen_mask.cavity,
                0.0..=100.0,
                0,
                "%",
                "被更亮的像素包围的凹陷处额外压暗，用来强调缝隙和褶皱。",
            );
            if ui
                .checkbox(&mut self.gen_mask.merge, "合并描边")
                .changed()
            {
                changed = true;
            }
            ui.label(
                egui::RichText::new("遮罩越亮 = 越容易受光；用来控制哪里能被打亮")
                    .size(10.5)
                    .color(TEXT_DIM),
            );
            ui.add_space(2.0);
            if ui
                .add_enabled(
                    self.albedo.is_some(),
                    egui::Button::new(egui::RichText::new("生成光照遮罩").strong()),
                )
                .clicked()
            {
                self.gen_mask_now();
            }
        });
        if changed && self.auto_gen && self.albedo.is_some() && self.mask.is_some() {
            self.gen_mask_now();
        }
    }

    fn section_manual(&mut self, ui: &mut egui::Ui) {
        section_title(ui, "⑤ 手动修正方向（可选）");
        card(ui, |ui| {
            egui::CollapsingHeader::new(
                egui::RichText::new("展开：给指定区域手动指定朝向 / 遮罩亮度")
                    .size(12.0)
                    .color(TEXT_DIM),
            )
            .default_open(false)
            .show(ui, |ui| {
                self.ensure_sel();
                ui.horizontal(|ui| {
                    ui.checkbox(&mut self.brush_mode, "画笔选区")
                        .on_hover_text("打开后左键拖动是在画选区，不会移动光源");
                });
                param_row(ui, "笔刷大小", &mut self.brush, 1.0..=20.0, 0, " px", "");

                ui.horizontal(|ui| {
                    if ui.button("全选").clicked() {
                        self.ensure_sel();
                        for s in self.sel.iter_mut() {
                            *s = true;
                        }
                        self.sel_count = self.sel.len();
                        self.sel_dirty = true;
                    }
                    if ui.button("反选").clicked() {
                        for s in self.sel.iter_mut() {
                            *s = !*s;
                        }
                        self.sel_count = self.sel.iter().filter(|s| **s).count();
                        self.sel_dirty = true;
                    }
                    if ui.button("清空").clicked() {
                        for s in self.sel.iter_mut() {
                            *s = false;
                        }
                        self.sel_count = 0;
                        self.sel_dirty = true;
                    }
                    if ui
                        .add_enabled(!self.undo.is_empty(), egui::Button::new("撤销"))
                        .on_hover_text("Ctrl+Z · 覆盖生成、导入、手动修正")
                        .clicked()
                    {
                        self.do_undo();
                    }
                    if ui
                        .add_enabled(!self.redo.is_empty(), egui::Button::new("重做"))
                        .on_hover_text("Ctrl+Y")
                        .clicked()
                    {
                        self.do_redo();
                    }
                });
                ui.label(
                    egui::RichText::new(format!("当前已选 {} 个像素", self.sel_count))
                        .size(10.5)
                        .color(TEXT_DIM),
                );

                ui.add_space(4.0);
                ui.label(egui::RichText::new("① 指定朝向").size(12.0).strong());
                ui.horizontal_wrapped(|ui| {
                    for (i, (_, label)) in DIRECTIONS.iter().enumerate() {
                        if ui
                            .selectable_label(self.direction == i, *label)
                            .clicked()
                        {
                            self.direction = i;
                        }
                    }
                });
                param_row(ui, "倾斜角", &mut self.tilt, 0.0..=90.0, 0, "°", "");
                if ui
                    .add_enabled(
                        self.normal.is_some() && self.sel_count > 0,
                        egui::Button::new("应用到法线图"),
                    )
                    .clicked()
                {
                    self.apply_direction();
                }

                ui.add_space(6.0);
                ui.label(egui::RichText::new("② 指定遮罩亮度").size(12.0).strong());
                param_row(ui, "亮度值", &mut self.mask_value, 0.0..=100.0, 0, "%", "");
                ui.checkbox(&mut self.mask_relative, "相对叠加（在原亮度上加减）");
                if ui
                    .add_enabled(
                        self.mask.is_some() && self.sel_count > 0,
                        egui::Button::new("应用到遮罩"),
                    )
                    .clicked()
                {
                    self.apply_mask_value();
                }
            });
        });
    }

    fn central(&mut self, ui: &mut egui::Ui) {
        egui::CentralPanel::default()
            .frame(
                egui::Frame::new()
                    .fill(BG_DARK)
                    .inner_margin(egui::Margin::same(0)),
            )
            .show(ui, |ui| {
                let avail = ui.available_rect_before_wrap();
                let resp = ui.allocate_rect(avail, Sense::click_and_drag());
                let painter = ui.painter_at(avail);

                let (wi, hi) = match &self.albedo {
                    Some(a) => (a.w, a.h),
                    None => (0, 0),
                };
                if wi == 0 || hi == 0 {
                    self.hover_px = None;
                    // 空状态：给一张可点的引导卡，而不是干巴巴一行字
                    let c = Rect::from_center_size(avail.center(), egui::vec2(470.0, 208.0));
                    painter.rect_filled(c, 13.0, Color32::from_rgb(28, 32, 39));
                    painter.rect_stroke(
                        c,
                        13.0,
                        Stroke::new(1.0, BORDER),
                        egui::StrokeKind::Inside,
                    );
                    painter.text(
                        c.center() - egui::vec2(0.0, 48.0),
                        Align2::CENTER_CENTER,
                        "把 PNG 拖到这里",
                        FontId::proportional(21.0),
                        TEXT,
                    );
                    painter.text(
                        c.center() - egui::vec2(0.0, 16.0),
                        Align2::CENTER_CENTER,
                        "或者点下面的按钮选一张像素画底图 · 支持随时再拖入替换",
                        FontId::proportional(12.5),
                        TEXT_DIM,
                    );
                    let btn = Rect::from_center_size(
                        c.center() + egui::vec2(0.0, 46.0),
                        egui::vec2(176.0, 38.0),
                    );
                    if ui
                        .put(
                            btn,
                            egui::Button::new(
                                egui::RichText::new("选择图片…").size(14.0).strong(),
                            ),
                        )
                        .clicked()
                    {
                        if let Some(p) = open_dialog() {
                            self.load_albedo(&p);
                        }
                    }
                    return;
                }
                let (w, h) = (wi as f32, hi as f32);

                if self.need_fit {
                    self.fit(avail, w, h);
                }

                if resp.hovered() {
                    let scroll = ui.input(|i| i.smooth_scroll_delta.y);
                    if scroll.abs() > 0.01 {
                        let before = self.image_rect(avail, w, h);
                        let anchor = ui
                            .input(|i| i.pointer.hover_pos())
                            .unwrap_or_else(|| avail.center());
                        let fx = if before.width() > 0.0 {
                            (anchor.x - before.min.x) / self.zoom
                        } else {
                            0.0
                        };
                        let fy = if before.height() > 0.0 {
                            (anchor.y - before.min.y) / self.zoom
                        } else {
                            0.0
                        };
                        self.zoom = (self.zoom * (1.0 + scroll * 0.0018)).clamp(0.05, 64.0);
                        let after = egui::vec2(w * self.zoom, h * self.zoom);
                        let want_min = anchor - egui::vec2(fx * self.zoom, fy * self.zoom);
                        self.pan = (want_min + after / 2.0) - avail.center();
                    }
                }

                if resp.dragged_by(egui::PointerButton::Middle) {
                    self.pan += resp.drag_delta();
                }

                let img_rect = self.image_rect(avail, w, h);
                draw_checkerboard(&painter, img_rect, self.zoom);

                let uv = Rect::from_min_max(Pos2::ZERO, Pos2::new(1.0, 1.0));
                if let Some(tex) = &self.tex {
                    painter.image(tex.id(), img_rect, uv, Color32::WHITE);
                }
                if let Some(t) = &self.sel_tex {
                    painter.image(t.id(), img_rect, uv, Color32::WHITE);
                }
                painter.rect_stroke(
                    img_rect,
                    0.0,
                    Stroke::new(1.0, Color32::from_gray(72)),
                    egui::StrokeKind::Outside,
                );

                let pointer = ui.input(|i| i.pointer.interact_pos());
                let primary_down = ui.input(|i| i.pointer.primary_down());
                if let Some(pos) = pointer {
                    if resp.hovered() || resp.dragged() {
                        let t = (pos - img_rect.min) / self.zoom;
                        if self.brush_mode {
                            if primary_down {
                                let cur = (t.x.round() as i32, t.y.round() as i32);
                                let prev = self.last_paint.unwrap_or(cur);
                                self.paint_selection(prev, cur);
                                self.last_paint = Some(cur);
                            } else {
                                self.last_paint = None;
                            }
                        } else if (self.follow_mouse || primary_down)
                            && ((self.settings.lx - t.x as f64).abs() > 1e-9
                                || (self.settings.ly - t.y as f64).abs() > 1e-9)
                        {
                            self.settings.lx = t.x as f64;
                            self.settings.ly = t.y as f64;
                            self.dirty = true;
                        }
                    }
                }

                if self.view == ViewMode::Final {
                    draw_light_marker(&painter, img_rect, self.zoom, &self.settings);
                }

                // 鼠标所在像素 + 像素格高亮
                self.hover_px = None;
                if let Some(pos) = pointer {
                    if img_rect.contains(pos) {
                        let t = (pos - img_rect.min) / self.zoom;
                        let px = (t.x.floor() as i32, t.y.floor() as i32);
                        if px.0 >= 0 && px.1 >= 0 && (px.0 as usize) < wi && (px.1 as usize) < hi {
                            self.hover_px = Some(px);
                            if self.zoom >= 6.0 {
                                let cell = Rect::from_min_size(
                                    img_rect.min
                                        + egui::vec2(
                                            px.0 as f32 * self.zoom,
                                            px.1 as f32 * self.zoom,
                                        ),
                                    egui::vec2(self.zoom, self.zoom),
                                );
                                painter.rect_stroke(
                                    cell,
                                    0.0,
                                    Stroke::new(1.2, ACCENT),
                                    egui::StrokeKind::Outside,
                                );
                            }
                        }
                    }
                }

                painter.text(
                    avail.min + egui::vec2(12.0, 10.0),
                    Align2::LEFT_TOP,
                    format!("{}  ·  {}×{}", view_label(self.view), wi, hi),
                    FontId::proportional(12.0),
                    Color32::from_rgb(150, 158, 172),
                );
                if let Some((x, y)) = self.hover_px {
                    painter.text(
                        avail.left_bottom() + egui::vec2(12.0, -10.0),
                        Align2::LEFT_BOTTOM,
                        format!("X {x}   Y {y}"),
                        FontId::proportional(12.0),
                        Color32::from_rgb(150, 158, 172),
                    );
                }

                if ui.input(|i| i.key_pressed(egui::Key::Space)) {
                    self.need_fit = true;
                }
            });
    }
}

// ================================================================ 小部件

fn card<R>(ui: &mut egui::Ui, add: impl FnOnce(&mut egui::Ui) -> R) -> R {
    card_with_rect(ui, add).0
}

/// 同 `card`，但同时返回整张卡片的矩形（用于拖放命中检测）
fn card_with_rect<R>(
    ui: &mut egui::Ui,
    add: impl FnOnce(&mut egui::Ui) -> R,
) -> (R, Rect) {
    let r = egui::Frame::new()
        .fill(CARD_BG)
        .corner_radius(7.0)
        .stroke(Stroke::new(1.0, BORDER))
        .inner_margin(egui::Margin::same(9))
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            add(ui)
        });
    (r.inner, r.response.rect)
}

fn section_title(ui: &mut egui::Ui, text: &str) {
    ui.add_space(2.0);
    ui.horizontal(|ui| {
        let (rect, _) = ui.allocate_exact_size(egui::vec2(3.0, 14.0), Sense::hover());
        ui.painter().rect_filled(rect, 1.5, ACCENT);
        ui.label(egui::RichText::new(text).size(13.0).strong().color(TEXT));
    });
    ui.add_space(2.0);
}

fn param_row(
    ui: &mut egui::Ui,
    label: &str,
    value: &mut f64,
    range: std::ops::RangeInclusive<f64>,
    decimals: usize,
    suffix: &str,
    tip: &str,
) -> bool {
    let mut changed = false;
    ui.horizontal(|ui| {
        ui.add_sized(
            egui::vec2(64.0, 19.0),
            egui::Label::new(egui::RichText::new(label).size(12.0).color(TEXT_DIM)),
        );
        let mut s = egui::Slider::new(value, range).max_decimals(decimals);
        if !suffix.is_empty() {
            s = s.suffix(suffix);
        }
        let resp = ui.add(s);
        if !tip.is_empty() {
            resp.clone().on_hover_text(tip);
        }
        changed = resp.changed();
    });
    changed
}

fn view_card(
    ui: &mut egui::Ui,
    thumb: Option<TextureId>,
    aspect: f32,
    label: &str,
    selected: bool,
    ready: bool,
    hint: &str,
) -> egui::Response {
    let size = egui::vec2(112.0, 76.0);
    let (rect, resp) = ui.allocate_exact_size(size, Sense::click());
    let hovered = resp.hovered();
    let bg = if selected {
        Color32::from_rgb(52, 58, 70)
    } else if hovered {
        CARD_BG2
    } else {
        CARD_BG
    };
    let p = ui.painter();
    p.rect_filled(rect, 7.0, bg);
    p.rect_stroke(
        rect,
        7.0,
        Stroke::new(
            if selected { 1.6 } else { 1.0 },
            if selected { ACCENT } else { BORDER },
        ),
        egui::StrokeKind::Inside,
    );

    let img_area = Rect::from_min_max(
        rect.min + egui::vec2(7.0, 7.0),
        egui::pos2(rect.max.x - 7.0, rect.max.y - 21.0),
    );
    match thumb {
        Some(t) if ready => {
            p.image(
                t,
                fit_into(img_area, aspect),
                Rect::from_min_max(Pos2::ZERO, Pos2::new(1.0, 1.0)),
                Color32::WHITE,
            );
        }
        _ => {
            let (t, col) = if hint.is_empty() {
                ("—", Color32::from_gray(85))
            } else {
                (hint, ACCENT.gamma_multiply(0.85))
            };
            p.text(
                img_area.center(),
                Align2::CENTER_CENTER,
                t,
                FontId::proportional(if hint.is_empty() { 15.0 } else { 12.0 }),
                col,
            );
        }
    }
    p.text(
        egui::pos2(rect.center().x, rect.max.y - 10.0),
        Align2::CENTER_CENTER,
        label,
        FontId::proportional(12.0),
        if selected { ACCENT } else { TEXT },
    );
    resp
}

fn fit_into(area: Rect, aspect: f32) -> Rect {
    if aspect <= 0.0 || !aspect.is_finite() {
        return area;
    }
    let a = area.width() / area.height().max(1.0);
    if aspect > a {
        let w = area.width();
        Rect::from_center_size(area.center(), egui::vec2(w, w / aspect))
    } else {
        let h = area.height();
        Rect::from_center_size(area.center(), egui::vec2(h * aspect, h))
    }
}

fn slot_title(slot: Slot) -> &'static str {
    match slot {
        Slot::Albedo => "底图",
        Slot::Normal => "法线图",
        Slot::Mask => "光照遮罩",
    }
}

fn view_label(v: ViewMode) -> &'static str {
    match v {
        ViewMode::Final => "最终合成",
        ViewMode::Albedo => "底图",
        ViewMode::Normal => "法线",
        ViewMode::Mask => "光照遮罩",
    }
}

/// 生成缩略图：每格做 3×3 采样，代价与源图大小基本无关
fn make_thumb(w: usize, h: usize, data: &[u8], max: usize) -> (usize, usize, Vec<u8>) {
    let scale = (w as f32 / max as f32).max(h as f32 / max as f32).max(1.0);
    let tw = ((w as f32 / scale).round() as usize).max(1).min(w);
    let th = ((h as f32 / scale).round() as usize).max(1).min(h);
    let mut out = vec![0u8; tw * th * 4];
    for ty in 0..th {
        let y0 = ty * h / th;
        let y1 = (((ty + 1) * h) / th).max(y0 + 1);
        for tx in 0..tw {
            let x0 = tx * w / tw;
            let x1 = (((tx + 1) * w) / tw).max(x0 + 1);
            let mut acc = [0f32; 3];
            let mut asum = 0f32;
            let mut n = 0f32;
            for sy in 0..3 {
                let py = y0 + (y1 - y0 - 1) * sy / 2;
                for sx in 0..3 {
                    let px = x0 + (x1 - x0 - 1) * sx / 2;
                    let i = (py * w + px) * 4;
                    let a = data[i + 3] as f32 / 255.0;
                    for c in 0..3 {
                        acc[c] += data[i + c] as f32 * a;
                    }
                    asum += a;
                    n += 1.0;
                }
            }
            let o = (ty * tw + tx) * 4;
            if asum > 0.01 {
                for c in 0..3 {
                    out[o + c] = (acc[c] / asum).round().clamp(0.0, 255.0) as u8;
                }
            }
            out[o + 3] = ((asum / n) * 255.0).round().clamp(0.0, 255.0) as u8;
        }
    }
    (tw, th, out)
}

fn put_thumb(
    handle: &mut Option<egui::TextureHandle>,
    ctx: &egui::Context,
    name: &str,
    w: usize,
    h: usize,
    data: &[u8],
) {
    let img = egui::ColorImage::from_rgba_unmultiplied([w, h], data);
    match handle {
        Some(t) => t.set(img, egui::TextureOptions::LINEAR),
        None => *handle = Some(ctx.load_texture(name, img, egui::TextureOptions::LINEAR)),
    }
}

fn draw_checkerboard(painter: &egui::Painter, rect: Rect, zoom: f32) {
    painter.rect_filled(rect, 0.0, Color32::from_rgb(40, 43, 49));
    let cell = (zoom * 8.0).max(8.0);
    let mut y = rect.min.y;
    let mut row = 0;
    while y < rect.max.y {
        let mut x = rect.min.x + if row % 2 == 0 { 0.0 } else { cell };
        while x < rect.max.x {
            let r = Rect::from_min_size(
                Pos2::new(x, y),
                egui::vec2(cell.min(rect.max.x - x), cell.min(rect.max.y - y)),
            );
            painter.rect_filled(r, 0.0, Color32::from_rgb(46, 49, 56));
            x += cell * 2.0;
        }
        y += cell;
        row += 1;
    }
}

fn draw_light_marker(painter: &egui::Painter, img_rect: Rect, zoom: f32, s: &LightSettings) {
    let c = img_rect.min + egui::vec2(s.lx as f32 * zoom, s.ly as f32 * zoom);
    let light = Color32::from_rgb(s.light[0], s.light[1], s.light[2]);
    let hf = ((s.height.max(1.0) - 1.0) / 100.0).ln_1p() as f32;
    let stem = 55.0 * hf / 6f32.ln();
    let top = c - egui::vec2(0.0, stem * zoom.max(0.5));

    painter.line_segment(
        [c, top],
        Stroke::new(
            1.0,
            Color32::from_rgba_unmultiplied(light.r(), light.g(), light.b(), 80),
        ),
    );
    let r = (s.falloff as f32) * zoom;
    if r > 1.0 {
        painter.circle_stroke(
            c,
            r,
            Stroke::new(
                1.0,
                Color32::from_rgba_unmultiplied(light.r(), light.g(), light.b(), 70),
            ),
        );
    }
    let arm = 5.0;
    painter.line_segment(
        [c - egui::vec2(arm, 0.0), c + egui::vec2(arm, 0.0)],
        Stroke::new(1.0, light.gamma_multiply(0.75)),
    );
    painter.line_segment(
        [c - egui::vec2(0.0, arm), c + egui::vec2(0.0, arm)],
        Stroke::new(1.0, light.gamma_multiply(0.75)),
    );
    painter.circle_filled(c, 2.5, light);
    painter.circle_filled(top, 2.0, light.gamma_multiply(0.9));
}

fn install_fonts(ctx: &egui::Context) -> String {
    let candidates = [
        ("微软雅黑", "C:/Windows/Fonts/msyh.ttc"),
        ("微软雅黑细体", "C:/Windows/Fonts/msyhl.ttc"),
        ("黑体", "C:/Windows/Fonts/simhei.ttf"),
        ("等线", "C:/Windows/Fonts/Deng.ttf"),
        ("宋体", "C:/Windows/Fonts/simsun.ttc"),
    ];
    for (name, path) in candidates {
        if let Ok(bytes) = std::fs::read(path) {
            let mut fonts = egui::FontDefinitions::default();
            fonts.font_data.insert(
                "cjk".to_owned(),
                Arc::new(egui::FontData::from_owned(bytes)),
            );
            for fam in [egui::FontFamily::Proportional, egui::FontFamily::Monospace] {
                fonts
                    .families
                    .entry(fam)
                    .or_default()
                    .insert(0, "cjk".to_owned());
            }
            ctx.set_fonts(fonts);
            return format!("字体 {name}");
        }
    }
    "未找到中文字体".to_string()
}

fn open_dialog() -> Option<PathBuf> {
    rfd::FileDialog::new()
        .add_filter("PNG 图片", &["png"])
        .add_filter("所有文件", &["*"])
        .pick_file()
}

fn save_dialog(suggested: &str, start_dir: Option<&Path>) -> Option<PathBuf> {
    let mut d = rfd::FileDialog::new()
        .add_filter("PNG 图片", &["png"])
        .set_file_name(suggested);
    if let Some(dir) = start_dir {
        d = d.set_directory(dir);
    }
    d.save_file()
}

fn file_label(p: &Path) -> String {
    p.file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| p.display().to_string())
}

fn stem_of(name: &str) -> String {
    match name.rfind('.') {
        Some(i) if i > 0 => name[..i].to_string(),
        _ => {
            if name.is_empty() || name == "自动生成" {
                "纹理".to_string()
            } else {
                name.to_string()
            }
        }
    }
}
