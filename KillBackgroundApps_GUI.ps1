[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Self-elevate to Administrator if not already elevated (ensures Razer, Office, and background services can be stopped)
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and ($args -contains "-Elevate" -or -not ($args -contains "-NoAutoElevate"))) {
    try {
        $forwardArgs = @($args | Where-Object { $_ -ne "-Elevate" -and $_ -ne "-NoAutoElevate" }) -join ' '
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -NoAutoElevate $forwardArgs"
        $psi.Verb = "RunAs"
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        exit
    } catch {
        # User declined UAC, continue in standard mode
    }
}

# Options: -Theme Auto|Light|Dark   -WhatIf (simulate: nothing is terminated)
$ThemeOption = 'Auto'
$themeIndex = [Array]::IndexOf([string[]]@($args), '-Theme')
if ($themeIndex -ge 0 -and $themeIndex + 1 -lt $args.Count) { $ThemeOption = [string]$args[$themeIndex + 1] }
$SimulateOnly = $args -contains '-WhatIf'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml -ErrorAction SilentlyContinue

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFile = Join-Path $scriptDir "targets.json"
$iconPngPath = Join-Path $scriptDir "icon.png"
$iconIcoPath = (Join-Path $scriptDir "icon.ico").Replace('\', '/')

$Ellipsis = [string][char]0x2026
$Dot = [string][char]0x00B7

# Liquid Glass engine (LiquidGlass.cs). Compiled once per version into
# %LOCALAPPDATA%\ProcessPurge and reused, so launches stay fast.
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
# Win32 API detector type for Taskbar Windows & DWM Acrylic Blur
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

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
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

[void][LiquidGlass.Lens]::Initialize()

# Services to stop (Razer + Office + Gigabyte services)
$script:CurrentTargetsToKill = @()
$script:SafeProcNames = @()
$script:ServicesToStop = @(
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

# Core OS Kernel and Driver infrastructure: NEVER KILL TO PREVENT CRASH
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

# ---------------------------------------------------------------------------------------------------------------
# Background work (runs in a runspace pool so the glass UI never freezes). Logic mirrors the original synchronous
# Scan-Processes / Purge / Kill-SpecificProcess code exactly.
# ---------------------------------------------------------------------------------------------------------------
$ScanWork = {
    param($CoreWhitelist, $UserWhitelist)
    $userSession = [System.Diagnostics.Process]::GetCurrentProcess().SessionId

    # 1. Detect ALL windows currently open on the Taskbar or Desktop
    $taskbarWins = [TaskbarDetector]::GetTaskbarWindows()
    $safeProcNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $protectedList = [System.Collections.Generic.List[object]]::new()

    foreach ($w in $taskbarWins) {
        try {
            $proc = Get-Process -Id $w.Pid -ErrorAction SilentlyContinue
            if ($proc) {
                $pname = $proc.ProcessName
                if ($pname -in @("powershell", "pwsh", "conhost", "cmd")) { continue }

                [void]$safeProcNames.Add($pname)
                $protectedList.Add([PSCustomObject]@{
                    Name = $pname
                    Title = $w.Title
                    Id = $proc.Id
                })
            }
        } catch {}
    }

    # Add core OS infrastructure to safe set
    foreach ($item in $CoreWhitelist) {
        [void]$safeProcNames.Add($item)
    }
    foreach ($item in @($UserWhitelist)) {
        if ($item) { [void]$safeProcNames.Add([string]$item) }
    }
    [void]$safeProcNames.Add([System.Diagnostics.Process]::GetCurrentProcess().ProcessName)
    [void]$safeProcNames.Add("powershell")
    [void]$safeProcNames.Add("conhost")

    # 2. NO MERCY: Target ANY process in user session or background bloat that is NOT in $safeProcNames
    $targets = [System.Collections.Generic.List[object]]::new()
    $totalRamBytes = [long]0

    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $pname = $p.ProcessName

        # Skip if safe
        if ($safeProcNames.Contains($pname)) { continue }

        # Match: ANY process running in the user's session OR matching bloat/services in Session 0
        $isBloat = ($p.SessionId -eq $userSession) -or
                   ($pname -like "*razer*") -or
                   ($pname -like "*rz*") -or
                   ($pname -like "*office*") -or
                   ($pname -like "*click*") -or
                   ($pname -like "*gbt*") -or
                   ($pname -like "*gimate*")

        if ($isBloat) {
            $targets.Add($p)
            try { $totalRamBytes += $p.WorkingSet64 } catch {}
        }
    }

    # Presentation data: friendly names, image paths (for icons) and per-app totals
    $protectedGroups = @(foreach ($g in ($protectedList | Group-Object Name)) {
        $first = $g.Group[0]
        $path = [LiquidGlass.ProcInfo]::ImagePath([int]$first.Id)
        [PSCustomObject]@{ Name = $g.Name; Title = $first.Title; Path = $path; Friendly = [LiquidGlass.ProcInfo]::FriendlyName($path) }
    })

    $targetGroups = @(foreach ($g in ($targets | Group-Object ProcessName)) {
        $bytes = [long]0
        foreach ($p in $g.Group) { try { $bytes += $p.WorkingSet64 } catch {} }
        $path = $null
        foreach ($p in $g.Group) { $path = [LiquidGlass.ProcInfo]::ImagePath([int]$p.Id); if ($path) { break } }
        [PSCustomObject]@{ Name = $g.Name; Count = $g.Count; Bytes = $bytes; Path = $path; Friendly = [LiquidGlass.ProcInfo]::FriendlyName($path) }
    })

    @{
        Safe          = @($safeProcNames)
        Protected     = $protectedGroups
        Targets       = $targets.ToArray()
        TargetGroups  = @($targetGroups | Sort-Object -Property Bytes -Descending)
        TotalBytes    = $totalRamBytes
        PhysicalBytes = [LiquidGlass.Native]::TotalPhysicalMemory()
    }
}

# Purge Action: NO MERCY WITH SUPERVISOR TERMINATION
$PurgeWork = {
    param($Targets, $Services, $IsAdmin, $SafeNames, $WhatIf)
    $killedCount = 0
    $bytesFreed = [long]0

    if ($WhatIf) {
        foreach ($t in $Targets) { $bytesFreed += $t.WorkingSet; $killedCount++ }
        return @{ Killed = $killedCount; Bytes = $bytesFreed }
    }

    # 1. Stop background services if Admin
    if ($IsAdmin) {
        foreach ($svc in $Services) {
            try {
                Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
                & sc.exe stop $svc 2>$null | Out-Null
            } catch {}
        }
    }

    # 2. Terminate all target background processes
    $targetNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($proc in $Targets) {
        try {
            $bytesFreed += $proc.WorkingSet
            [void]$targetNames.Add($proc.Name)
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            $killedCount++
        } catch {}
        try {
            & taskkill.exe /F /PID $proc.Id /T 2>$null | Out-Null
        } catch {}
    }

    # 3. Terminate SearchHost first if msedgewebview2 is targeted to stop instant resurrection
    if ($targetNames.Contains("msedgewebview2") -or $targetNames.Contains("SearchHost")) {
        try { & taskkill.exe /F /IM "SearchHost.exe" /T 2>$null | Out-Null } catch {}
        try { & taskkill.exe /F /IM "msedgewebview2.exe" /T 2>$null | Out-Null } catch {}
    }

    # 4. Kill all matching process trees by Image Name
    foreach ($tname in $targetNames) {
        try {
            & taskkill.exe /F /IM "$tname.exe" /T 2>$null | Out-Null
        } catch {}
    }

    # 5. Clean up any lingering background msedge instances if Edge has no active taskbar window
    $safeSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($SafeNames), [System.StringComparer]::OrdinalIgnoreCase)
    if (-not $safeSet.Contains("msedge")) {
        try { & taskkill.exe /F /IM "msedge.exe" /T 2>$null | Out-Null } catch {}
    }

    @{ Killed = $killedCount; Bytes = $bytesFreed }
}

$KillWork = {
    param($Name, $WhatIf)
    $killed = 0
    if ($WhatIf) {
        $killed = @(Get-Process -Name $Name -ErrorAction SilentlyContinue).Count
        return @{ Name = $Name; Killed = $killed }
    }

    # Supervisor termination for Edge webview / SearchHost
    if ($Name -eq "msedgewebview2" -or $Name -eq "SearchHost") {
        try { & taskkill.exe /F /IM "SearchHost.exe" /T 2>$null | Out-Null } catch {}
        try { & taskkill.exe /F /IM "msedgewebview2.exe" /T 2>$null | Out-Null } catch {}
    }

    Get-Process -Name $Name -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            $killed++
        } catch {}
    }
    try {
        & taskkill.exe /F /IM "$Name.exe" /T 2>$null | Out-Null
    } catch {}

    @{ Name = $Name; Killed = $killed }
}

