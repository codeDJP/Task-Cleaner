param(
    [switch]$WhatIf,
    [switch]$NoPopup,
    [switch]$Quiet
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$iconPngPath = (Join-Path $scriptDir "icon.png").Replace('\', '/')
$iconIcoPath = (Join-Path $scriptDir "icon.ico").Replace('\', '/')

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Win32 API detector type for Taskbar / Active Screen Windows
if (-not ([System.Management.Automation.PSTypeName]'TaskbarDetector').Type) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public class TaskbarDetector {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr OpenDesktop(string lpszDesktop, uint dwFlags, bool fInherit, uint dwDesiredAccess);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool CloseDesktop(IntPtr hDesktop);

    public delegate bool EnumDesktopWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool EnumDesktopWindows(IntPtr hDesktop, EnumDesktopWindowsProc lpfn, IntPtr lParam);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out bool pvAttribute, int cbAttribute);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public const int DWMWA_CLOAKED = 14;
    public const int GWL_EXSTYLE = -20;
    public const uint WS_EX_TOOLWINDOW = 0x00000080;
    public const uint WS_EX_APPWINDOW = 0x00040000;
    public const uint GW_OWNER = 4;

    public class WinItem {
        public uint Pid;
        public string Title;
        public bool IsIconic;
    }

    private static void CheckHwnd(IntPtr hWnd, List<WinItem> list, HashSet<uint> seenPids, uint currentPid) {
        if (!IsWindowVisible(hWnd)) return;

        int len = GetWindowTextLength(hWnd);
        if (len == 0) return;

        StringBuilder sb = new StringBuilder(len + 1);
        GetWindowText(hWnd, sb, sb.Capacity);
        string title = sb.ToString().Trim();
        if (string.IsNullOrEmpty(title)) return;

        if (title == "Program Manager" || title == "Windows Input Experience" || title == "Background Process Killer" || title == "Safe Background Task Killer") return;

        bool cloaked = false;
        DwmGetWindowAttribute(hWnd, DWMWA_CLOAKED, out cloaked, sizeof(bool));
        if (cloaked) return;

        int exStyle = GetWindowLong(hWnd, GWL_EXSTYLE);
        bool isTool = (exStyle & (int)WS_EX_TOOLWINDOW) != 0;
        bool isApp = (exStyle & (int)WS_EX_APPWINDOW) != 0;

        if (isTool && !isApp) return;

        IntPtr owner = GetWindow(hWnd, GW_OWNER);
        if (owner != IntPtr.Zero && !isApp) return;

        bool isIconic = IsIconic(hWnd);

        RECT rect;
        GetWindowRect(hWnd, out rect);
        int width = rect.Right - rect.Left;
        int height = rect.Bottom - rect.Top;

        if (isIconic || (width > 50 && height > 50)) {
            uint pid = 0;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid > 0 && pid != currentPid && !seenPids.Contains(pid)) {
                seenPids.Add(pid);
                list.Add(new WinItem { Pid = pid, Title = title, IsIconic = isIconic });
            }
        }
    }

    public static List<WinItem> GetTaskbarWindows() {
        var list = new List<WinItem>();
        var seenPids = new HashSet<uint>();
        uint currentPid = (uint)System.Diagnostics.Process.GetCurrentProcess().Id;

        IntPtr hDesk = OpenDesktop("Default", 0, false, 0x0100 | 0x0040 | 0x0001);
        if (hDesk != IntPtr.Zero) {
            EnumDesktopWindows(hDesk, (hWnd, lParam) => {
                CheckHwnd(hWnd, list, seenPids, currentPid);
                return true;
            }, IntPtr.Zero);
            CloseDesktop(hDesk);
        } else {
            EnumWindows((hWnd, lParam) => {
                CheckHwnd(hWnd, list, seenPids, currentPid);
                return true;
            }, IntPtr.Zero);
        }

        return list;
    }
}
"@
}

# 1. Detect open taskbar windows
$taskbarWins = [TaskbarDetector]::GetTaskbarWindows()
$safeProcNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$protectedAppDetails = @()

