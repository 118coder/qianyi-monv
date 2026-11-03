// NativeApi.cs — C# 直连 C++ 内核（P/Invoke + 函数指针表，零 Variant 封送）
//
// 为什么不用 GDScript 那条 GDExtension 通道：那条路每帧要把数组包成 PackedFloat32Array、
// 过一次 Variant 转换；万级个体时仅封送就吃掉几毫秒。C# 这边直接拿 Span<T> + fixed 指针，
// 只做一次"取指针"，内核原地读写。
//
// 安全边界：
//   · DLL 里的导出只有 qy_get_api / qy_api_version，其余全走函数表 —— 加函数不改 ABI；
//   · 传进去的指针生命周期只到本次调用返回（内核不得保存）；
//   · 所有长度由调用方保证一致，内核不越界读（它只按 desc.Count 走）。
using System;
using System.IO;
using System.Runtime.InteropServices;
using Godot;

namespace Qy.Bridge;

[StructLayout(LayoutKind.Sequential)]
public struct QyVec2
{
    public float X;
    public float Y;
}

[StructLayout(LayoutKind.Sequential)]
public struct QyCrowdDesc
{
    public int Count;
    public float CellSize;
    public float Radius;
    public float Strength;
    public int MaxNeighbors;
}

/// <summary>C 函数表镜像（必须与 native/include/qy_native_api.h 的 qy_api_v1 字段顺序一致）。</summary>
[StructLayout(LayoutKind.Sequential)]
public unsafe struct QyApiV1
{
    public uint Version;
    public delegate* unmanaged[Cdecl]<QyVec2*, QyCrowdDesc*, float*, float*, int*, void> CrowdSeparation;
    public delegate* unmanaged[Cdecl]<QyVec2*, QyCrowdDesc*, float*, float*, int*, int, void> CrowdSeparationMt;
    public delegate* unmanaged[Cdecl]<void*, nuint, ulong, ulong> Hash64;
    public delegate* unmanaged[Cdecl]<byte*> BuildInfo;
}

public static unsafe class NativeApi
{
    private const uint RequiredApiVersion = 1;

    private static IntPtr _lib;
    private static QyApiV1* _api;

    public static bool IsReady => _api != null;

    /// <summary>优先取 exe 同级（导出后），其次 res://，最后环境变量 QY_NATIVE_DLL。</summary>
    private static string[] Candidates()
    {
        const string dll = "qy_native.windows.debug.x86_64.dll";
        return new[]
        {
            Path.Combine(AppContext.BaseDirectory, dll),
            ProjectSettings.GlobalizePath("res://native/bin/" + dll),
            Environment.GetEnvironmentVariable("QY_NATIVE_DLL") ?? string.Empty,
        };
    }

    public static bool TryInitialize(out string error)
    {
        error = string.Empty;
        if (IsReady) return true;

        foreach (var path in Candidates())
        {
            if (string.IsNullOrEmpty(path) || !File.Exists(path)) continue;
            if (!NativeLibrary.TryLoad(path, out var lib))
            {
                error = $"加载失败（可能缺 VC 运行库或位数不符）：{path}";
                continue;
            }

            var getApiPtr = NativeLibrary.GetExport(lib, "qy_get_api");
            var getApi = (delegate* unmanaged[Cdecl]<uint, QyApiV1*>)getApiPtr;
            var api = getApi(RequiredApiVersion);
            if (api == null)
            {
                error = $"{path} 的 API 版本低于 {RequiredApiVersion}，需要重新编译 native";
                NativeLibrary.Free(lib);
                continue;
            }

            _lib = lib;
            _api = api;
            GD.Print($"[native] {path} · {BuildInfo()}");
            return true;
        }

        if (error.Length == 0) error = "未找到 qy_native DLL（先跑 tools/build_native.ps1）";
        return false;
    }

    public static string BuildInfo()
    {
        if (_api == null) return "<not loaded>";
        var p = _api->BuildInfo();
        return p == null ? "<null>" : Marshal.PtrToStringUTF8((IntPtr)p) ?? "<bad utf8>";
    }

    /// <summary>
    /// 群体分离。dx/dy 由调用方预分配并复用（不要每帧 new）。
    /// 一帧只应调用一次；返回值为实际处理的个体数。
    /// </summary>
    public static int Separation(ReadOnlySpan<QyVec2> pos, Span<float> dx, Span<float> dy,
                                 in QyCrowdDesc desc, int workers = 1, Span<int> hits = default)
    {
        if (_api == null || pos.IsEmpty) return 0;
        if (dx.Length < pos.Length || dy.Length < pos.Length)
            throw new ArgumentException("输出缓冲区太小");

        fixed (QyVec2* p = pos)
        fixed (float* px = dx)
        fixed (float* py = dy)
        fixed (int* ph = hits)
        {
            var d = desc;
            d.Count = pos.Length;
            if (workers > 1)
                _api->CrowdSeparationMt(p, &d, px, py, ph, workers);
            else
                _api->CrowdSeparation(p, &d, px, py, ph);
        }
        return pos.Length;
    }

    public static ulong Hash64(ReadOnlySpan<byte> data, ulong seed = 0)
    {
        if (_api == null || data.IsEmpty) return seed;
        fixed (byte* p = data)
        {
            return _api->Hash64(p, (nuint)data.Length, seed);
        }
    }
}
