//! 把 PNG 转成裸 RGBA，供对照脚本使用
//! 用法: cargo run --release --example dump_raw -- <输入png> <输出raw>

fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    if a.len() < 2 {
        eprintln!("用法: dump_raw <png> <raw>");
        std::process::exit(2);
    }
    let img = pixel_lighter::io::load_png(std::path::Path::new(&a[0])).expect("读取失败");
    std::fs::write(&a[1], &img.data).expect("写入失败");
    println!("{} {} {}", img.w, img.h, a[1]);
}