$script:Pool = [runspacefactory]::CreateRunspacePool(1, 3)
$script:Pool.ApartmentState = 'STA'
$script:Pool.Open()

function Invoke-Async([scriptblock]$Work, [hashtable]$Arguments, [scriptblock]$Done) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:Pool
    [void]$ps.AddScript($Work.ToString())
    if ($Arguments) { [void]$ps.AddParameters($Arguments) }
    $job = @{ PS = $ps; Handle = $ps.BeginInvoke(); Done = $Done }
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(40)
    $timer.Tag = $job
    $timer.Add_Tick({
        param($s, $e)
        $j = $s.Tag
        if (-not $j.Handle.IsCompleted) { return }
        $s.Stop()
        $result = $null
        try { $result = @($j.PS.EndInvoke($j.Handle))[0] } catch {}
        try { $j.PS.Dispose() } catch {}
        & $j.Done $result
    })
    $timer.Start()
}

# ---------------------------------------------------------------------------------------------------------------
# Theme (Apple system colours, HIG 2025) - follows Windows light/dark unless -Theme is given
# ---------------------------------------------------------------------------------------------------------------
$Palettes = @{
    Dark = @{
        Label = '#F2FFFFFF'; Secondary = '#8CFFFFFF'; Tertiary = '#40FFFFFF'; Separator = '#1AFFFFFF'
        Fill = '#1AFFFFFF'; Hover = '#1FFFFFFF'; Pressed = '#33FFFFFF'; RowHover = '#0FFFFFFF'
        Section = '#2E0B0C0F'; SectionRim = '#14FFFFFF'; Track = '#26FFFFFF'; Scroll = '#66FFFFFF'
        TrafficOff = '#38FFFFFF'; TrafficOffRim = '#14FFFFFF'; OnTint = '#FFFFFFFF'
        Tooltip = '#F21C1D22'; RedSoft = '#33FF4245'
        Red = '#FF4245'; Orange = '#FF9230'; Yellow = '#FFD600'; Green = '#30D158'; Mint = '#00DAC3'; Teal = '#00D2E0'
        Cyan = '#3CD3FE'; Blue = '#0091FF'; Indigo = '#6D7CFF'; Purple = '#DB34F2'; Pink = '#FF375F'; Gray = '#98989D'
        PurgeTint = '#D9FF375F'; PurgeIdleTint = '#1AFFFFFF'; ThumbTint = '#42FFFFFF'
        BodyTint = '#7A15161B'; Sheen = '#14FFFFFF'; InnerRim = '#0FFFFFFF'; RimHi = '#8CFFFFFF'; RimMid = '#14FFFFFF'; RimLo = '#40FFFFFF'; HudTint = '#B31E1F24'
        ChromeFace = 0.05; ChromeStroke = 0.16; ChromeShadow = 0.18; ThumbShadow = 0.25; HudFace = 0.06
    }
    Light = @{
        Label = '#D9000000'; Secondary = '#80000000'; Tertiary = '#42000000'; Separator = '#1A000000'
        Fill = '#0F000000'; Hover = '#12000000'; Pressed = '#1F000000'; RowHover = '#0A000000'
        Section = '#59FFFFFF'; SectionRim = '#80FFFFFF'; Track = '#14000000'; Scroll = '#59000000'
        TrafficOff = '#26000000'; TrafficOffRim = '#14000000'; OnTint = '#FFFFFFFF'
        Tooltip = '#F7FFFFFF'; RedSoft = '#26FF383C'
        Red = '#FF383C'; Orange = '#FF8D28'; Yellow = '#FFCC00'; Green = '#34C759'; Mint = '#00C8B3'; Teal = '#00C3D0'
        Cyan = '#00C0E8'; Blue = '#0088FF'; Indigo = '#6155F5'; Purple = '#CB30E0'; Pink = '#FF2D55'; Gray = '#8E8E93'
        PurgeTint = '#E6FF2D55'; PurgeIdleTint = '#99FFFFFF'; ThumbTint = '#F2FFFFFF'
        BodyTint = '#8CF5F6FA'; Sheen = '#40FFFFFF'; InnerRim = '#4DFFFFFF'; RimHi = '#F2FFFFFF'; RimMid = '#40FFFFFF'; RimLo = '#99FFFFFF'; HudTint = '#D9FFFFFF'
        ChromeFace = 0.3; ChromeStroke = 0.6; ChromeShadow = 0.12; ThumbShadow = 0.16; HudFace = 0.5
    }
}

function Resolve-ThemeName {
    if ($ThemeOption -match '^(?i)(light|dark)$') { return (Get-Culture).TextInfo.ToTitleCase($ThemeOption.ToLowerInvariant()) }
    try {
        $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme
        if ($v -eq 1) { return 'Light' }
    } catch {}
    return 'Dark'
}