foreach ($w in $taskbarWins) {
    try {
        $proc = Get-Process -Id $w.Pid -ErrorAction SilentlyContinue
        if ($proc) {
            $pname = $proc.ProcessName
            if ($pname -in @("powershell", "pwsh", "cmd", "conhost")) { continue }

            [void]$safeProcNames.Add($pname)
            $protectedAppDetails += [PSCustomObject]@{
                ProcessName = $pname
                Title = $w.Title
                Id = $proc.Id
            }
        }
    } catch {}
}

# Core system essentials to protect OS stability
$coreOSWhitelist = @(
    "System", "Idle", "Registry", "smss", "csrss", "wininit", "services", "lsass", "winlogon",
    "fontdrvhost", "dwm", "sihost", "explorer", "svchost", "taskhostw",
    "MsMpEng", "MpDefenderCoreService", "SecurityHealthService", "smartscreen",
    "audiodg", "ctfmon", "TextInputHost",
    "nvcontainer", "NVDisplay.Container", "atieclxx", "AudioCaptureService", "amdpmfservice", "amdpmfserviceuser",
    "StartMenuExperienceHost", "ShellExperienceHost", "RuntimeBroker",
    "powershell", "pwsh", "cmd", "conhost", "Antigravity IDE", "bash", "wsl", "git", "python", "pythonw", "Code", "language_server_windows_x64",
    "DAX3API", "GameInputRedistService", "GameInputSvc", "Gbt.GpuPowerGear.Proxy", "Gbt.GpuPowerGear.Service"
)

foreach ($item in $coreOSWhitelist) { [void]$safeProcNames.Add($item) }
# Extra never-kill names from targets.json ("whitelistProcesses")
try {
    $configFile = Join-Path $scriptDir "targets.json"
    if (Test-Path $configFile) { foreach ($item in @((Get-Content -Raw -Path $configFile | ConvertFrom-Json).whitelistProcesses)) { if ($item) { [void]$safeProcNames.Add([string]$item) } } }
} catch {}
$userSession = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
[void]$safeProcNames.Add([System.Diagnostics.Process]::GetCurrentProcess().ProcessName)
[void]$safeProcNames.Add("powershell")
[void]$safeProcNames.Add("conhost")

# 2. NO MERCY: Target ANY process in user session or background bloat that is NOT in $safeProcNames
$toKill = @()
$killedSummary = @{}
$totalBytesFreed = 0

Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
    $proc = $_
    $pname = $proc.ProcessName

    if ($safeProcNames.Contains($pname)) { return }

    $isBloat = ($proc.SessionId -eq $userSession) -or 
               ($pname -like "*razer*") -or 
               ($pname -like "*rz*") -or 
               ($pname -like "*office*") -or 
               ($pname -like "*click*") -or 
               ($pname -like "*gbt*") -or 
               ($pname -like "*gimate*")

    if ($isBloat) {
        $toKill += $proc
    }
}

# 3. Stop Services if Admin
$servicesToStop = @(
    "ClickToRunSvc",
    "Razer Chroma SDK Diagnostic Service",
    "Razer Chroma SDK Server",
    "Razer Chroma SDK Service",
    "Razer Chroma Stream Server",
    "Razer Elevation Service",
    "Razer Game Manager Service 3",
    "RazerExperienceService",
    "RGS",
    "GiMATEService",
    "GprocSrvc"
)

if ($isAdmin -and -not $WhatIf) {
    foreach ($svc in $servicesToStop) {
        try { 
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue 
            & sc.exe stop $svc 2>$null | Out-Null
        } catch {}
    }
}

# 4. Terminate processes
$killedCount = 0
$targetNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($proc in $toKill) {
    $name = $proc.ProcessName
    $ws = 0
    try { $ws = $proc.WorkingSet64 } catch {}
    $totalBytesFreed += $ws

    if (-not $killedSummary.ContainsKey($name)) {
        $killedSummary[$name] = [PSCustomObject]@{ Count = 0; Bytes = 0 }
    }
    $killedSummary[$name].Count++
    $killedSummary[$name].Bytes += $ws
    [void]$targetNames.Add($name)

    if (-not $WhatIf) {
        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            $killedCount++
        } catch {}
        try {
            & taskkill.exe /F /PID $proc.Id /T 2>$null | Out-Null
        } catch {}
    } else {
        $killedCount++
    }
}

