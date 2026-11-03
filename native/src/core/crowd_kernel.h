/*
 * crowd_kernel.h — 纯 C++ 内核（不依赖 Godot、不依赖 Windows）。
 *
 * 这一层存在的意义：它是可以被单测、被工具、被别的引擎复用的"算法层"。
 * 上层（GDExtension 绑定 / C# P/Invoke）只做数据搬运，业务逻辑一律留在这里。
 *
 * 为什么先做群体分离：现有 GDScript 版在 1 万只怪时分离一遍要 1.2 秒/次
 * （ai_controller 里靠 `count < 500` 的品质闸门降级才保住帧率）。这段逻辑是纯数值计算、
 * 无引擎依赖，是迁移到 C++ 收益最大、风险最小的一块——正好作为架构验证的第一个模块。
 */
#ifndef QY_CROWD_KERNEL_H
#define QY_CROWD_KERNEL_H

#include <stdint.h>

#include "qy_native_api.h"

namespace qy {

/*
 * 群体分离（单线程）。
 *   pos  : 长度 desc.count 的坐标（x,y 紧凑）
 *   out_dx/out_dy : 长度 desc.count 的输出（调用方分配；内核不清零，直接覆盖）
 *   out_hits : 可选，长度 desc.count
 * 返回值：无。非法输入（空指针 / count<=0）直接返回，输出保持原样。
 */
void crowd_separation(const qy_vec2 *pos, const qy_crowd_desc &desc,
                      float *out_dx, float *out_dy, int32_t *out_hits);

/*
 * 多线程版。workers<=1 退化为单线程；workers>1 时按区间切分并行计算。
 * 注意：网格构建仍是单线程（O(n)），并行的是 O(n·k) 的邻居查询 —— 这才是热点。
 */
void crowd_separation_mt(const qy_vec2 *pos, const qy_crowd_desc &desc,
                         float *out_dx, float *out_dy, int32_t *out_hits, int workers);

}  // namespace qy

#endif  // QY_CROWD_KERNEL_H