# ---------------------------------------------------------------------------------------------------------------
# Window
# ---------------------------------------------------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:lg="clr-namespace:LiquidGlass;assembly=__ASM__"
        Title="Safe Background Task Killer" Width="560" Height="740"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" Icon="__ICO__" UseLayoutRounding="True" SnapsToDevicePixels="True"
        FontFamily="SF Pro Text, Segoe UI Variable Text, Segoe UI" FontSize="13"
        Foreground="{DynamicResource Label}" TextOptions.TextFormattingMode="Ideal">
    <Window.Resources>
        <FontFamily x:Key="Display">SF Pro Display, Segoe UI Variable Display, Segoe UI</FontFamily>
        <FontFamily x:Key="Rounded">SF Pro Rounded, Segoe UI Variable Display, Segoe UI</FontFamily>

        <Style x:Key="Bare" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{DynamicResource Label}"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="HorizontalContentAlignment" Value="Center"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Toolbar item inside a glass capsule: a platter fades in on hover (macOS Tahoe) -->
        <Style x:Key="ToolButton" TargetType="Button">
            <Setter Property="Width" Value="36"/>
            <Setter Property="Height" Value="36"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid Background="Transparent">
                            <Ellipse x:Name="Platter" Width="30" Height="30" Fill="{DynamicResource Hover}" Opacity="0"/>
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Trigger.EnterActions>
                                    <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="Platter" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.12"/></Storyboard></BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="Platter" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.22"/></Storyboard></BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Platter" Property="Fill" Value="{DynamicResource Pressed}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Traffic lights (14pt, 23pt pitch) -->
        <Style x:Key="Traffic" TargetType="Button">
            <Setter Property="Width" Value="14"/>
            <Setter Property="Height" Value="14"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Ellipse Fill="{TemplateBinding Background}" Stroke="{TemplateBinding BorderBrush}" StrokeThickness="0.8"/>
                            <Ellipse x:Name="Shade" Fill="#000000" Opacity="0"/>
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="Shade" Property="Opacity" Value="0.22"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="Chip" TargetType="Border">
            <Setter Property="CornerRadius" Value="10"/>
            <Setter Property="Padding" Value="8,3,9,3"/>
            <Setter Property="Margin" Value="0,0,6,6"/>
            <Setter Property="Background" Value="{DynamicResource Fill}"/>
            <Setter Property="TextElement.FontSize" Value="11"/>
            <Setter Property="TextElement.FontWeight" Value="Medium"/>
            <Setter Property="TextElement.Foreground" Value="{DynamicResource Secondary}"/>
        </Style>

        <!-- Overlay scrollbar that appears on hover -->
        <Style TargetType="ScrollBar">
            <Setter Property="OverridesDefaultStyle" Value="True"/>
            <Setter Property="Width" Value="10"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Track x:Name="PART_Track" IsDirectionReversed="True">
                            <Track.Thumb>
                                <Thumb>
                                    <Thumb.Template>
                                        <ControlTemplate TargetType="Thumb">
                                            <Border x:Name="Knob" Background="{DynamicResource Scroll}" CornerRadius="3" Width="6" HorizontalAlignment="Center"/>
                                            <ControlTemplate.Triggers>
                                                <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Knob" Property="Width" Value="8"/><Setter TargetName="Knob" Property="CornerRadius" Value="4"/></Trigger>
                                            </ControlTemplate.Triggers>
                                        </ControlTemplate>
                                    </Thumb.Template>
                                </Thumb>
                            </Track.Thumb>
                        </Track>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <ControlTemplate x:Key="OverlayScroll" TargetType="ScrollViewer">
            <Grid Background="Transparent">
                <ScrollContentPresenter Margin="{TemplateBinding Padding}" CanContentScroll="{TemplateBinding CanContentScroll}"/>
                <ScrollBar x:Name="PART_VerticalScrollBar" HorizontalAlignment="Right" Margin="0,10,3,70" Opacity="0"
                           Maximum="{TemplateBinding ScrollableHeight}" ViewportSize="{TemplateBinding ViewportHeight}"
                           Value="{Binding VerticalOffset, Mode=OneWay, RelativeSource={RelativeSource TemplatedParent}}"
                           Visibility="{TemplateBinding ComputedVerticalScrollBarVisibility}"/>
            </Grid>
            <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Trigger.EnterActions>
                        <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="PART_VerticalScrollBar" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.15"/></Storyboard></BeginStoryboard>
                    </Trigger.EnterActions>
                    <Trigger.ExitActions>
                        <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="PART_VerticalScrollBar" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.5"/></Storyboard></BeginStoryboard>
                    </Trigger.ExitActions>
                </Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate>

        <Style TargetType="ToolTip">
            <Setter Property="OverridesDefaultStyle" Value="True"/>
            <Setter Property="HasDropShadow" Value="True"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToolTip">
                        <Border Background="{DynamicResource Tooltip}" BorderBrush="{DynamicResource Separator}" BorderThickness="0.8" CornerRadius="7" Padding="9,4,9,5" Margin="0,0,6,8">
                            <Border.Effect><DropShadowEffect BlurRadius="10" ShadowDepth="2" Direction="270" Opacity="0.25"/></Border.Effect>
                            <ContentPresenter TextElement.Foreground="{DynamicResource Label}" TextElement.FontSize="11.5" TextElement.FontFamily="SF Pro Text, Segoe UI"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid x:Name="Root" RenderTransformOrigin="0.5,0.5">
        <Grid.RenderTransform><ScaleTransform x:Name="RootScale" ScaleX="1" ScaleY="1"/></Grid.RenderTransform>

        <Grid x:Name="SceneContainer">
            <!-- Window: a clear slab of Liquid Glass - whatever is behind the window shows through it -->
            <Border x:Name="Body" CornerRadius="8" Background="{DynamicResource BodyTint}"/>
            <Border CornerRadius="8" IsHitTestVisible="False">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                        <GradientStop Color="{DynamicResource SheenColor}" Offset="0"/>
                        <GradientStop Color="#00FFFFFF" Offset="0.45"/>
                    </LinearGradientBrush>
                </Border.Background>
            </Border>
            <Border CornerRadius="6.5" Margin="1.5" IsHitTestVisible="False" BorderThickness="1" BorderBrush="{DynamicResource InnerRim}"/>
            <Border CornerRadius="8" IsHitTestVisible="False" BorderThickness="1.2">
                <Border.BorderBrush>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="0.7,1">
                        <GradientStop Color="{DynamicResource RimHiColor}" Offset="0"/>
                        <GradientStop Color="{DynamicResource RimMidColor}" Offset="0.45"/>
                        <GradientStop Color="{DynamicResource RimLoColor}" Offset="1"/>
                    </LinearGradientBrush>
                </Border.BorderBrush>
            </Border>

            <Grid x:Name="Scene" Margin="12,0,12,12">
                <Grid.RowDefinitions>
                    <RowDefinition Height="52"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <!-- Unified toolbar (draggable) -->
                <Grid x:Name="TitleBar" Grid.Row="0" Background="Transparent">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel x:Name="Traffic" Orientation="Horizontal" VerticalAlignment="Center" Margin="4,0,0,0" Background="Transparent">
                        <Button x:Name="BtnClose" Style="{StaticResource Traffic}" Background="#FF5F57" BorderBrush="#E0443E" ToolTip="Close">
                            <Path x:Name="GlyphClose" Data="M0,0 L6,6 M6,0 L0,6" Stroke="#A64D0000" StrokeThickness="1.3" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Opacity="0"/>
                        </Button>
                        <Button x:Name="BtnMinimize" Style="{StaticResource Traffic}" Background="#FEBC2E" BorderBrush="#DEA123" Margin="9,0,0,0" ToolTip="Minimize">
                            <Path x:Name="GlyphMin" Data="M0,0 L7,0" Stroke="#B3995700" StrokeThickness="1.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Opacity="0"/>
                        </Button>
                        <Button x:Name="BtnZoom" Style="{StaticResource Traffic}" Background="{DynamicResource TrafficOff}" BorderBrush="{DynamicResource TrafficOffRim}" Margin="9,0,0,0" IsEnabled="False"/>
                    </StackPanel>

                    <Border x:Name="AppIcon" Grid.Column="1" Width="28" Height="28" CornerRadius="7" Margin="18,0,10,0" VerticalAlignment="Center">
                        <Border.Effect><DropShadowEffect BlurRadius="6" ShadowDepth="1" Direction="270" Opacity="0.3"/></Border.Effect>
                    </Border>

                    <StackPanel Grid.Column="2" VerticalAlignment="Center">
                        <TextBlock Text="Safe Background Task Killer" FontSize="15" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                        <TextBlock x:Name="TxtSubtitle" Text="Scanning&#x2026;" FontSize="11" Foreground="{DynamicResource Secondary}" Margin="0,1,0,0" TextTrimming="CharacterEllipsis"/>
                    </StackPanel>

                    <lg:GlassSurface x:Name="Tools" Grid.Column="3" Height="36" CornerRadius="-1" VerticalAlignment="Center" SourceName="Body"
                                     Refraction="10" Bezel="14" Profile="4" OuterRefraction="2" OuterBand="4" Dispersion="0.06" Saturation="1.3"
                                     Face="{DynamicResource ChromeFace}" Glint="0.9" GlintBand="2.2" Stroke="{DynamicResource ChromeStroke}"
                                     ShadowOpacity="{DynamicResource ChromeShadow}" ShadowBlur="14" ShadowDepth="3">
                        <StackPanel Orientation="Horizontal" Margin="2,0">
                            <Button x:Name="BtnRescan" Style="{StaticResource ToolButton}" ToolTip="Rescan (Ctrl+R)">
                                <Path Data="M14.98,5.82 A6.5,6.5 0 1 1 10,3.5 M7.9,1.2 L10.2,3.5 L7.9,5.8" Width="20" Height="20" Stretch="None"
                                      Stroke="{DynamicResource Label}" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                                      RenderTransformOrigin="0.5,0.5">
                                    <Path.RenderTransform><RotateTransform x:Name="RescanSpin"/></Path.RenderTransform>
                                </Path>
                            </Button>
                            <Button x:Name="BtnConfig" Style="{StaticResource ToolButton}" ToolTip="Edit targets.json (Ctrl+,)">
                                <Path x:Name="IcoGear" Width="17" Height="17" Stretch="None" Fill="{DynamicResource Label}"/>
                            </Button>
                        </StackPanel>
                    </lg:GlassSurface>
                </Grid>

                <!-- Memory overview -->
                <Border x:Name="Hero" Grid.Row="1" CornerRadius="14" Background="{DynamicResource Section}" BorderBrush="{DynamicResource SectionRim}" BorderThickness="0.8" Padding="18,16,16,10">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid Width="96" Height="96" VerticalAlignment="Top" Margin="0,0,0,6">
                            <lg:Ring x:Name="Ring" StrokeWidth="12" TrackBrush="{DynamicResource Track}" StartColor="{DynamicResource CyanColor}" EndColor="{DynamicResource PinkColor}"/>
                            <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                                <lg:NumberText x:Name="TxtPercent" Suffix="%" FontFamily="{StaticResource Rounded}" FontWeight="SemiBold" FontSize="20" HorizontalAlignment="Center" Typography.NumeralAlignment="Tabular"/>
                                <TextBlock Text="of RAM" FontSize="10" Foreground="{DynamicResource Secondary}" HorizontalAlignment="Center" Margin="0,-2,0,0"/>
                            </StackPanel>
                        </Grid>
                        <StackPanel Grid.Column="1" Margin="20,2,0,0" VerticalAlignment="Center">
                            <TextBlock Text="Reclaimable Memory" FontSize="12" FontWeight="Medium" Foreground="{DynamicResource Secondary}"/>
                            <StackPanel Orientation="Horizontal">
                                <lg:NumberText x:Name="TxtReclaimValue" FontFamily="{StaticResource Rounded}" FontWeight="SemiBold" FontSize="38" Typography.NumeralAlignment="Tabular"/>
                                <TextBlock x:Name="TxtReclaimUnit" Text="MB" FontFamily="{StaticResource Rounded}" FontWeight="SemiBold" FontSize="20" Foreground="{DynamicResource Secondary}" Margin="5,0,0,7" VerticalAlignment="Bottom"/>
                            </StackPanel>
                            <WrapPanel Margin="0,6,0,0">
                                <Border Style="{StaticResource Chip}">
                                    <StackPanel Orientation="Horizontal">
                                        <Ellipse Width="6" Height="6" Fill="{DynamicResource Pink}" Margin="0,0,6,0" VerticalAlignment="Center"/>
                                        <TextBlock x:Name="ChipTargets" Text="0 processes"/>
                                    </StackPanel>
                                </Border>
                                <Border Style="{StaticResource Chip}">
                                    <StackPanel Orientation="Horizontal">
                                        <Ellipse Width="6" Height="6" Fill="{DynamicResource Green}" Margin="0,0,6,0" VerticalAlignment="Center"/>
                                        <TextBlock x:Name="ChipProtected" Text="0 protected"/>
                                    </StackPanel>
                                </Border>
                                <Border x:Name="ChipAdmin" Style="{StaticResource Chip}">
                                    <StackPanel Orientation="Horizontal">
                                        <Path x:Name="ChipAdminIcon" Data="M7,0.8 L12.6,2.9 L12.6,7.2 C12.6,10.6 10.3,13.1 7,14.4 C3.7,13.1 1.4,10.6 1.4,7.2 L1.4,2.9 Z" Width="9" Height="11" Stretch="Uniform" Margin="0,0,6,0" VerticalAlignment="Center"/>
                                        <TextBlock x:Name="ChipAdminText"/>
                                    </StackPanel>
                                </Border>
                                <Border x:Name="ChipSimulation" Style="{StaticResource Chip}" Visibility="Collapsed">
                                    <StackPanel Orientation="Horizontal">
                                        <Ellipse Width="6" Height="6" Fill="{DynamicResource Blue}" Margin="0,0,6,0" VerticalAlignment="Center"/>
                                        <TextBlock Text="Simulation"/>
                                    </StackPanel>
                                </Border>
                            </WrapPanel>
                        </StackPanel>
                    </Grid>
                </Border>

                <!-- Segmented control with a Liquid Glass thumb -->
                <Grid x:Name="Seg" Grid.Row="2" Height="32" Margin="0,12,0,12">
                    <Border CornerRadius="16" Background="{DynamicResource Fill}"/>
                    <Grid x:Name="SegTrack" Margin="2">
                        <lg:GlassSurface x:Name="SegThumb" HorizontalAlignment="Left" CornerRadius="-1" SourceName="Body"
                                         Refraction="8" Bezel="12" Profile="4" OuterRefraction="1.5" OuterBand="3" Dispersion="0.05" Saturation="1.3"
                                         TintColor="{DynamicResource ThumbTintColor}" Face="0" Glint="1" GlintBand="2" Stroke="{DynamicResource ChromeStroke}"
                                         ShadowOpacity="{DynamicResource ThumbShadow}" ShadowBlur="8" ShadowDepth="2"/>
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition/>
                                <ColumnDefinition/>
                            </Grid.ColumnDefinitions>
                            <Button x:Name="TabBackground" Style="{StaticResource Bare}">
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock x:Name="TabBackgroundLabel" Text="Background" FontSize="12" FontWeight="SemiBold"/>
                                    <TextBlock x:Name="TabBackgroundCount" Text="0" FontSize="12" Foreground="{DynamicResource Secondary}" Margin="6,0,0,0" Typography.NumeralAlignment="Tabular"/>
                                </StackPanel>
                            </Button>
                            <Button x:Name="TabProtected" Grid.Column="1" Style="{StaticResource Bare}">
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock x:Name="TabProtectedLabel" Text="Protected" FontSize="12" FontWeight="Medium" Foreground="{DynamicResource Secondary}"/>
                                    <TextBlock x:Name="TabProtectedCount" Text="0" FontSize="12" Foreground="{DynamicResource Secondary}" Margin="6,0,0,0" Typography.NumeralAlignment="Tabular"/>
                                </StackPanel>
                            </Button>
                        </Grid>
                    </Grid>
                </Grid>

                <!-- Grouped list -->
                <Border x:Name="ListSection" Grid.Row="3" CornerRadius="14" Background="{DynamicResource Section}" BorderBrush="{DynamicResource SectionRim}" BorderThickness="0.8">
                    <Grid>
                        <Grid.OpacityMask>
                            <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                                <GradientStop Color="#FF000000" Offset="0"/>
                                <GradientStop Color="#FF000000" Offset="0.8"/>
                                <GradientStop Color="#10000000" Offset="1"/>
                            </LinearGradientBrush>
                        </Grid.OpacityMask>
                        <ScrollViewer x:Name="ScrollTargets" Template="{StaticResource OverlayScroll}" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                                      CanContentScroll="False" lg:SmoothScroll.Enabled="True" Padding="0,6,0,76">
                            <StackPanel x:Name="PnlTargetApps"/>
                        </ScrollViewer>
                        <ScrollViewer x:Name="ScrollProtected" Template="{StaticResource OverlayScroll}" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                                      CanContentScroll="False" lg:SmoothScroll.Enabled="True" Padding="0,6,0,76" Visibility="Collapsed">
                            <StackPanel x:Name="PnlProtectedApps"/>
                        </ScrollViewer>
                        <StackPanel x:Name="EmptyState" VerticalAlignment="Center" HorizontalAlignment="Center" Margin="0,0,0,64" Visibility="Collapsed">
                            <Grid Width="52" Height="52" HorizontalAlignment="Center">
                                <Ellipse x:Name="EmptyBadge" Fill="{DynamicResource Green}"/>
                                <Viewbox Width="26" Height="26">
                                    <Path x:Name="EmptyGlyph" Width="20" Height="20" Stretch="None" Stroke="White" StrokeThickness="2.2"
                                          StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                                </Viewbox>
                            </Grid>
                            <TextBlock x:Name="EmptyTitle" FontSize="17" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,12,0,3"/>
                            <TextBlock x:Name="EmptyBody" FontSize="12" Foreground="{DynamicResource Secondary}" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap" MaxWidth="290"/>
                        </StackPanel>
                    </Grid>
                </Border>
            </Grid>
        </Grid>

        <!-- Floating prominent action: tinted Liquid Glass refracting the list scrolling beneath it -->
        <lg:GlassSurface x:Name="PurgeBar" SourceName="SceneContainer" VerticalAlignment="Bottom" HorizontalAlignment="Center" Margin="0,0,0,24"
                         Height="48" CornerRadius="-1" BlurRadius="6" Refraction="14" Bezel="20" Profile="5" OuterRefraction="3" OuterBand="5"
                         Dispersion="0.07" Saturation="1.4" TintColor="{DynamicResource PurgeTintColor}" Face="0" Glint="1" GlintBand="2.5" Stroke="0.22"
                         Interactive="True" ShadowOpacity="0.38" ShadowBlur="26" ShadowDepth="8">
            <Button x:Name="BtnPurge" Style="{StaticResource Bare}" Padding="24,0,28,0">
                <StackPanel Orientation="Horizontal">
                    <Grid Width="18" Height="18" Margin="0,0,8,0" VerticalAlignment="Center">
                        <Path x:Name="IcoPurge" Data="M11.6,1.5 L4.2,11.2 L9.3,11.2 L8.2,18.5 L15.8,8.6 L10.7,8.6 Z" Fill="{DynamicResource OnTint}" Stretch="Uniform"/>
                        <lg:Ring x:Name="PurgeSpinner" StrokeWidth="2.2" Progress="0.3" Visibility="Collapsed" TrackBrush="#40FFFFFF" StartColor="#FFFFFFFF" EndColor="#FFFFFFFF" RenderTransformOrigin="0.5,0.5">
                            <lg:Ring.RenderTransform><RotateTransform x:Name="PurgeSpin"/></lg:Ring.RenderTransform>
                        </lg:Ring>
                    </Grid>
                    <TextBlock x:Name="TxtPurge" Text="Purge Background Processes" FontSize="14" FontWeight="SemiBold" Foreground="{DynamicResource OnTint}" VerticalAlignment="Center"/>
                </StackPanel>
            </Button>
        </lg:GlassSurface>

        <!-- Notification HUD -->
        <lg:GlassSurface x:Name="Hud" SourceName="SceneContainer" VerticalAlignment="Top" HorizontalAlignment="Center" Margin="0,8,0,0"
                         MinWidth="300" Height="58" CornerRadius="22" BlurRadius="10" Refraction="12" Bezel="18" Profile="4" OuterRefraction="2" OuterBand="4"
                         Dispersion="0.06" Saturation="1.4" Face="{DynamicResource HudFace}" TintColor="{DynamicResource HudTintColor}" Glint="0.9" GlintBand="2.5" Stroke="{DynamicResource ChromeStroke}"
                         ShadowOpacity="0.35" ShadowBlur="28" ShadowDepth="8" Opacity="0" Visibility="Collapsed" IsHitTestVisible="False">
            <StackPanel Orientation="Horizontal" Margin="13,0,24,0" VerticalAlignment="Center">
                <Grid Width="32" Height="32" Margin="0,0,11,0">
                    <Ellipse x:Name="HudBadge" Fill="{DynamicResource Green}"/>
                    <Viewbox Width="17" Height="17">
                        <Path x:Name="HudGlyph" Width="20" Height="20" Stretch="None" Stroke="White" StrokeThickness="2.4"
                              StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                    </Viewbox>
                </Grid>
                <StackPanel VerticalAlignment="Center">
                    <TextBlock x:Name="HudTitle" FontSize="13" FontWeight="SemiBold"/>
                    <TextBlock x:Name="HudBody" FontSize="12" Foreground="{DynamicResource Secondary}" Margin="0,1,0,0"/>
                </StackPanel>
            </StackPanel>
        </lg:GlassSurface>
    </Grid>