# Force kill process trees by name
if (-not $WhatIf) {
    if ($targetNames.Contains("msedgewebview2") -or $targetNames.Contains("SearchHost")) {
        try { & taskkill.exe /F /IM "SearchHost.exe" /T 2>$null | Out-Null } catch {}
        try { & taskkill.exe /F /IM "msedgewebview2.exe" /T 2>$null | Out-Null } catch {}
    }

    foreach ($tname in $targetNames) {
        try {
            & taskkill.exe /F /IM "$tname.exe" /T 2>$null | Out-Null
        } catch {}
    }

    if (-not $safeProcNames.Contains("msedge")) {
        try { & taskkill.exe /F /IM "msedge.exe" /T 2>$null | Out-Null } catch {}
    }
}

$mbFreed = [math]::Round($totalBytesFreed / 1MB, 1)
$gbFreed = [math]::Round($totalBytesFreed / 1GB, 2)
$freedText = if ($gbFreed -ge 1.0) { "$gbFreed GB" } else { "$mbFreed MB" }

# Formulate summary messages
$killedAppsList = @()
foreach ($key in ($killedSummary.Keys | Sort-Object)) {
    $killedAppsList += "$key ($($killedSummary[$key].Count))"
}
$killedAppsStr = if ($killedAppsList.Count -gt 0) { $killedAppsList -join ", " } else { "None" }

$uniqueVisibleApps = ($protectedAppDetails | Select-Object -ExpandProperty ProcessName -Unique) -join ", "
if ([string]::IsNullOrWhiteSpace($uniqueVisibleApps)) { $uniqueVisibleApps = "None detected" }

# Console output
if (-not $Quiet) {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "   NO-MERCY BACKGROUND PROCESS CLEANUP" -ForegroundColor White
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "[PROTECTED] Taskbar Windows:   " -NoNewline -ForegroundColor Green
    Write-Host $uniqueVisibleApps -ForegroundColor White
    Write-Host "[TERMINATED] Background Targets:" -NoNewline -ForegroundColor Yellow
    Write-Host $killedAppsStr -ForegroundColor White
    Write-Host "[RECLAIMED] Total RAM Freed:   " -NoNewline -ForegroundColor Green
    Write-Host "$freedText ($killedCount process instances)" -ForegroundColor White
    Write-Host "==========================================`n" -ForegroundColor Cyan
}

