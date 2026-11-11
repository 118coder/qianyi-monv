# 像素打光器（pixel-lighter-rs）

把平面像素画变成立体、可打光的桌面工具：输入一张 PNG 底图，自动生成
**立体法线图**与**光照遮罩**，画布上移动光源即可实时预览明暗。

- 发布版 exe 与中文说明在 [`../pixel-lighter/`](../pixel-lighter/)，双击仓库根目录的 `打光工具箱.bat` 即可启动
- 本目录是完整 Rust 源码（GUI 用 eframe/egui，批量模式用 CLI 参数）

## 算法出处与等价性

算法 1:1 移植自开源网页工具 **Pixel-Art-Lighter v3.5.23**（单文件 HTML，
其脚本含 `renderPixels` / `generateTexture` / `applySurfaceHints` 等）。
移植后用「黄金对照测试」验证等价性：`verify/gen_ref.js` 用 Node 跑原版函数
产出参考像素，[`tests/golden.rs`](tests/golden.rs) 对 Rust 实现做**逐字节比对**，
22 组用例（13 法线 + 2 遮罩 + 4 光照 + 3 视图）全部一致。

## 性能（576×384 图，原版 JS 对比）

| 环节 | 原版 JS | Rust | 加速 |
|---|---|---|---|
| 法线图生成 | ~238 ms | ~31 ms | ~7.5× |
| 光照遮罩生成 | ~45 ms | ~15 ms | ~3× |
| 打光渲染 | ~28.7 ms | ~1.45 ms | ~20× |

## 构建

```bash
cargo build --release          # 需要 Rust 1.96+，无其它系统依赖
cargo test  --release          # 6 项单测 + 22 组黄金对照
cargo run   --release -- --input 某图.png        # CLI 批量模式
cargo run   --release -- --input-dir 目录 --out 输出目录
```

注意：`verify/ref/` 下的 `.raw` 是测试 fixture（已入库，不要删）；
重新生成参考数据的办法见 [`verify/README.md`](verify/README.md)。

## 目录

```
src/algorithm.rs   核心算法（法线生成管线 / 遮罩 / 打光渲染，f32 缓存对齐原版 Float32Array）
src/app.rs         全中文 GUI（拖放、撤销/重做、快捷键、四视图缩略图）
src/cli.rs         命令行批量模式
tests/golden.rs    黄金对照测试
verify/            原版参考数据生成脚本与性能基准
```

## License

随本项目（仓库根）整体分发；原版 Pixel-Art-Lighter 的算法归其作者所有，
本移植仅作内部素材管线用途。