</Window>
'@

$xaml = $xaml.Replace('__ASM__', [LiquidGlass.GlassSurface].Assembly.GetName().Name).Replace('__ICO__', $iconIcoPath)
$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# Get Controls
$ui = @{}
foreach ($name in @(
        'Root', 'RootScale', 'SceneContainer', 'Body', 'TitleBar', 'Traffic', 'BtnClose', 'BtnMinimize', 'BtnZoom', 'GlyphClose', 'GlyphMin',
        'AppIcon', 'TxtSubtitle', 'Tools', 'BtnRescan', 'RescanSpin', 'BtnConfig', 'IcoGear', 'Ring', 'TxtPercent', 'TxtReclaimValue', 'TxtReclaimUnit',
        'ChipTargets', 'ChipProtected', 'ChipAdmin', 'ChipAdminIcon', 'ChipAdminText', 'ChipSimulation', 'SegTrack', 'SegThumb',
        'TabBackground', 'TabBackgroundLabel', 'TabBackgroundCount', 'TabProtected', 'TabProtectedLabel', 'TabProtectedCount',
        'ScrollTargets', 'PnlTargetApps', 'ScrollProtected', 'PnlProtectedApps', 'EmptyState', 'EmptyBadge', 'EmptyGlyph', 'EmptyTitle', 'EmptyBody',
        'PurgeBar', 'BtnPurge', 'IcoPurge', 'PurgeSpinner', 'PurgeSpin', 'TxtPurge', 'Hud', 'HudBadge', 'HudGlyph', 'HudTitle', 'HudBody')) {
    $ui[$name] = $window.FindName($name)
}

