//! 像素打光器 · Rust 高性能版
//!
//! 无参数启动图形界面；带参数启动命令行批量模式。

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod app;
mod cli;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    // 单个文件参数 => 直接进界面并载入（支持"打开方式"/拖到 exe 上）
    let gui_file = if args.len() == 1 && !args[0].starts_with('-') {
        let p = std::path::PathBuf::from(&args[0]);
        if p.is_file() {
            Some(p)
        } else {
            None
        }
    } else {
        None
    };

    if args.is_empty() || gui_file.is_some() {
        let options = eframe::NativeOptions {
            viewport: eframe::egui::ViewportBuilder::default()
                .with_inner_size([1380.0, 880.0])
                .with_min_inner_size([1000.0, 640.0])
                .with_title("像素打光器 · Rust 高性能版"),
            ..Default::default()
        };
        let _ = eframe::run_native(
            "像素打光器",
            options,
            Box::new(move |cc| {
                Ok(Box::new(app::App::new(cc, gui_file.clone())) as Box<dyn eframe::App>)
            }),
        );
    } else {
        std::process::exit(cli::run(&args));
    }
}
