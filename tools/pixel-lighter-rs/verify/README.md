# verify/ —— 等价性验证素材

**`ref/` 是黄金测试的 fixture 数据（已入库），不要删。** `tests/golden.rs` 直接读它，
删掉后 `cargo test` 会全部失败（`os error 3`）。

## 目录内容

| 文件 | 作用 |
|---|---|
| `ref/*.raw` | 原版 JS 跑出来的参考像素，裸 RGBA（无头、无压缩），逐字节比对用 |
| `ref/cases.json` | 每个用例的参数（生成预设、开关、光照参数），Rust 侧按此复现 |
| `gen_ref.js` | 用 Node 跑**原版**函数产出上面的 `.raw`；从 HTML 里正则抽取 `renderPixels` 等函数 |
| `bench_js.js` | 原版 JS 的性能基准（和 `cargo run --release -- --bench` 对照） |

## 重新生成参考数据

原版来源（外部单文件 Web 工具，不入库）：

```
G:\Program Files (x86)\Tencent\1229037592\FileRecv\Pixel-Art-Lighter-v3.5.23.html
```

```bash
node verify/gen_ref.js "<上面那个 html 的路径>" verify/ref
# 输出：已生成参考数据 -> verify/ref / 文件: 24
```

只有改动 `gen_ref.js` 的用例集、或想换一张输入图时才需要重跑；平时直接用入库的 `ref/`。

## 词表

- `input_72x56.raw` —— 确定性生成的测试底图（72×56 裸 RGBA），两侧共用，避免依赖外部图片
- `normal_*` —— 13 项法线图生成
- `mask_*` —— 2 项光照遮罩生成
- `lit_*` —— 4 项打光合成
- `view_*` —— 3 项视图模式（底图 / 法线 / 遮罩）
- `bis_*` —— 二分定位用例（逐个开关隔离差异，排障时用；**改算法前先跑这几个能快速缩小范围**）
