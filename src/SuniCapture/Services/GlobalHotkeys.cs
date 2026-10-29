using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace SuniCapture.Services;

/// <summary>Owns only the four SuniCapture shortcuts, for the lifetime of its main window.</summary>
public sealed class GlobalHotkeys : IDisposable
{
    private const int FirstId = 0x5310;
    private readonly Window _owner;
    private readonly List<int> _registered = new();
    private HwndSource? _source;
    private nint _handle;
    private bool _disposed;

    public GlobalHotkeys(Window owner) => _owner = owner ?? throw new ArgumentNullException(nameof(owner));

    public event Action<int>? Pressed;

    public IReadOnlyList<string> Register()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_source != null) return Array.Empty<string>();
        _handle = new WindowInteropHelper(_owner).EnsureHandle();
        _source = HwndSource.FromHwnd(_handle);
        if (_source == null)
            return new[] { L.T("hotkey.unavailable") };
        _source.AddHook(WindowMessage);
        var warnings = new List<string>();
        for (int number = 1; number <= 4; number++)
        {
            int id = FirstId + number;
            if (RegisterHotKey(_handle, id, 0x0002 | 0x0004 | 0x4000, (uint)(0x30 + number)))
                _registered.Add(id);
            else
                warnings.Add(L.F("hotkey.conflict", number));
        }
        return warnings;
    }

    private nint WindowMessage(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == 0x0312)
        {
            int number = wParam.ToInt32() - FirstId;
            if (number >= 1 && number <= 4 && _registered.Contains(wParam.ToInt32()))
            {
                handled = true;
                Pressed?.Invoke(number);
            }
        }
        return 0;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        foreach (int id in _registered) UnregisterHotKey(_handle, id);
        _registered.Clear();
        _source?.RemoveHook(WindowMessage);
        _source = null;
        Pressed = null;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(nint window, int id, uint modifiers, uint key);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(nint window, int id);
}