$Glyphs = @{
    Check  = 'M5,10.4 L8.6,14 L15.2,6.4'
    Alert  = 'M10,4.2 L10,11.6 M10,15.4 L10,15.5'
    Info   = 'M10,8.8 L10,15.2 M10,4.9 L10,5'
    Shield = 'M10,2.2 L16.2,4.6 L16.2,9.4 C16.2,13.2 13.6,16 10,17.6 C6.4,16 3.8,13.2 3.8,9.4 L3.8,4.6 Z'
}

function Set-Theme([string]$name) {
    $script:ThemeName = $name
    $palette = $Palettes[$name]
    foreach ($key in $palette.Keys) {
        $value = $palette[$key]
        if ($value -is [string]) {
            $color = [System.Windows.Media.ColorConverter]::ConvertFromString($value)
            $window.Resources["$($key)Color"] = $color
            $brush = [System.Windows.Media.SolidColorBrush]::new($color)
            $brush.Freeze()
            $window.Resources[$key] = $brush
        } else {
            $window.Resources[$key] = [double]$value
        }
    }
    Update-WindowActiveState
}

function Update-WindowActiveState {
    $active = $window.IsActive -or -not $window.IsLoaded
    if ($active) {
        $ui.BtnClose.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF5F57')
        $ui.BtnClose.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E0443E')
        $ui.BtnMinimize.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FEBC2E')
        $ui.BtnMinimize.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#DEA123')
    } else {
        foreach ($b in @($ui.BtnClose, $ui.BtnMinimize)) {
            $b.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'TrafficOff')
            $b.SetResourceReference([System.Windows.Controls.Control]::BorderBrushProperty, 'TrafficOffRim')
        }
    }
}

Set-Theme (Resolve-ThemeName)

# App icon
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
    $ui.AppIcon.Background = $iconBrush
} catch {}

$ui.IcoGear.Data = [LiquidGlass.Symbols]::Gear(17, 8)
$ui.EmptyGlyph.Data = [System.Windows.Media.Geometry]::Parse($Glyphs.Check)

if ($isAdmin) {
    $ui.ChipAdminText.Text = 'Administrator'
    $ui.ChipAdminIcon.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'Green')
    $ui.ChipAdmin.ToolTip = 'Background services will be stopped too'
} else {
    $ui.ChipAdminText.Text = 'Standard User'
    $ui.ChipAdminIcon.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'Orange')
    $ui.ChipAdmin.ToolTip = 'Relaunch as administrator to also stop background services'
}
if ($SimulateOnly) { $ui.ChipSimulation.Visibility = 'Visible' }

# ---------------------------------------------------------------------------------------------------------------
# Motion helpers
# ---------------------------------------------------------------------------------------------------------------
function Fade($element, [double]$to, [int]$ms) {
    [LiquidGlass.Motion]::Ease($element, [System.Windows.UIElement]::OpacityProperty, $to, $ms)
}

function Start-AppearAnimation($element, [int]$delayMs) {
    $element.Opacity = 0
    $shift = [System.Windows.Media.TranslateTransform]::new(0, 10)
    $element.RenderTransform = $shift
    $fade = [System.Windows.Media.Animation.DoubleAnimation]::new(1, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(260)))
    $fade.BeginTime = [TimeSpan]::FromMilliseconds($delayMs)
    $element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    $rise = [System.Windows.Media.Animation.DoubleAnimation]::new(0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(660)))
    $rise.BeginTime = [TimeSpan]::FromMilliseconds($delayMs)
    $rise.EasingFunction = [LiquidGlass.SpringEase]::new(0.2)
    $shift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $rise)
}

function Start-Spin($rotate, [int]$ms) {
    $spin = [System.Windows.Media.Animation.DoubleAnimation]::new(0, 360, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($ms)))
    $spin.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $rotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $spin)
}

function Stop-Spin($rotate) {
    $rotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
    $rotate.Angle = 0
}

function Invoke-Later([int]$ms, [scriptblock]$action) {
    $t = [System.Windows.Threading.DispatcherTimer]::new()
    $t.Interval = [TimeSpan]::FromMilliseconds($ms)
    $t.Tag = $action
    $t.Add_Tick({ param($s, $e) $s.Stop(); & $s.Tag })
    $t.Start()
}

function Format-Bytes([double]$bytes) {
    if ($bytes -ge 1GB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N0} MB' -f ($bytes / 1MB)) }
    return ('{0:N0} KB' -f ($bytes / 1KB))
}

# ---------------------------------------------------------------------------------------------------------------
# List rows
# ---------------------------------------------------------------------------------------------------------------
$MonogramKeys = @('Blue', 'Indigo', 'Purple', 'Pink', 'Red', 'Orange', 'Green', 'Teal', 'Cyan', 'Mint')
$script:IconQueue = [System.Collections.Queue]::new()

function New-Monogram([string]$name) {
    $seed = 7
    foreach ($ch in $name.ToCharArray()) { $seed = ($seed * 31 + [int]$ch) % 1000003 }
    $color = $window.Resources["$($MonogramKeys[$seed % $MonogramKeys.Count])Color"]
    $top = [System.Windows.Media.Color]::FromRgb([byte](($color.R + 255 * 0.35) / 1.35), [byte](($color.G + 255 * 0.35) / 1.35), [byte](($color.B + 255 * 0.35) / 1.35))
    $tile = [System.Windows.Controls.Border]::new()
    $tile.CornerRadius = [System.Windows.CornerRadius]::new(7)
    $tile.Background = [System.Windows.Media.LinearGradientBrush]::new($top, $color, 90)
    $letter = [System.Windows.Controls.TextBlock]::new()
    $letter.Text = if ($name) { $name.Substring(0, 1).ToUpperInvariant() } else { '?' }
    $letter.FontFamily = $window.FindResource('Rounded')
    $letter.FontWeight = [System.Windows.FontWeights]::SemiBold
    $letter.FontSize = 14
    $letter.Foreground = [System.Windows.Media.Brushes]::White
    $letter.HorizontalAlignment = 'Center'
    $letter.VerticalAlignment = 'Center'
    $tile.Child = $letter
    return $tile
}