# 5. Display a Liquid Glass notification (macOS Tahoe style) unless -NoPopup is specified
if (-not $NoPopup) {
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml -ErrorAction SilentlyContinue

        # Liquid Glass engine shared with the dashboard (compiled once into %LOCALAPPDATA%\ProcessPurge)
        if (-not ('LiquidGlass.GlassSurface' -as [type])) {
            $engineSources = @(Join-Path $scriptDir "LiquidGlass.cs")
            $engineRefs = @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml')
            try {
                $engineHash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash(
                    [System.Text.Encoding]::UTF8.GetBytes((($engineSources | ForEach-Object { [System.IO.File]::ReadAllText($_) }) -join "`n")))).Replace('-', '').Substring(0, 16)
                $engineCache = Join-Path $env:LOCALAPPDATA "ProcessPurge"
                $engineDll = Join-Path $engineCache "LiquidGlass.$engineHash.dll"
                if (-not (Test-Path $engineDll)) {
                    New-Item -ItemType Directory -Path $engineCache -Force | Out-Null
                    Add-Type -Path $engineSources -ReferencedAssemblies $engineRefs -OutputAssembly $engineDll -OutputType Library
                }
                if (-not ('LiquidGlass.GlassSurface' -as [type])) { Add-Type -Path $engineDll }
            } catch {}
            if (-not ('LiquidGlass.GlassSurface' -as [type])) {
                Add-Type -Path $engineSources -ReferencedAssemblies $engineRefs
            }
        }
        $light = $false
        try { $light = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 1 } catch {}
        $t = if ($light) {
            @{ Label = '#D9000000'; Secondary = '#80000000'; Tint = '#B3F5F6FA'; Sheen = '#59FFFFFF'; RimHi = '#F2FFFFFF'; RimMid = '#40FFFFFF'; RimLo = '#99FFFFFF'; CloseBg = '#F2FFFFFF'; Green = '#34C759'; Red = '#FF383C' }
        } else {
            @{ Label = '#F2FFFFFF'; Secondary = '#A6FFFFFF'; Tint = '#A615161B'; Sheen = '#1AFFFFFF'; RimHi = '#8CFFFFFF'; RimMid = '#14FFFFFF'; RimLo = '#40FFFFFF'; CloseBg = '#F23A3B40'; Green = '#30D158'; Red = '#FF4245' }
        }

        $dot = [string][char]0x00B7
        $noun = if ($killedCount -eq 1) { 'process' } else { 'processes' }
        if ($WhatIf) {
            $cardTitle = "Ready to Free $freedText"
            $mainMessage = "Simulation $dot $killedCount background $noun would be closed."
        } elseif ($killedCount -gt 0) {
            $cardTitle = "Freed $freedText"
            $mainMessage = "Closed $killedCount background $noun."
        } else {
            $cardTitle = "All Clear"
            $mainMessage = "No unnecessary background apps are running."
        }

        $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:lg="clr-namespace:LiquidGlass;assembly=__ASM__"
        Title="Safe Background Task Killer - Notification" Width="380" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" WindowStartupLocation="Manual" UseLayoutRounding="True"
        FontFamily="SF Pro Text, Segoe UI Variable Text, Segoe UI" TextOptions.TextFormattingMode="Ideal">
    <Grid x:Name="Root" RenderTransformOrigin="1,0">
        <Grid.RenderTransform>
            <TransformGroup>
                <ScaleTransform x:Name="Scale"/>
                <TranslateTransform x:Name="Shift"/>
            </TransformGroup>
        </Grid.RenderTransform>

        <!-- Clear Liquid Glass card: whatever is behind it shows through -->
        <Grid x:Name="Card">
            <Border CornerRadius="8" Background="__Tint__"/>
            <Border CornerRadius="8" IsHitTestVisible="False">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                        <GradientStop Color="__Sheen__" Offset="0"/>
                        <GradientStop Color="#00FFFFFF" Offset="0.5"/>
                    </LinearGradientBrush>
                </Border.Background>
            </Border>
            <Border CornerRadius="8" IsHitTestVisible="False" BorderThickness="1.2">
                <Border.BorderBrush>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="0.7,1">
                        <GradientStop Color="__RimHi__" Offset="0"/>
                        <GradientStop Color="__RimMid__" Offset="0.45"/>
                        <GradientStop Color="__RimLo__" Offset="1"/>
                    </LinearGradientBrush>
                </Border.BorderBrush>
            </Border>
            <Grid Margin="14,13,16,14">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border x:Name="AppIcon" Width="38" Height="38" CornerRadius="9" VerticalAlignment="Top" Margin="0,1,12,0">
                    <Border.Effect><DropShadowEffect BlurRadius="6" ShadowDepth="1" Direction="270" Opacity="0.3"/></Border.Effect>
                </Border>
                <StackPanel Grid.Column="1">
                    <Grid>
                        <TextBlock x:Name="TxtTitle" FontSize="13" FontWeight="SemiBold" Foreground="__Label__" Margin="0,0,40,0" TextTrimming="CharacterEllipsis"/>
                        <TextBlock Text="now" FontSize="11" Foreground="__Secondary__" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,1,0,0"/>
                    </Grid>
                    <TextBlock x:Name="TxtBody" FontSize="13" Foreground="__Label__" Margin="0,1,0,0" TextWrapping="Wrap"/>
                    <TextBlock FontSize="11.5" Foreground="__Secondary__" Margin="0,6,0,0" TextTrimming="CharacterEllipsis">
                        <Run Text="Closed " Foreground="__Red__" FontWeight="SemiBold"/><Run x:Name="RunClosed"/>
                    </TextBlock>
                    <TextBlock FontSize="11.5" Foreground="__Secondary__" Margin="0,2,0,0" TextTrimming="CharacterEllipsis">
                        <Run Text="Protected " Foreground="__Green__" FontWeight="SemiBold"/><Run x:Name="RunProtected"/>
                    </TextBlock>
                </StackPanel>
            </Grid>
        </Grid>

        <!-- macOS reveals the close button on hover, at the card's top-left corner -->
        <Border x:Name="CloseBtn" Width="20" Height="20" CornerRadius="10" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="5,5,0,0"
                Background="__CloseBg__" Opacity="0">
            <Border.Effect><DropShadowEffect BlurRadius="6" ShadowDepth="1" Direction="270" Opacity="0.3"/></Border.Effect>
            <Path Data="M0,0 L6,6 M6,0 L0,6" Stroke="__Secondary__" StrokeThickness="1.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                  HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
    </Grid>
