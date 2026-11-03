/*
 * qy_native_api.h — 引擎无关的 C ABI（本项目的唯一跨语言契约）
 *
 * 设计约束（改之前先读）：
 *  1. 这个头文件不允许出现任何 Godot / WebView2 / STL 类型，只有 C 的 POD。
 *     —— 它是 C++ 内核与 C#（P/Invoke）、GDScript（GDExtension）、外部工具之间唯一的 ABI。
 *  2. 只能**追加**，不能改字段顺序/类型：C# 侧的结构体是 LayoutKind.Sequential 硬对应的。
 *     语义不兼容时新开 qy_api_v2，并让 qy_get_api(v) 按版本返回；老版本继续可用。
 *  3. 名字以 qy_ 前缀，避免和引擎/第三方 DLL 符号撞名。
 *  4. 导出函数一律 extern "C"，异常不得穿过边界（内核里 catch 全部，返回错误码/空值）。
 */
#ifndef QY_NATIVE_API_H
#define QY_NATIVE_API_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#  define QY_API __declspec(dllexport)
#elif defined(__GNUC__)
#  define QY_API __attribute__((visibility("default")))
#else
#  define QY_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define QY_API_VERSION 1u

typedef struct qy_vec2 {
    float x;
    float y;
} qy_vec2;

/* 群体分离参数。cell_size 是空间哈希的格子边长（世界单位），建议 = radius * 2。 */
typedef struct qy_crowd_desc {
    int32_t count;        /* 个体数量，必须 > 0 */
    float   cell_size;    /* 哈希格边长，<=0 时内核按 radius*2 兜底 */
    float   radius;       /* 分离半径（个体间距），<=0 时用 24.0f 兜底 */
    float   strength;     /* 力的强度系数，1.0 = GDScript 版原行为 */
    int32_t max_neighbors;/* 每个个体最多考虑多少邻居，<=0 表示不限 */
} qy_crowd_desc;

/*
 * 函数指针表：跨 DLL 版本演进的唯一入口。
 * 调用方先 qy_get_api(QY_API_VERSION) 拿到表，再按字段调用 —— 这样内核加函数不会破坏老二进制。
 */
typedef struct qy_api_v1 {
    uint32_t version;

    /*
     * 群体分离（单线程）：对每个个体求「推开邻居」的合力。
     *   pos      : 长度 count 的坐标数组（x,y 交替，紧凑排列）
     *   out_dx   : 长度 count 的输出缓冲区（调用方分配，内核只写）
     *   out_dy   : 同上
     *   out_hits : 可选，长度 count；每个个体实际参与的邻居数。可传 NULL
     * 输出语义：单位方向加权和，长度上限 1.2（与 GDScript 版 friend_unit._separation 一致）。
     */
    void (*crowd_separation)(const qy_vec2 *pos, const qy_crowd_desc *desc,
                             float *out_dx, float *out_dy, int32_t *out_hits);

    /* 同上的多线程版。workers<=1 时等价于单线程。 */
    void (*crowd_separation_mt)(const qy_vec2 *pos, const qy_crowd_desc *desc,
                                float *out_dx, float *out_dy, int32_t *out_hits,
                                int32_t workers);

    /* 确定性 64 位哈希（FNV-1a 变体）：存档校验、按种子生成、资源内容寻址都用它 */
    uint64_t (*hash64)(const void *data, size_t len, uint64_t seed);

    /* 构建信息（"qy_native <版本> <git> <编译器>"），日志/问题定位用；返回静态字符串，勿释放 */
    const char *(*build_info)(void);
} qy_api_v1;

/* 返回本 DLL 支持的 API 版本（当前 = QY_API_VERSION） */
QY_API uint32_t qy_api_version(void);

/* 取函数表；min_version 高于本 DLL 支持时返回 NULL（调用方必须判空并降级） */
QY_API const qy_api_v1 *qy_get_api(uint32_t min_version);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* QY_NATIVE_API_H */