function New-AppRow {
    param([string]$Title, [string]$Subtitle, [string]$Trailing, [string]$Path, [string]$KillName, [bool]$Protected, [bool]$Last, [int]$Index)

    $row = [System.Windows.Controls.Grid]::new()
    $row.Height = 46
    $row.Margin = [System.Windows.Thickness]::new(6, 0, 6, 0)
    $row.Background = [System.Windows.Media.Brushes]::Transparent

    $hover = [System.Windows.Controls.Border]::new()
    $hover.CornerRadius = [System.Windows.CornerRadius]::new(10)
    $hover.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'RowHover')
    $hover.Opacity = 0
    [void]$row.Children.Add($hover)

    $grid = [System.Windows.Controls.Grid]::new()
    $grid.Margin = [System.Windows.Thickness]::new(10, 0, 8, 0)
    foreach ($width in @('Auto', '*', 'Auto', 'Auto')) {
        $column = [System.Windows.Controls.ColumnDefinition]::new()
        $column.Width = if ($width -eq '*') { [System.Windows.GridLength]::new(1, 'Star') } else { [System.Windows.GridLength]::Auto }
        $grid.ColumnDefinitions.Add($column)
    }

    $iconHost = [System.Windows.Controls.Grid]::new()
    $iconHost.Width = 28
    $iconHost.Height = 28
    $iconHost.VerticalAlignment = 'Center'
    [void]$iconHost.Children.Add((New-Monogram $Title))
    [void]$grid.Children.Add($iconHost)
    if ($Path) { $script:IconQueue.Enqueue(@{ Path = $Path; Host = $iconHost }) }

    $texts = [System.Windows.Controls.StackPanel]::new()
    $texts.Margin = [System.Windows.Thickness]::new(12, 0, 10, 0)
    $texts.VerticalAlignment = 'Center'
    $titleText = [System.Windows.Controls.TextBlock]::new()
    $titleText.Text = $Title
    $titleText.FontSize = 13
    $titleText.FontWeight = [System.Windows.FontWeights]::Medium
    $titleText.TextTrimming = 'CharacterEllipsis'
    $subText = [System.Windows.Controls.TextBlock]::new()
    $subText.Text = $Subtitle
    $subText.FontSize = 11
    $subText.Margin = [System.Windows.Thickness]::new(0, 1, 0, 0)
    $subText.TextTrimming = 'CharacterEllipsis'
    $subText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Secondary')
    [void]$texts.Children.Add($titleText)
    [void]$texts.Children.Add($subText)
    [System.Windows.Controls.Grid]::SetColumn($texts, 1)
    [void]$grid.Children.Add($texts)

    if ($Protected) {
        $shield = [System.Windows.Shapes.Path]::new()
        $shield.Data = [System.Windows.Media.Geometry]::Parse($Glyphs.Shield)
        $shield.Width = 12
        $shield.Height = 14
        $shield.Stretch = 'Uniform'
        $shield.VerticalAlignment = 'Center'
        $shield.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'Green')
        $shield.ToolTip = 'Protected: visible on screen or taskbar'
        $trail = $shield
    } else {
        $trail = [System.Windows.Controls.TextBlock]::new()
        $trail.Text = $Trailing
        $trail.FontSize = 12
        $trail.FontWeight = [System.Windows.FontWeights]::Medium
        $trail.VerticalAlignment = 'Center'
        [System.Windows.Documents.Typography]::SetNumeralAlignment($trail, 'Tabular')
        $trail.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Secondary')
    }
    [System.Windows.Controls.Grid]::SetColumn($trail, 2)
    [void]$grid.Children.Add($trail)

    # End button: red glyph on a neutral platter, revealed on hover (destructive = red label, not red fill)
    $end = [System.Windows.Controls.Border]::new()
    $end.Width = 22
    $end.Height = 22
    $end.CornerRadius = [System.Windows.CornerRadius]::new(11)
    $end.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0)
    $end.VerticalAlignment = 'Center'
    $end.Opacity = 0
    $end.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'Fill')
    $end.ToolTip = "End $Title"
    $xmark = [System.Windows.Shapes.Path]::new()
    $xmark.Data = [System.Windows.Media.Geometry]::Parse('M0,0 L7,7 M7,0 L0,7')
    $xmark.StrokeThickness = 1.6
    $xmark.StrokeStartLineCap = 'Round'
    $xmark.StrokeEndLineCap = 'Round'
    $xmark.HorizontalAlignment = 'Center'
    $xmark.VerticalAlignment = 'Center'
    $xmark.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, 'Red')
    $end.Child = $xmark
    $end.Tag = $KillName
    $end.Add_MouseEnter({ param($s, $e) $s.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'RedSoft') })
    $end.Add_MouseLeave({ param($s, $e) $s.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'Fill') })
    $end.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Kill-SpecificProcess $s.Tag })
    [System.Windows.Controls.Grid]::SetColumn($end, 3)
    [void]$grid.Children.Add($end)
    [void]$row.Children.Add($grid)

    if (-not $Last) {
        $separator = [System.Windows.Shapes.Rectangle]::new()
        $separator.Height = 0.8
        $separator.VerticalAlignment = 'Bottom'
        $separator.Margin = [System.Windows.Thickness]::new(50, 0, 10, 0)
        $separator.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'Separator')
        [void]$row.Children.Add($separator)
    }

    $row.Tag = @{ Hover = $hover; End = $end }
    $row.Add_MouseEnter({ param($s, $e) Fade $s.Tag.Hover 1 110; Fade $s.Tag.End 1 140 })
    $row.Add_MouseLeave({ param($s, $e) Fade $s.Tag.Hover 0 220; Fade $s.Tag.End 0 200 })

    if ($Index -ge 0) { Start-AppearAnimation $row ([Math]::Min($Index, 14) * 24) }
    return $row
}

$script:IconTimer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Background)
$script:IconTimer.Interval = [TimeSpan]::FromMilliseconds(12)
$script:IconTimer.Add_Tick({
    $budget = 3
    while ($script:IconQueue.Count -gt 0 -and $budget -gt 0) {
        $item = $script:IconQueue.Dequeue()
        $budget--
        $source = [LiquidGlass.ProcInfo]::Icon($item.Path)
        if (-not $source) { continue }
        $image = [System.Windows.Controls.Image]::new()
        $image.Source = $source
        $image.Width = 28
        $image.Height = 28
        $image.Opacity = 0
        [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($image, 'HighQuality')
        [void]$item.Host.Children.Add($image)
        Fade $image 1 200
        Fade $item.Host.Children[0] 0 200
    }
    if ($script:IconQueue.Count -eq 0) { $script:IconTimer.Stop() }
})

# ---------------------------------------------------------------------------------------------------------------
# State -> UI
# ---------------------------------------------------------------------------------------------------------------
$script:ActiveTab = 'Background'
$script:Busy = $false
$script:Scanning = $false
$script:ScanQueued = $false
$script:HasScanned = $false
$script:TargetGroupCount = 0
$script:ProtectedCount = 0

$thumbScale = [System.Windows.Media.ScaleTransform]::new(1, 1)
$thumbShift = [System.Windows.Media.TranslateTransform]::new(0, 0)
$thumbTransform = [System.Windows.Media.TransformGroup]::new()
$thumbTransform.Children.Add($thumbScale)
$thumbTransform.Children.Add($thumbShift)
$ui.SegThumb.RenderTransform = $thumbTransform
$ui.SegThumb.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 0.5)

$hudScale = [System.Windows.Media.ScaleTransform]::new(1, 1)
$hudShift = [System.Windows.Media.TranslateTransform]::new(0, 0)
$hudTransform = [System.Windows.Media.TransformGroup]::new()
$hudTransform.Children.Add($hudScale)
$hudTransform.Children.Add($hudShift)
$ui.Hud.RenderTransform = $hudTransform
$ui.Hud.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 0.5)

function Update-ThumbGeometry {
    $half = [Math]::Max(0.0, $ui.SegTrack.ActualWidth / 2.0)
    $ui.SegThumb.Width = $half
    $thumbShift.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
    $thumbShift.X = if ($script:ActiveTab -eq 'Protected') { $half } else { 0 }
}

function Update-EmptyState {
    $showEmpty = $false
    if ($script:HasScanned) {
        if ($script:ActiveTab -eq 'Background' -and $script:TargetGroupCount -eq 0) {
            $showEmpty = $true
            $ui.EmptyBadge.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'Green')
            $ui.EmptyGlyph.Data = [System.Windows.Media.Geometry]::Parse($Glyphs.Check)
            $ui.EmptyGlyph.Fill = $null
            $ui.EmptyTitle.Text = 'All Clear'
            $ui.EmptyBody.Text = 'Nothing is running in the background right now.'
        } elseif ($script:ActiveTab -eq 'Protected' -and $script:ProtectedCount -eq 0) {
            $showEmpty = $true
            $ui.EmptyBadge.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'Blue')
            $ui.EmptyGlyph.Data = [System.Windows.Media.Geometry]::Parse($Glyphs.Shield)
            $ui.EmptyGlyph.Fill = [System.Windows.Media.Brushes]::White
            $ui.EmptyTitle.Text = 'No Open Windows'
            $ui.EmptyBody.Text = 'Apps you have open on screen or in the taskbar are protected automatically.'
        }
    }
    $ui.EmptyState.Visibility = if ($showEmpty) { 'Visible' } else { 'Collapsed' }
}

