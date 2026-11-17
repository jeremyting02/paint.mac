using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

internal static class PaintNETCapture
{
    private const ushort Control = 0x11;
    private const ushort Shift = 0x10;
    private const ushort Enter = 0x0d;
    private const int FileNameEdit = 0x480;
    private const int OK = 1;
    private const uint WindowOwner = 4;
    private const uint SetTextMessage = 0x000c;
    private const uint CommandMessage = 0x0111;

    private delegate bool WindowCallback(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr window);
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("user32.dll")] private static extern IntPtr SetActiveWindow(IntPtr window);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, IntPtr process);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll")] private static extern IntPtr GetDlgItem(IntPtr dialog, int id);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(
        IntPtr window, StringBuilder name, int capacity);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(
        IntPtr window, StringBuilder text, int capacity);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr SendMessageTimeout(
        IntPtr window, uint message, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] private static extern bool PostMessage(
        IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(
        uint count, Input[] inputs, int size);

    // Win32 INPUT is a tagged union. The mouse member supplies the union size
    // and alignment even though the runner sends keyboard input only.
    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int X, Y;
        public uint Data, Flags, Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort Key, ScanCode;
        public uint Flags, Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputData
    {
        [FieldOffset(0)] public MouseInput Mouse;
        [FieldOffset(0)] public KeyboardInput Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputData Data;
    }

    private static string Title(IntPtr window)
    {
        var title = new StringBuilder(1024);
        GetWindowText(window, title, title.Capacity);
        return title.ToString();
    }

    private static IntPtr FindWindow(Func<IntPtr, bool> matches)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr unused) {
            if (!IsWindowVisible(window) || !IsWindowEnabled(window) || !matches(window)) return true;
            found = window;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    private static void WaitFor(string description, Func<bool> ready)
    {
        var timer = Stopwatch.StartNew();
        do
        {
            if (ready()) return;
            Thread.Sleep(50);
        } while (timer.Elapsed < TimeSpan.FromSeconds(20));

        throw new InvalidOperationException(
            "Timed out waiting for " + description + ". Foreground window: " + Title(GetForegroundWindow()));
    }

    private static IntPtr WaitForDialog(IntPtr editor, string title)
    {
        IntPtr dialog = IntPtr.Zero;
        WaitFor("the " + title + " dialog", delegate {
            dialog = FindWindow(window => GetWindow(window, WindowOwner) == editor && Title(window) == title);
            return dialog != IntPtr.Zero;
        });
        return dialog;
    }

    private static IntPtr WaitForFileDialog(IntPtr editor, string description)
    {
        IntPtr dialog = IntPtr.Zero;
        WaitFor(description, delegate {
            dialog = FindWindow(window => {
                // Wine's common file dialogs can have an empty window title.
                var type = new StringBuilder(32);
                GetClassName(window, type, type.Capacity);
                return GetWindow(window, WindowOwner) == editor && type.ToString() == "#32770" &&
                       GetDlgItem(window, FileNameEdit) != IntPtr.Zero && GetDlgItem(window, OK) != IntPtr.Zero;
            });
            return dialog != IntPtr.Zero;
        });
        return dialog;
    }

    private static void Focus(IntPtr window)
    {
        if (!IsWindowEnabled(window)) throw new InvalidOperationException("Window is disabled: " + Title(window));
        if (IsIconic(window)) ShowWindow(window, 9); // SW_RESTORE
        if (GetForegroundWindow() != window)
        {
            uint target = GetWindowThreadProcessId(window, IntPtr.Zero);
            // Keep the shared input queue for the life of the helper. Detaching
            // here can clear the foreground window before Wine handles input.
            AttachThreadInput(GetCurrentThreadId(), target, true);
            BringWindowToTop(window);
            SetActiveWindow(window);
            SetForegroundWindow(window);
        }
        WaitFor("focus on " + Title(window), () => GetForegroundWindow() == window);
    }

    private static Input Key(ushort key, uint flags)
    {
        return new Input {
            Type = 1, // INPUT_KEYBOARD
            Data = new InputData { Keyboard = new KeyboardInput { Key = key, Flags = flags } }
        };
    }

    private static void Send(IntPtr window, Input[] inputs)
    {
        if (GetForegroundWindow() != window || !IsWindowEnabled(window))
            throw new InvalidOperationException("Focus changed before sending input to " + Title(window));
        if (SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(Input))) != inputs.Length)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "SendInput failed");
    }

    private static void Chord(IntPtr window, params ushort[] keys)
    {
        var inputs = new Input[keys.Length * 2];
        for (int i = 0; i < keys.Length; i++)
        {
            inputs[i] = Key(keys[i], 0);
            inputs[inputs.Length - i - 1] = Key(keys[i], 2); // KEYEVENTF_KEYUP
        }
        Send(window, inputs);
    }

    private static void SubmitPath(IntPtr dialog, string path)
    {
        IntPtr edit = GetDlgItem(dialog, FileNameEdit);
        IntPtr result;
        // WM_SETTEXT targets the filename field. WM_COMMAND/IDOK submits the
        // dialog asynchronously so its PNG options modal can open afterward.
        if (SendMessageTimeout(edit, SetTextMessage, IntPtr.Zero, path, 2, 2000, out result) == IntPtr.Zero ||
            result == IntPtr.Zero || !PostMessage(dialog, CommandMessage, (IntPtr)OK, GetDlgItem(dialog, OK)))
            throw new IOException("Could not submit " + path + " to the file dialog.");
    }

    private static bool ShowsDocument(IntPtr editor, string path)
    {
        return Title(editor).TrimStart('*').StartsWith(Path.GetFileName(path) + " - Paint.NET 5.2",
            StringComparison.OrdinalIgnoreCase);
    }

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length != 3) throw new ArgumentException("Expected operation, staging input and staging output.");
            bool ownsCapture;
            using (var mutex = new Mutex(true, @"Local\paint.mac.PaintNETCapture", out ownsCapture))
            {
                if (!ownsCapture) throw new InvalidOperationException("Another Paint.NET capture is running.");
                try { Capture(args[0], args[1], args[2]); }
                finally { mutex.ReleaseMutex(); }
            }
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("Paint.NET capture: " + error.Message);
            return 1;
        }
    }

    private static void Capture(string operation, string source, string output)
    {
        ushort shortcut;
        switch (operation)
        {
            case "black-and-white": shortcut = 'G'; break;
            case "invert-colors": shortcut = 'I'; break;
            default: throw new ArgumentException("Unknown operation: " + operation);
        }
        if (!File.Exists(source) || File.Exists(output)) throw new IOException("Invalid staging paths.");

        IntPtr editor = FindWindow(window => Title(window).Contains("Paint.NET 5.2 ("));
        if (editor == IntPtr.Zero)
            throw new InvalidOperationException("Open Paint.NET 5.2 in this Wine prefix and dismiss any modal dialog.");
        Console.WriteLine("Using " + Title(editor));
        Focus(editor);
        Chord(editor, Control, 'O');
        SubmitPath(WaitForFileDialog(editor, "the Open dialog"), source);
        WaitFor("the staged input in Paint.NET", () => ShowsDocument(editor, source) && IsWindowEnabled(editor));

        DocumentChord(editor, source, Control, Shift, shortcut);
        WaitFor("the adjustment to mark the staged input edited",
            () => ShowsDocument(editor, source) && Title(editor).StartsWith("*") && IsWindowEnabled(editor));

        DocumentChord(editor, source, Control, Shift, 'S');
        SubmitPath(WaitForFileDialog(editor, "the Save As dialog"), output);
        IntPtr config = WaitForDialog(editor, "Save Options");
        Focus(config);
        Chord(config, Enter);
        WaitFor("the saved PNG", () => ShowsDocument(editor, output) && IsWindowEnabled(editor) && File.Exists(output));

        DocumentChord(editor, output, Control, 'W');
        WaitFor("the staged tab to close", () => !ShowsDocument(editor, output));
    }

    private static void DocumentChord(IntPtr editor, string path, params ushort[] keys)
    {
        Focus(editor);
        if (!ShowsDocument(editor, path))
            throw new InvalidOperationException("The active tab changed before sending the command.");
        Chord(editor, keys);
    }
}
