//! PNG 读写

use crate::algorithm::Img;
use std::path::Path;

pub fn load_png(path: &Path) -> Result<Img, String> {
    let img = image::open(path).map_err(|e| e.to_string())?.to_rgba8();
    let (w, h) = (img.width() as usize, img.height() as usize);
    Ok(Img::from_rgba(w, h, img.into_raw()))
}

pub fn save_png(w: usize, h: usize, data: &[u8], path: &Path) -> Result<(), String> {
    image::save_buffer_with_format(
        path,
        data,
        w as u32,
        h as u32,
        image::ExtendedColorType::Rgba8,
        image::ImageFormat::Png,
    )
    .map_err(|e| e.to_string())
}