function Select-Tab([string]$tab, [bool]$animate = $true) {
    if ($tab -eq $script:ActiveTab -and $animate) { return }
    $script:ActiveTab = $tab
    $half = [Math]::Max(0.0, $ui.SegTrack.ActualWidth / 2.0)
    $target = if ($tab -eq 'Protected') { $half } else { 0 }
    if ($animate) {
        [LiquidGlass.Motion]::Spring($thumbShift, [System.Windows.Media.TranslateTransform]::XProperty, $target, 420, 0.28)
        foreach ($axis in @(@([System.Windows.Media.ScaleTransform]::ScaleXProperty, 1.16), @([System.Windows.Media.ScaleTransform]::ScaleYProperty, 1.1))) {
            $swell = [System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames]::new()
            $out = [System.Windows.Media.Animation.CubicEase]::new()
            $out.EasingMode = 'EaseOut'
            [void]$swell.KeyFrames.Add([System.Windows.Media.Animation.EasingDoubleKeyFrame]::new($axis[1], [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(130)), $out))
            [void]$swell.KeyFrames.Add([System.Windows.Media.Animation.EasingDoubleKeyFrame]::new(1, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(720)), [LiquidGlass.SpringEase]::new(0.35)))
            $thumbScale.BeginAnimation($axis[0], $swell)
        }
        [LiquidGlass.GlassSurface]::TrackAll(900)
    } else {
        $thumbShift.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
        $thumbShift.X = $target
    }

    $selectedLabel = if ($tab -eq 'Background') { $ui.TabBackgroundLabel } else { $ui.TabProtectedLabel }
    $otherLabel = if ($tab -eq 'Background') { $ui.TabProtectedLabel } else { $ui.TabBackgroundLabel }
    $selectedLabel.FontWeight = [System.Windows.FontWeights]::SemiBold
    $selectedLabel.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Label')
    $otherLabel.FontWeight = [System.Windows.FontWeights]::Medium
    $otherLabel.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Secondary')

    $show = if ($tab -eq 'Background') { $ui.ScrollTargets } else { $ui.ScrollProtected }
    $hide = if ($tab -eq 'Background') { $ui.ScrollProtected } else { $ui.ScrollTargets }
    $hide.Visibility = 'Collapsed'
    $show.Visibility = 'Visible'
    if ($animate) { $show.Opacity = 0; Fade $show 1 200 }
    Update-EmptyState
}

function Update-PurgeButton {
    $count = @($script:CurrentTargetsToKill).Count
    if ($script:Busy) {
        $ui.IcoPurge.Visibility = 'Collapsed'
        $ui.PurgeSpinner.Visibility = 'Visible'
        Start-Spin $ui.PurgeSpin 800
        $ui.TxtPurge.Text = "Purging$Ellipsis"
        $ui.PurgeBar.Interactive = $false
        return
    }
    Stop-Spin $ui.PurgeSpin
    $ui.PurgeSpinner.Visibility = 'Collapsed'
    $ui.IcoPurge.Visibility = 'Visible'
    if ($count -gt 0 -or -not $script:HasScanned) {
        $noun = if ($count -eq 1) { 'Process' } else { 'Processes' }
        $ui.TxtPurge.Text = if ($script:HasScanned) { "Purge $count Background $noun" } else { 'Purge Background Processes' }
        $ui.PurgeBar.SetResourceReference([LiquidGlass.GlassSurface]::TintColorProperty, 'PurgeTintColor')
        $ui.TxtPurge.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'OnTint')
        $ui.IcoPurge.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'OnTint')
        $ui.PurgeBar.Interactive = $true
    } else {
        $ui.TxtPurge.Text = 'Nothing to Purge'
        $ui.PurgeBar.SetResourceReference([LiquidGlass.GlassSurface]::TintColorProperty, 'PurgeIdleTintColor')
        $ui.TxtPurge.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Secondary')
        $ui.IcoPurge.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'Secondary')
        $ui.PurgeBar.Interactive = $false
    }
}

function Update-Hero([double]$bytes, [double]$physical) {
    $useGb = $bytes -ge 1GB
    $value = if ($useGb) { $bytes / 1GB } else { $bytes / 1MB }
    $from = $ui.TxtReclaimValue.Value
    if ($script:HeroUnitGb -ne $useGb) { $from = if ($useGb) { $from / 1024 } else { $from * 1024 } }
    $script:HeroUnitGb = $useGb
    $ui.TxtReclaimUnit.Text = if ($useGb) { 'GB' } else { 'MB' }
    $ui.TxtReclaimValue.Decimals = if ($useGb) { 2 } else { 0 }
    $ui.TxtReclaimValue.Value = $from
    $count = [System.Windows.Media.Animation.DoubleAnimation]::new($value, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(900)))
    $ease = [System.Windows.Media.Animation.QuarticEase]::new()
    $ease.EasingMode = 'EaseOut'
    $count.EasingFunction = $ease
    $ui.TxtReclaimValue.BeginAnimation([LiquidGlass.NumberText]::ValueProperty, $count)

    $share = if ($physical -gt 0) { [Math]::Min(1.0, $bytes / $physical) } else { 0 }
    [LiquidGlass.Motion]::Spring($ui.Ring, [LiquidGlass.Ring]::ProgressProperty, $share, 700, 0.12)
    $pct = [System.Windows.Media.Animation.DoubleAnimation]::new($share * 100, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(900)))
    $pct.EasingFunction = $ease
    $ui.TxtPercent.BeginAnimation([LiquidGlass.NumberText]::ValueProperty, $pct)
}

function Update-FromScan($data) {
    $script:HasScanned = $true
    $script:CurrentTargetsToKill = @($data.Targets)
    $script:SafeProcNames = @($data.Safe)
    $groups = @($data.TargetGroups)
    $protected = @($data.Protected)
    $script:TargetGroupCount = $groups.Count
    $script:ProtectedCount = $protected.Count

    $instances = $script:CurrentTargetsToKill.Count
    $ui.ChipTargets.Text = if ($instances -eq 1) { '1 process' } else { "$instances processes" }
    $ui.ChipProtected.Text = "$($protected.Count) protected"
    $ui.TabBackgroundCount.Text = "$($groups.Count)"
    $ui.TabProtectedCount.Text = "$($protected.Count)"
    $ui.TxtSubtitle.Text = switch ($protected.Count) {
        0 { 'No open apps to protect' }
        1 { 'Protecting 1 open app' }
        default { "Protecting $($protected.Count) open apps" }
    }

    $script:IconQueue.Clear()
    $ui.PnlTargetApps.Children.Clear()
    $ui.PnlProtectedApps.Children.Clear()

    for ($i = 0; $i -lt $groups.Count; $i++) {
        $g = $groups[$i]
        $title = if ($g.Friendly) { $g.Friendly } else { $g.Name }
        $countText = if ($g.Count -eq 1) { '1 process' } else { "$($g.Count) processes" }
        $subtitle = if ($title -ieq $g.Name) { $countText } else { "$($g.Name) $Dot $countText" }
        $index = if ($script:ActiveTab -eq 'Background') { $i } else { -1 }
        [void]$ui.PnlTargetApps.Children.Add((New-AppRow -Title $title -Subtitle $subtitle -Trailing (Format-Bytes $g.Bytes) -Path $g.Path -KillName $g.Name -Protected $false -Last ($i -eq $groups.Count - 1) -Index $index))
    }
    for ($i = 0; $i -lt $protected.Count; $i++) {
        $p = $protected[$i]
        $title = if ($p.Friendly) { $p.Friendly } else { $p.Name }
        $index = if ($script:ActiveTab -eq 'Protected') { $i } else { -1 }
        [void]$ui.PnlProtectedApps.Children.Add((New-AppRow -Title $title -Subtitle $p.Title -Trailing '' -Path $p.Path -KillName $p.Name -Protected $true -Last ($i -eq $protected.Count - 1) -Index $index))
    }
    if ($script:IconQueue.Count -gt 0) { $script:IconTimer.Start() }

    Update-Hero ([double]$data.TotalBytes) ([double]$data.PhysicalBytes)
    Update-PurgeButton
    Update-EmptyState
}

# Extra never-kill names from targets.json ("whitelistProcesses"), so anyone can protect their own apps
function Get-UserWhitelist {
    try {
        if (Test-Path $configFile) { return @((Get-Content -Raw -Path $configFile | ConvertFrom-Json).whitelistProcesses) }
    } catch {}
    return @()
}

