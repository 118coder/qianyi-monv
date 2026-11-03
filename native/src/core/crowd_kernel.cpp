#include "crowd_kernel.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <thread>
#include <unordered_map>
#include <vector>

namespace qy {
namespace {

constexpr float kMaxForce = 1.2f;      // 与 GDScript 版 limit_length(1.2) 对齐
constexpr float kTau = 6.28318530718f;

struct Grid {
    float cell = 32.0f;
    std::unordered_map<int64_t, std::vector<int32_t>> buckets;

    static inline int64_t key_of(int32_t cx, int32_t cy) {
        // 用无符号拼接，避免负数左移的未定义行为
        const uint64_t a = static_cast<uint32_t>(cx);
        const uint64_t b = static_cast<uint32_t>(cy);
        return static_cast<int64_t>((a << 32) | b);
    }

    inline int32_t cell_of(float v) const {
        return static_cast<int32_t>(std::floor(v / cell));
    }
};

/* 完全重叠时给一个确定性的方向：同一次调用内结果可复现（不依赖 rand，便于回放/对拍） */
inline void overlap_dir(int32_t i, int32_t j, float &ox, float &oy) {
    const uint32_t h = static_cast<uint32_t>(i) * 2654435761u + static_cast<uint32_t>(j) * 2246822519u;
    const float ang = static_cast<float>(h & 1023u) * (kTau / 1024.0f);
    ox = std::cos(ang);
    oy = std::sin(ang);
}

void build_grid(const qy_vec2 *pos, int32_t count, Grid &g) {
    g.buckets.clear();
    g.buckets.reserve(static_cast<size_t>(count) * 2u);
    for (int32_t i = 0; i < count; ++i) {
        const int32_t cx = g.cell_of(pos[i].x);
        const int32_t cy = g.cell_of(pos[i].y);
        g.buckets[Grid::key_of(cx, cy)].push_back(i);
    }
}

/* 单个个体的分离力（会被多线程调用，必须只读 pos/grid，只写自己的输出槽） */
void separation_one(const qy_vec2 *pos, int32_t i, const Grid &g, float r, float r2,
                    float strength, int32_t max_neighbors,
                    float &out_x, float &out_y, int32_t &out_hits) {
    const int32_t cx = g.cell_of(pos[i].x);
    const int32_t cy = g.cell_of(pos[i].y);
    float sx = 0.0f;
    float sy = 0.0f;
    int32_t hits = 0;

    for (int32_t ox = -1; ox <= 1; ++ox) {
        for (int32_t oy = -1; oy <= 1; ++oy) {
            const auto it = g.buckets.find(Grid::key_of(cx + ox, cy + oy));
            if (it == g.buckets.end()) {
                continue;
            }
            for (const int32_t j : it->second) {
                if (j == i) {
                    continue;
                }
                const float dx = pos[i].x - pos[j].x;
                const float dy = pos[i].y - pos[j].y;
                const float l2 = dx * dx + dy * dy;
                if (l2 >= r2) {
                    continue;
                }
                if (l2 <= 1e-8f) {
                    float px = 0.0f;
                    float py = 0.0f;
                    overlap_dir(i, j, px, py);
                    sx += px;
                    sy += py;
                } else {
                    const float l = std::sqrt(l2);
                    const float w = 1.0f - l / r;   // 线性弹簧：越近推得越狠
                    sx += (dx / l) * w;
                    sy += (dy / l) * w;
                }
                ++hits;
                if (max_neighbors > 0 && hits >= max_neighbors) {
                    out_x = sx * strength;
                    out_y = sy * strength;
                    out_hits = hits;
                    return;
                }
            }
        }
    }

    sx *= strength;
    sy *= strength;
    const float len2 = sx * sx + sy * sy;
    if (len2 > kMaxForce * kMaxForce) {
        const float inv = kMaxForce / std::sqrt(len2);
        sx *= inv;
        sy *= inv;
    }
    out_x = sx;
    out_y = sy;
    out_hits = hits;
}

inline void sanitize(const qy_crowd_desc &in, float &r, float &r2, float &strength, float &cell) {
    r = (in.radius > 0.0f) ? in.radius : 24.0f;
    r2 = r * r;
    strength = (in.strength != 0.0f) ? in.strength : 1.0f;
    cell = (in.cell_size > 0.0f) ? in.cell_size : (r * 2.0f);
}

}  // namespace

void crowd_separation(const qy_vec2 *pos, const qy_crowd_desc &desc,
                      float *out_dx, float *out_dy, int32_t *out_hits) {
    if (pos == nullptr || out_dx == nullptr || out_dy == nullptr || desc.count <= 0) {
        return;
    }
    float r = 0.0f;
    float r2 = 0.0f;
    float strength = 1.0f;
    float cell = 0.0f;
    sanitize(desc, r, r2, strength, cell);

    Grid g;
    g.cell = cell;
    build_grid(pos, desc.count, g);

    for (int32_t i = 0; i < desc.count; ++i) {
        int32_t hits = 0;
        separation_one(pos, i, g, r, r2, strength, desc.max_neighbors,
                       out_dx[i], out_dy[i], hits);
        if (out_hits != nullptr) {
            out_hits[i] = hits;
        }
    }
}

void crowd_separation_mt(const qy_vec2 *pos, const qy_crowd_desc &desc,
                         float *out_dx, float *out_dy, int32_t *out_hits, int workers) {
    if (workers <= 1 || desc.count < 512) {
        crowd_separation(pos, desc, out_dx, out_dy, out_hits);
        return;
    }
    if (pos == nullptr || out_dx == nullptr || out_dy == nullptr || desc.count <= 0) {
        return;
    }
    float r = 0.0f;
    float r2 = 0.0f;
    float strength = 1.0f;
    float cell = 0.0f;
    sanitize(desc, r, r2, strength, cell);

    Grid g;
    g.cell = cell;
    build_grid(pos, desc.count, g);   // 建表保持单线程：O(n)，并行收益为负

    const int n = std::max(1, std::min(workers, 32));
    const int32_t chunk = (desc.count + n - 1) / n;
    std::vector<std::thread> pool;
    pool.reserve(static_cast<size_t>(n));

    for (int t = 0; t < n; ++t) {
        const int32_t begin = t * chunk;
        const int32_t end = std::min(desc.count, begin + chunk);
        if (begin >= end) {
            break;
        }
        pool.emplace_back([&, begin, end]() {
            for (int32_t i = begin; i < end; ++i) {
                int32_t hits = 0;
                separation_one(pos, i, g, r, r2, strength, desc.max_neighbors,
                               out_dx[i], out_dy[i], hits);
                if (out_hits != nullptr) {
                    out_hits[i] = hits;
                }
            }
        });
    }
    for (auto &th : pool) {
        th.join();
    }
}

}  // namespace qy