</Window>
'@
        $xaml = $xaml.Replace('__ASM__', [LiquidGlass.GlassSurface].Assembly.GetName().Name)
        foreach ($key in $t.Keys) { $xaml = $xaml.Replace("__$($key)__", $t[$key]) }

        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $window = [System.Windows.Markup.XamlReader]::Load($reader)
        $root = $window.FindName("Root")
        $scale = $window.FindName("Scale")
        $shift = $window.FindName("Shift")
        $closeButton = $window.FindName("CloseBtn")
        $window.FindName("TxtTitle").Text = $cardTitle
        $window.FindName("TxtBody").Text = $mainMessage
        $window.FindName("RunClosed").Text = $killedAppsStr
        $window.FindName("RunProtected").Text = $uniqueVisibleApps

        try {
            $iconBitmap = [System.Windows.Media.Imaging.BitmapImage]::new()
            $iconBitmap.BeginInit()
            $iconBitmap.CacheOption = 'OnLoad'
            $iconBitmap.DecodePixelWidth = 256
            $iconBitmap.UriSource = [Uri]$iconPngPath
            $iconBitmap.EndInit()
            $iconBitmap.Freeze()
            $iconBrush = [System.Windows.Media.ImageBrush]::new($iconBitmap)
            [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($iconBrush, 'HighQuality')
            $window.FindName("AppIcon").Background = $iconBrush
        } catch {}

        # Top-right of the work area, like a macOS notification
        $screen = [System.Windows.SystemParameters]::WorkArea
        $window.Left = $screen.Right - $window.Width - 12
        $window.Top = $screen.Top + 12

        $window.Add_SourceInitialized({
            $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
            [LiquidGlass.Native]::RoundDwmCorners($hwnd)
            [void][LiquidGlass.Native]::EnableBlurBehind($hwnd)
        })

        $script:Dismissing = $false
        function Hide-Notification {
            if ($script:Dismissing) { return }
            $script:Dismissing = $true
            [LiquidGlass.Motion]::Ease($root, [System.Windows.UIElement]::OpacityProperty, 0, 200)
            $done = [System.Windows.Threading.DispatcherTimer]::new()
            $done.Interval = [TimeSpan]::FromMilliseconds(250)
            $done.Add_Tick({ $window.Close() })
            $done.Start()
        }

        # Fade in over the blurred glass pane
        $root.Opacity = 0
        $window.Add_ContentRendered({
            [LiquidGlass.Motion]::Ease($root, [System.Windows.UIElement]::OpacityProperty, 1, 200)
        })

        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromSeconds(4.5)
        $timer.Add_Tick({
            $timer.Stop()
            Hide-Notification
        })
        $timer.Start()

        # Hovering keeps the notification on screen and reveals the close button; any click dismisses it
        $window.Add_MouseEnter({ $timer.Stop(); [LiquidGlass.Motion]::Ease($closeButton, [System.Windows.UIElement]::OpacityProperty, 1, 120) })
        $window.Add_MouseLeave({ [LiquidGlass.Motion]::Ease($closeButton, [System.Windows.UIElement]::OpacityProperty, 0, 200); $timer.Start() })
        $window.Add_MouseDown({ Hide-Notification })

        $window.ShowDialog() | Out-Null
    } catch {
        # Fallback if GUI subsystem cannot render
    }
}