function Start-Scan {
    if ($script:Scanning) { $script:ScanQueued = $true; return }
    $script:Scanning = $true
    Start-Spin $ui.RescanSpin 900
    Invoke-Async $ScanWork @{ CoreWhitelist = $coreOSWhitelist; UserWhitelist = (Get-UserWhitelist) } {
        param($data)
        $script:Scanning = $false
        Stop-Spin $ui.RescanSpin
        if ($data) { Update-FromScan $data }
        if ($script:ScanQueued) { $script:ScanQueued = $false; Start-Scan }
        # Give back the transient scan objects once the list has settled
        Invoke-Later 1500 { [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers() }
    }
}

# ---------------------------------------------------------------------------------------------------------------
# HUD
# ---------------------------------------------------------------------------------------------------------------
$script:HudTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:HudTimer.Interval = [TimeSpan]::FromMilliseconds(3400)
$script:HudTimer.Add_Tick({
    $script:HudTimer.Stop()
    Fade $ui.Hud 0 240
    [LiquidGlass.Motion]::Ease($hudShift, [System.Windows.Media.TranslateTransform]::YProperty, -10, 240)
    [LiquidGlass.GlassSurface]::TrackAll(300)
})

function Show-Hud([string]$Title, [string]$Body, [string]$Kind = 'success') {
    $ui.HudTitle.Text = $Title
    $ui.HudBody.Text = $Body
    switch ($Kind) {
        'warning' { $ui.HudBadge.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'Orange'); $ui.HudGlyph.Data = [System.Windows.Media.Geometry]::Parse($Glyphs.Alert) }
        'info'    { $ui.HudBadge.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'Blue'); $ui.HudGlyph.Data = [System.Windows.Media.Geometry]::Parse($Glyphs.Info) }
        default   { $ui.HudBadge.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'Green'); $ui.HudGlyph.Data = [System.Windows.Media.Geometry]::Parse($Glyphs.Check) }
    }
    $ui.Hud.Visibility = 'Visible'
    $hudShift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
    $hudShift.Y = -16
    $hudScale.ScaleX = 0.94
    $hudScale.ScaleY = 0.94
    Fade $ui.Hud 1 120
    [LiquidGlass.Motion]::Spring($hudShift, [System.Windows.Media.TranslateTransform]::YProperty, 0, 460, 0.3)
    [LiquidGlass.Motion]::Spring($hudScale, [System.Windows.Media.ScaleTransform]::ScaleXProperty, 1, 460, 0.3)
    [LiquidGlass.Motion]::Spring($hudScale, [System.Windows.Media.ScaleTransform]::ScaleYProperty, 1, 460, 0.3)
    [LiquidGlass.GlassSurface]::TrackAll(900)
    $script:HudTimer.Stop()
    $script:HudTimer.Start()
}

# ---------------------------------------------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------------------------------------------
function Kill-SpecificProcess ($procName) {
    if ([string]::IsNullOrWhiteSpace($procName)) { return }

    $forbidden = @("System", "Idle", "Registry", "smss", "csrss", "wininit", "services", "lsass", "winlogon", "dwm", "sihost", "explorer", "powershell", "pwsh", "Antigravity IDE")
    if ($procName -in $forbidden) {
        Show-Hud "Can't End $procName" 'It is a critical system process.' 'warning'
        return
    }

    Invoke-Async $KillWork @{ Name = $procName; WhatIf = [bool]$SimulateOnly } {
        param($result)
        $n = if ($result) { [int]$result.Killed } else { 0 }
        $what = if ($n -eq 1) { '1 instance' } else { "$n instances" }
        if ($SimulateOnly) { Show-Hud "Would End $($result.Name)" "$what $Dot simulation, nothing was closed" 'info' }
        else { Show-Hud "Ended $($result.Name)" "$what terminated" 'success' }
        Invoke-Later 350 { Start-Scan }
    }
}

function Start-Purge {
    if ($script:Busy -or $script:Scanning) { return }
    if (@($script:CurrentTargetsToKill).Count -eq 0) {
        if ($script:HasScanned) { Show-Hud 'All Clear' 'Nothing is running in the background.' 'success' }
        return
    }
    $script:Busy = $true
    Update-PurgeButton
    $i = 0
    foreach ($row in $ui.PnlTargetApps.Children) {
        $dim = [System.Windows.Media.Animation.DoubleAnimation]::new(0.35, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(260)))
        $dim.BeginTime = [TimeSpan]::FromMilliseconds([Math]::Min($i, 16) * 18)
        $row.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $dim)
        $i++
    }

    $targets = @(foreach ($p in $script:CurrentTargetsToKill) {
        $ws = [long]0
        try { $ws = $p.WorkingSet64 } catch {}
        [PSCustomObject]@{ Id = $p.Id; Name = $p.ProcessName; WorkingSet = $ws }
    })
    Invoke-Async $PurgeWork @{ Targets = $targets; Services = $script:ServicesToStop; IsAdmin = [bool]$isAdmin; SafeNames = @($script:SafeProcNames); WhatIf = [bool]$SimulateOnly } {
        param($result)
        $script:Busy = $false
        $killed = if ($result) { [int]$result.Killed } else { 0 }
        $freed = Format-Bytes $(if ($result) { [double]$result.Bytes } else { 0 })
        $noun = if ($killed -eq 1) { 'process' } else { 'processes' }
        if ($SimulateOnly) { Show-Hud "Would Free $freed" "$killed background $noun $Dot simulation" 'info' }
        else { Show-Hud "Freed $freed" "Closed $killed background $noun" 'success' }
        Update-PurgeButton
        # Allow OS kernel 600ms to finalize process teardown before updating the UI
        Invoke-Later 600 { Start-Scan }
    }
}

function Open-Config {
    if (Test-Path $configFile) {
        Start-Process "notepad.exe" -ArgumentList "`"$configFile`""
    }
}

function Close-Animated {
    if ($script:Closing) { return }
    $script:Closing = $true
    Fade $ui.Root 0 120
    Invoke-Later 130 { $window.Close() }
}

# ---------------------------------------------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------------------------------------------
$ui.TitleBar.Add_MouseLeftButtonDown({ param($s, $e) if ($e.ClickCount -eq 1) { try { $window.DragMove() } catch {} } })
$ui.BtnClose.Add_Click({ Close-Animated })
$ui.BtnMinimize.Add_Click({ $window.WindowState = [System.Windows.WindowState]::Minimized })
$ui.Traffic.Add_MouseEnter({ Fade $ui.GlyphClose 1 100; Fade $ui.GlyphMin 1 100 })
$ui.Traffic.Add_MouseLeave({ Fade $ui.GlyphClose 0 160; Fade $ui.GlyphMin 0 160 })
$ui.BtnRescan.Add_Click({ Start-Scan })
$ui.BtnConfig.Add_Click({ Open-Config })
$ui.BtnPurge.Add_Click({ Start-Purge })
$ui.TabBackground.Add_Click({ Select-Tab 'Background' })
$ui.TabProtected.Add_Click({ Select-Tab 'Protected' })
$ui.SegTrack.Add_SizeChanged({ Update-ThumbGeometry })

$window.Add_Activated({ Update-WindowActiveState })
$window.Add_Deactivated({ Update-WindowActiveState })


$window.Add_PreviewKeyDown({
    param($s, $e)
    $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    if ($e.Key -eq 'F5' -or ($ctrl -and $e.Key -eq 'R')) { Start-Scan; $e.Handled = $true }
    elseif ($e.Key -eq 'Escape' -or ($ctrl -and $e.Key -eq 'W')) { Close-Animated; $e.Handled = $true }
    elseif ($ctrl -and $e.Key -eq 'D1') { Select-Tab 'Background'; $e.Handled = $true }
    elseif ($ctrl -and $e.Key -eq 'D2') { Select-Tab 'Protected'; $e.Handled = $true }
    elseif ($ctrl -and $e.Key -eq 'OemComma') { Open-Config; $e.Handled = $true }
})

$window.Add_SourceInitialized({
    $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
    # Clear glass with a light live blur of whatever is behind; Windows 11 rounds and clips it
    [LiquidGlass.Native]::RoundDwmCorners($hwnd)
    [void][LiquidGlass.Native]::EnableBlurBehind($hwnd)
    $script:Watcher = [LiquidGlass.SystemWatcher]::new($window)
    $script:Watcher.add_Changed({
        param($kind)
        if ($kind -eq 'theme' -and $ThemeOption -eq 'Auto') {
            $name = Resolve-ThemeName
            if ($name -ne $script:ThemeName) { Set-Theme $name }
        }
    })
})

# Materialize: the glass pane appears and its content fades in
$ui.Root.Opacity = 0
$window.Add_ContentRendered({
    Fade $ui.Root 1 220
    [LiquidGlass.GlassSurface]::TrackAll(600)
})

$window.Add_Closed({
    try { $script:Pool.Close() } catch {}
    # Troubleshooting: set PROCESSPURGE_DEBUGLOG to a file path to capture any script errors raised by the UI
    if ($env:PROCESSPURGE_DEBUGLOG) {
        try { $Error | ForEach-Object { "$_`r`n$($_.InvocationInfo.PositionMessage)`r`n" } | Out-File -FilePath $env:PROCESSPURGE_DEBUGLOG -Encoding utf8 } catch {}
    }
})

Update-PurgeButton
Select-Tab 'Background' $false

# Initial Scan & Show (the scan runs in the background while the window materializes)
Start-Scan
$window.ShowDialog() | Out-Null
