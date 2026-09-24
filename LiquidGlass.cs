// Liquid Glass rendering engine for Process Purge (WPF, C# 5 so Windows PowerShell's Add-Type can compile it).
// Glass is drawn with a runtime-compiled ps_3_0 lens shader (d3dcompiler_47.dll ships with Windows 10/11)
// when the GPU path is unavailable every surface degrades to classic frosted glass.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Media.Media3D;
using System.Windows.Shapes;

namespace LiquidGlass
{
    // ------------------------------------------------------------------ shader
    [ComImport, Guid("8BA5FB08-5195-40e2-AC58-0D989C3A0102"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ID3DBlob
    {
        [PreserveSig] IntPtr GetBufferPointer();
        [PreserveSig] IntPtr GetBufferSize();
    }

    public static class Lens
    {
        // SDF rounded-rect lens modelled on Apple's glassBackground filter: a convex bezel that samples inward
        // (magnifying toward the rim) plus a thin outer band that pulls in content from just past the edge,
        // subtle chromatic dispersion, tone-mapping + vibrancy, colour-bleeding diagonal rim glints, a 1px inner
        // stroke and a pointer glow.
        public const string Hlsl = @"
sampler2D Input : register(s0);
float4 Geo    : register(c0); // x,y host size (DIP)  z corner radius  w bezel width
float4 Optics : register(c1); // x inset  y inner refraction (DIP)  z dispersion  w saturation
float4 Tint   : register(c2); // straight rgba; tint is modulated by backdrop luminance like coloured glass
float4 Light  : register(c3); // x,y direction toward the key light  z glint band (DIP)  w inner stroke alpha
float4 Glow   : register(c4); // x,y centre (uv)  z radius (DIP)  w intensity
float4 Misc   : register(c5); // x glint amount  y px per DIP  z edge volume  w brightness
float4 Band   : register(c6); // x outer refraction (DIP)  y outer band width (DIP)  z bezel profile exponent
float4 Tone   : register(c7); // x,y luminance remap range  z white face alpha

float4 main(float2 uv : TEXCOORD) : COLOR
{
    float2 size = Geo.xy;
    float2 p = (uv - 0.5) * size;
    float2 hs = size * 0.5 - Optics.x;
    float r = min(Geo.z, min(hs.x, hs.y));
    float2 q = abs(p) - hs + r;
    float2 qc = max(q, 0);
    float lq = length(qc);
    float inside = r - lq - min(max(q.x, q.y), 0);

    float2 axis = (q.x > q.y) ? float2(1, 0) : float2(0, 1);
    float2 n = (lq > 0.001) ? qc / max(lq, 0.0001) : axis;
    n *= (p < 0) ? -1 : 1;

    float x = saturate(inside / Geo.w);
    float inner = Optics.y * pow(1 - x, Band.z);
    float ob = saturate(1 - inside / Band.y);
    float outer = Band.x * ob * ob;
    float2 dUv = n * (outer - inner) / size;

    float4 cG = tex2D(Input, uv + dUv);
    float cR = tex2D(Input, uv + dUv * (1 + Optics.z)).r;
    float cB = tex2D(Input, uv + dUv * (1 - Optics.z)).b;
    float3 col = float3(cR, cG.g, cB) / max(cG.a, 0.001);

    float luma = dot(col, float3(0.2126, 0.7152, 0.0722));
    col = lerp(luma.xxx, col, Optics.w);
    col = lerp(Tone.xxx, Tone.yyy, col) * Misc.w;
    col = lerp(col, 1, Tone.z);
    col = lerp(col, Tint.rgb * (0.72 + 0.56 * luma), Tint.a);

    float3 vib;
    vib.r = dot(col, float3(2.6705, -1.1088, -0.1117));
    vib.g = dot(col, float3(-0.3295, 1.8914, -0.1119));
    vib.b = dot(col, float3(-0.3297, -1.1084, 2.8881));
    vib = saturate(vib + 0.05);
    float3 glintCol = lerp(vib, 1, 0.55);

    float facing = dot(n, Light.xy);
    float band = saturate(1 - inside / Light.z);
    band *= band;
    float glint = band * (pow(saturate(facing), 1.7) + 0.7 * pow(saturate(-facing), 1.7)) * Misc.x;
    col = lerp(col, glintCol, saturate(glint));
    float stroke = saturate(1.25 - inside * Misc.y);
    col = lerp(col, 1, stroke * Light.w);
    col *= 1 - saturate(1 - x) * saturate(1 - x) * Misc.z * saturate(0.4 - 0.6 * facing);

    float2 gp = (uv - Glow.xy) * size;
    float g = saturate(1 - length(gp) / Glow.z);
    col += g * g * Glow.w;

    float aa = saturate(inside * Misc.y + 0.5);
    float alpha = lerp(cG.a, 1, Tint.a);
    return float4(col, 1) * (aa * alpha);
}";

        [DllImport("d3dcompiler_47.dll", CharSet = CharSet.Ansi)]
        static extern int D3DCompile(
            [MarshalAs(UnmanagedType.LPStr)] string srcData, IntPtr srcDataSize,
            [MarshalAs(UnmanagedType.LPStr)] string sourceName, IntPtr defines, IntPtr include,
            [MarshalAs(UnmanagedType.LPStr)] string entryPoint, [MarshalAs(UnmanagedType.LPStr)] string target,
            uint flags1, uint flags2, out ID3DBlob code, out ID3DBlob errorMsgs);

        public static PixelShader Shader;
        public static bool Supported;
        public static string Error;

        /// Compiles the lens shader. Returns false (and every GlassSurface falls back to frosted glass)
        /// when hardware pixel shaders are unavailable, e.g. over RDP or on software rendering.
        public static bool Initialize()
        {
            Supported = false;
            try
            {
                if ((RenderCapability.Tier >> 16) < 2) { Error = "hardware rendering tier < 2"; return false; }
                if (!RenderCapability.IsPixelShaderVersionSupported(3, 0)) { Error = "ps_3_0 not supported"; return false; }
                ID3DBlob code, err;
                int hr = D3DCompile(Hlsl, (IntPtr)Encoding.ASCII.GetByteCount(Hlsl), "lens", IntPtr.Zero, IntPtr.Zero,
                                    "main", "ps_3_0", (1u << 15), 0, out code, out err);
                if (err != null)
                {
                    Error = Marshal.PtrToStringAnsi(err.GetBufferPointer(), (int)err.GetBufferSize());
                    Marshal.ReleaseComObject(err);
                }
                if (hr < 0 || code == null) return false;
                int n = (int)code.GetBufferSize();
                byte[] bytes = new byte[n];
                Marshal.Copy(code.GetBufferPointer(), bytes, 0, n);
                Marshal.ReleaseComObject(code);
                PixelShader ps = new PixelShader();
                ps.SetStreamSource(new MemoryStream(bytes));
                ps.Freeze();
                Shader = ps;
                Supported = true;
                return true;
            }
            catch (Exception ex) { Error = ex.Message; return false; }
        }
    }

    public class LensEffect : ShaderEffect
    {
        public LensEffect()
        {
            PixelShader = Lens.Shader;
            UpdateShaderValue(InputProperty);
            UpdateShaderValue(GeoProperty);
            UpdateShaderValue(OpticsProperty);
            UpdateShaderValue(TintProperty);
            UpdateShaderValue(LightProperty);
            UpdateShaderValue(GlowProperty);
            UpdateShaderValue(MiscProperty);
            UpdateShaderValue(BandProperty);
            UpdateShaderValue(ToneProperty);
        }

        static DependencyProperty C(string name, object def, int reg)
        {
            return DependencyProperty.Register(name, def.GetType(), typeof(LensEffect), new UIPropertyMetadata(def, PixelShaderConstantCallback(reg)));
        }

        public static readonly DependencyProperty InputProperty = ShaderEffect.RegisterPixelShaderSamplerProperty("Input", typeof(LensEffect), 0);
        public static readonly DependencyProperty GeoProperty = C("Geo", new Point4D(100, 40, 20, 14), 0);
        public static readonly DependencyProperty OpticsProperty = C("Optics", new Point4D(0, 10, 0.1, 1.2), 1);
        public static readonly DependencyProperty TintProperty = C("Tint", Color.FromArgb(0, 0, 0, 0), 2);
        public static readonly DependencyProperty LightProperty = C("Light", new Point4D(0.5, 0.866, 2, 0.05), 3);
        public static readonly DependencyProperty GlowProperty = C("Glow", new Point4D(0.5, 0.5, 60, 0), 4);
        public static readonly DependencyProperty MiscProperty = C("Misc", new Point4D(0.6, 1.25, 0.2, 1), 5);
        public static readonly DependencyProperty BandProperty = C("Band", new Point4D(4, 5, 3, 0), 6);
        public static readonly DependencyProperty ToneProperty = C("Tone", new Point4D(0, 1, 0, 0), 7);

        public Brush Input { get { return (Brush)GetValue(InputProperty); } set { SetValue(InputProperty, value); } }
        public Point4D Geo { get { return (Point4D)GetValue(GeoProperty); } set { SetValue(GeoProperty, value); } }
        public Point4D Optics { get { return (Point4D)GetValue(OpticsProperty); } set { SetValue(OpticsProperty, value); } }
        public Color Tint { get { return (Color)GetValue(TintProperty); } set { SetValue(TintProperty, value); } }
        public Point4D Light { get { return (Point4D)GetValue(LightProperty); } set { SetValue(LightProperty, value); } }
        public Point4D Glow { get { return (Point4D)GetValue(GlowProperty); } set { SetValue(GlowProperty, value); } }
        public Point4D Misc { get { return (Point4D)GetValue(MiscProperty); } set { SetValue(MiscProperty, value); } }
        public Point4D Band { get { return (Point4D)GetValue(BandProperty); } set { SetValue(BandProperty, value); } }
        public Point4D Tone { get { return (Point4D)GetValue(ToneProperty); } set { SetValue(ToneProperty, value); } }
    }

    // ------------------------------------------------------------------ motion
    /// SwiftUI-style spring (WWDC23 "Animate with springs"): Bounce 0 = .smooth, 0.15 = .snappy, 0.3 = .bouncy.
    /// The animation's Duration should be ~1.5x the perceptual duration so the spring fully settles.
    public class SpringEase : EasingFunctionBase
    {
        public static readonly DependencyProperty BounceProperty =
            DependencyProperty.Register("Bounce", typeof(double), typeof(SpringEase), new PropertyMetadata(0.15));
        public double Bounce { get { return (double)GetValue(BounceProperty); } set { SetValue(BounceProperty, value); } }

        public SpringEase() { EasingMode = EasingMode.EaseOut; }
        public SpringEase(double bounce) : this() { Bounce = bounce; }

        public static double Spring(double t, double bounce)
        {
            double w0 = 3 * Math.PI;   // 2*pi / (1/1.5): the easing spans 1.5 perceptual durations
            double z = bounce >= 0 ? 1 - bounce : 1 / (1 + bounce);
            if (z >= 0.999) return 1 - Math.Exp(-w0 * t) * (1 + w0 * t);
            double wd = w0 * Math.Sqrt(1 - z * z);
            return 1 - Math.Exp(-z * w0 * t) * (Math.Cos(wd * t) + (z * w0 / wd) * Math.Sin(wd * t));
        }

        protected override double EaseInCore(double normalizedTime) { return 1 - Spring(1 - normalizedTime, Bounce); }
        protected override Freezable CreateInstanceCore() { return new SpringEase(); }
    }

    public static class Motion
    {
        public static void To(IAnimatable target, DependencyProperty dp, double to, double ms, IEasingFunction ease)
        {
            DoubleAnimation a = new DoubleAnimation(to, new Duration(TimeSpan.FromMilliseconds(ms)));
            a.EasingFunction = ease;
            target.BeginAnimation(dp, a, HandoffBehavior.SnapshotAndReplace);
        }

        /// ms is the perceptual duration; the animation runs 1.5x that so the spring settles.
        public static void Spring(IAnimatable target, DependencyProperty dp, double to, double ms, double bounce)
        {
            To(target, dp, to, ms * 1.5, new SpringEase(bounce));
        }

        public static void Ease(IAnimatable target, DependencyProperty dp, double to, double ms)
        {
            CubicEase e = new CubicEase(); e.EasingMode = EasingMode.EaseOut;
            To(target, dp, to, ms, e);
        }
    }

    // ------------------------------------------------------------------ glass surface
    /// A rounded rectangle (or capsule) of Liquid Glass. It samples a backdrop visual (SourceName / Source),
    /// optionally blurs it, bends it through the lens shader, and hosts arbitrary content on top.
    public class GlassSurface : Grid
    {
        static readonly List<WeakReference> Live = new List<WeakReference>();
        static int _trackUntil;
        static bool _tracking;
        public static Point LightDirection = new Point(0.5, 0.866);

        readonly Border _shadow;
        readonly Grid _wrapper;
        readonly Border _host;
        readonly Border _clipper;
        readonly Rectangle _rect;
        readonly VisualBrush _brush;
        readonly BlurEffect _blur;
        readonly LensEffect _fx;
        readonly Border _fallbackTint;
        readonly Border _fallbackRim;
        readonly RectangleGeometry _clip;
        readonly ScaleTransform _scale;
        readonly WeakReference _self;
        Rect _lastViewbox = Rect.Empty;
        double _pxPerDip = 1.0;
        bool _hover, _pressed;

        public GlassSurface()
        {
            _self = new WeakReference(this);
            _shadow = new Border();
            _shadow.Background = Brushes.Black;
            _shadow.Margin = new Thickness(1.5);
            _shadow.IsHitTestVisible = false;
            DropShadowEffect ds = new DropShadowEffect();
            ds.Direction = 270; ds.Color = Colors.Black;
            _shadow.Effect = ds;

            _wrapper = new Grid();
            _wrapper.IsHitTestVisible = false;
            _clip = new RectangleGeometry();
            _wrapper.Clip = _clip;

            _host = new Border();
            _clipper = new Border();
            _clipper.ClipToBounds = true;
            _rect = new Rectangle();
            _brush = new VisualBrush();
            _brush.AutoLayoutContent = false;
            _brush.ViewboxUnits = BrushMappingMode.Absolute;
            _brush.Stretch = Stretch.Fill;
            _brush.AlignmentX = AlignmentX.Left;
            _brush.AlignmentY = AlignmentY.Top;
            _rect.Fill = _brush;
            _blur = new BlurEffect();
            _blur.KernelType = KernelType.Gaussian;
            _clipper.Child = _rect;
            _host.Child = _clipper;
            _wrapper.Children.Add(_host);

            _fallbackTint = new Border();
            _fallbackTint.IsHitTestVisible = false;
            _fallbackRim = new Border();
            _fallbackRim.IsHitTestVisible = false;
            _fallbackRim.BorderThickness = new Thickness(1);
            LinearGradientBrush rim = new LinearGradientBrush();
            rim.StartPoint = new Point(0, 0); rim.EndPoint = new Point(0.6, 1);
            rim.GradientStops.Add(new GradientStop(Color.FromArgb(0x8C, 255, 255, 255), 0));
            rim.GradientStops.Add(new GradientStop(Color.FromArgb(0x14, 255, 255, 255), 0.5));
            rim.GradientStops.Add(new GradientStop(Color.FromArgb(0x38, 255, 255, 255), 1));
            rim.Freeze();
            _fallbackRim.BorderBrush = rim;

            if (Lens.Supported)
            {
                _fx = new LensEffect();
                _host.Effect = _fx;
            }

            Children.Add(_shadow);
            Children.Add(_wrapper);
            Children.Add(_fallbackTint);
            Children.Add(_fallbackRim);

            _scale = new ScaleTransform(1, 1);
            RenderTransform = _scale;
            RenderTransformOrigin = new Point(0.5, 0.5);

            SizeChanged += delegate { Refresh(); };
            Loaded += OnLoaded;
            Unloaded += delegate
            {
                LayoutUpdated -= OnLayoutUpdated;
                lock (Live) Live.Remove(_self);
            };
            MouseEnter += delegate { if (!Interactive) return; _hover = true; AnimateGlow(); };
            MouseLeave += delegate { if (!Interactive) return; _hover = false; _pressed = false; AnimateGlow(); AnimatePress(); };
            MouseMove += OnPointerMove;
            PreviewMouseLeftButtonDown += delegate(object s, MouseButtonEventArgs e) { if (!Interactive) return; _pressed = true; OnPointerMove(s, e); AnimateGlow(); AnimatePress(); };
            PreviewMouseLeftButtonUp += delegate { if (!Interactive) return; _pressed = false; AnimateGlow(); AnimatePress(); };
            Refresh();
        }

        void OnLoaded(object sender, RoutedEventArgs e)
        {
            PresentationSource src = PresentationSource.FromVisual(this);
            if (src != null && src.CompositionTarget != null) _pxPerDip = src.CompositionTarget.TransformToDevice.M11;
            if (Source == null && !string.IsNullOrEmpty(SourceName))
            {
                FrameworkElement scope = this;
                Window w = Window.GetWindow(this);
                object found = w != null ? w.FindName(SourceName) : null;
                if (found == null) found = scope.FindName(SourceName);
                Visual v = found as Visual;
                if (v != null) Source = v;
            }
            LayoutUpdated -= OnLayoutUpdated;
            LayoutUpdated += OnLayoutUpdated;
            lock (Live) { if (!Live.Contains(_self)) Live.Add(_self); }
            Refresh();
        }

        // ---------- dependency properties ----------
        static void Changed(DependencyObject d, DependencyPropertyChangedEventArgs e) { ((GlassSurface)d).Refresh(); }
        static DependencyProperty Reg(string name, Type t, object def)
        {
            return DependencyProperty.Register(name, t, typeof(GlassSurface), new FrameworkPropertyMetadata(def, Changed));
        }

        public static readonly DependencyProperty SourceProperty = Reg("Source", typeof(Visual), null);
        public static readonly DependencyProperty SourceNameProperty = Reg("SourceName", typeof(string), null);
        public static readonly DependencyProperty CornerRadiusProperty = Reg("CornerRadius", typeof(double), 20.0);
        public static readonly DependencyProperty BlurRadiusProperty = Reg("BlurRadius", typeof(double), 0.0);
        public static readonly DependencyProperty RefractionProperty = Reg("Refraction", typeof(double), 8.0);
        public static readonly DependencyProperty BezelProperty = Reg("Bezel", typeof(double), 12.5);
        public static readonly DependencyProperty ProfileProperty = Reg("Profile", typeof(double), 3.0);
        public static readonly DependencyProperty OuterRefractionProperty = Reg("OuterRefraction", typeof(double), 3.0);
        public static readonly DependencyProperty OuterBandProperty = Reg("OuterBand", typeof(double), 5.0);
        public static readonly DependencyProperty DispersionProperty = Reg("Dispersion", typeof(double), 0.06);
        public static readonly DependencyProperty SaturationProperty = Reg("Saturation", typeof(double), 1.2);
        public static readonly DependencyProperty BrightnessProperty = Reg("Brightness", typeof(double), 1.0);
        public static readonly DependencyProperty ToneMinProperty = Reg("ToneMin", typeof(double), 0.0);
        public static readonly DependencyProperty ToneMaxProperty = Reg("ToneMax", typeof(double), 1.0);
        public static readonly DependencyProperty FaceProperty = Reg("Face", typeof(double), 0.03);
        public static readonly DependencyProperty GlintProperty = Reg("Glint", typeof(double), 0.8);
        public static readonly DependencyProperty GlintBandProperty = Reg("GlintBand", typeof(double), 2.5);
        public static readonly DependencyProperty StrokeProperty = Reg("Stroke", typeof(double), 0.14);
        public static readonly DependencyProperty VolumeProperty = Reg("Volume", typeof(double), 0.15);
        public static readonly DependencyProperty TintColorProperty = Reg("TintColor", typeof(Color), Color.FromArgb(0, 0, 0, 0));
        public static readonly DependencyProperty ShadowOpacityProperty = Reg("ShadowOpacity", typeof(double), 0.18);
        public static readonly DependencyProperty ShadowBlurProperty = Reg("ShadowBlur", typeof(double), 24.0);
        public static readonly DependencyProperty ShadowDepthProperty = Reg("ShadowDepth", typeof(double), 6.0);
        public static readonly DependencyProperty GlowProperty = Reg("Glow", typeof(double), 0.0);
        public static readonly DependencyProperty GlowPointProperty = Reg("GlowPoint", typeof(Point), new Point(0.5, 0.5));
        public static readonly DependencyProperty GlowRadiusProperty = Reg("GlowRadius", typeof(double), 70.0);
        public static readonly DependencyProperty InteractiveProperty = Reg("Interactive", typeof(bool), false);
        public static readonly DependencyProperty HoverGlowProperty = Reg("HoverGlow", typeof(double), 0.05);
        public static readonly DependencyProperty PressGlowProperty = Reg("PressGlow", typeof(double), 0.2);
        public static readonly DependencyProperty PressScaleProperty = Reg("PressScale", typeof(double), 1.035);

        public Visual Source { get { return (Visual)GetValue(SourceProperty); } set { SetValue(SourceProperty, value); } }
        /// x:Name of the backdrop visual (resolved on Loaded). It must not be an ancestor of this surface.
        public string SourceName { get { return (string)GetValue(SourceNameProperty); } set { SetValue(SourceNameProperty, value); } }
        /// Negative = capsule.
        public double CornerRadius { get { return (double)GetValue(CornerRadiusProperty); } set { SetValue(CornerRadiusProperty, value); } }
        public double BlurRadius { get { return (double)GetValue(BlurRadiusProperty); } set { SetValue(BlurRadiusProperty, value); } }
        /// Inward (magnifying) displacement at the rim, in DIPs.
        public double Refraction { get { return (double)GetValue(RefractionProperty); } set { SetValue(RefractionProperty, value); } }
        /// Width of the curved bezel band; the centre beyond it is flat and undistorted.
        public double Bezel { get { return (double)GetValue(BezelProperty); } set { SetValue(BezelProperty, value); } }
        /// Falloff exponent of the bezel displacement (higher = concentrated closer to the rim).
        public double Profile { get { return (double)GetValue(ProfileProperty); } set { SetValue(ProfileProperty, value); } }
        /// Outward displacement of the thin outer band, in DIPs.
        public double OuterRefraction { get { return (double)GetValue(OuterRefractionProperty); } set { SetValue(OuterRefractionProperty, value); } }
        public double OuterBand { get { return (double)GetValue(OuterBandProperty); } set { SetValue(OuterBandProperty, value); } }
        public double Dispersion { get { return (double)GetValue(DispersionProperty); } set { SetValue(DispersionProperty, value); } }
        public double Saturation { get { return (double)GetValue(SaturationProperty); } set { SetValue(SaturationProperty, value); } }
        public double Brightness { get { return (double)GetValue(BrightnessProperty); } set { SetValue(BrightnessProperty, value); } }
        /// Backdrop luminance is remapped into [ToneMin, ToneMax] (dark glass ~0.08-0.40, light ~0.55-0.95).
        public double ToneMin { get { return (double)GetValue(ToneMinProperty); } set { SetValue(ToneMinProperty, value); } }
        public double ToneMax { get { return (double)GetValue(ToneMaxProperty); } set { SetValue(ToneMaxProperty, value); } }
        /// White "face" fill alpha laid over the tone-mapped backdrop.
        public double Face { get { return (double)GetValue(FaceProperty); } set { SetValue(FaceProperty, value); } }
        /// Strength of the diagonal specular glints (top-left key, bottom-right bounce).
        public double Glint { get { return (double)GetValue(GlintProperty); } set { SetValue(GlintProperty, value); } }
        public double GlintBand { get { return (double)GetValue(GlintBandProperty); } set { SetValue(GlintBandProperty, value); } }
        /// Alpha of the 1px inner edge stroke.
        public double Stroke { get { return (double)GetValue(StrokeProperty); } set { SetValue(StrokeProperty, value); } }
        public double Volume { get { return (double)GetValue(VolumeProperty); } set { SetValue(VolumeProperty, value); } }
        public Color TintColor { get { return (Color)GetValue(TintColorProperty); } set { SetValue(TintColorProperty, value); } }
        public double ShadowOpacity { get { return (double)GetValue(ShadowOpacityProperty); } set { SetValue(ShadowOpacityProperty, value); } }
        public double ShadowBlur { get { return (double)GetValue(ShadowBlurProperty); } set { SetValue(ShadowBlurProperty, value); } }
        public double ShadowDepth { get { return (double)GetValue(ShadowDepthProperty); } set { SetValue(ShadowDepthProperty, value); } }
        public double Glow { get { return (double)GetValue(GlowProperty); } set { SetValue(GlowProperty, value); } }
        /// Glow centre relative to the surface (0..1).
        public Point GlowPoint { get { return (Point)GetValue(GlowPointProperty); } set { SetValue(GlowPointProperty, value); } }
        public double GlowRadius { get { return (double)GetValue(GlowRadiusProperty); } set { SetValue(GlowRadiusProperty, value); } }
        /// Hover light that follows the pointer and a springy press.
        public bool Interactive { get { return (bool)GetValue(InteractiveProperty); } set { SetValue(InteractiveProperty, value); } }
        public double HoverGlow { get { return (double)GetValue(HoverGlowProperty); } set { SetValue(HoverGlowProperty, value); } }
        public double PressGlow { get { return (double)GetValue(PressGlowProperty); } set { SetValue(PressGlowProperty, value); } }
        public double PressScale { get { return (double)GetValue(PressScaleProperty); } set { SetValue(PressScaleProperty, value); } }

        // ---------- interaction ----------
        void OnPointerMove(object sender, MouseEventArgs e)
        {
            if (!Interactive || ActualWidth <= 0 || ActualHeight <= 0) return;
            Point p = e.GetPosition(this);
            GlowPoint = new Point(p.X / ActualWidth, p.Y / ActualHeight);
        }

        void AnimateGlow()
        {
            double target = _pressed ? PressGlow : (_hover ? HoverGlow : 0);
            Motion.Ease(this, GlowProperty, target, _pressed ? 90 : 260);
        }

        void AnimatePress()
        {
            double s = _pressed ? PressScale : 1.0;
            if (_pressed)
            {
                Motion.Ease(_scale, ScaleTransform.ScaleXProperty, s, 120);
                Motion.Ease(_scale, ScaleTransform.ScaleYProperty, s, 120);
            }
            else
            {
                Motion.Spring(_scale, ScaleTransform.ScaleXProperty, s, 450, 0.35);
                Motion.Spring(_scale, ScaleTransform.ScaleYProperty, s, 450, 0.35);
            }
            TrackAll(750);
        }

        // ---------- layout / rendering ----------
        double Radius()
        {
            double w = ActualWidth, h = ActualHeight;
            double r = CornerRadius;
            if (r < 0 || r > Math.Min(w, h) / 2) r = Math.Min(w, h) / 2;
            return Math.Max(0, r);
        }

        double LensMargin() { return _fx == null ? 0 : Math.Ceiling(Math.Max(0, OuterRefraction) * (1 + Dispersion) + 2); }
        double BlurPad() { return BlurRadius > 0 ? Math.Ceiling(BlurRadius) + 2 : 0; }

        public void Refresh()
        {
            double w = ActualWidth, h = ActualHeight;
            double r = Radius();
            PresentationSource ps = IsLoaded ? PresentationSource.FromVisual(this) : null;
            if (ps != null && ps.CompositionTarget != null) _pxPerDip = ps.CompositionTarget.TransformToDevice.M11;
            _clip.Rect = new Rect(0, 0, Math.Max(0, w), Math.Max(0, h));
            _clip.RadiusX = r; _clip.RadiusY = r;

            _shadow.CornerRadius = new System.Windows.CornerRadius(r);
            DropShadowEffect ds = (DropShadowEffect)_shadow.Effect;
            ds.Opacity = ShadowOpacity; ds.BlurRadius = ShadowBlur; ds.ShadowDepth = ShadowDepth;
            _shadow.Visibility = ShadowOpacity > 0 ? Visibility.Visible : Visibility.Collapsed;

            double m = LensMargin();
            double pad = BlurPad();
            _host.Margin = new Thickness(-m);
            _rect.Margin = new Thickness(-pad);
            _rect.Effect = BlurRadius > 0 ? _blur : null;
            if (_blur.Radius != BlurRadius) _blur.Radius = BlurRadius;
            if (_brush.Visual != Source) _brush.Visual = Source;

            Color t = TintColor;
            if (_fx != null)
            {
                _fallbackTint.Visibility = Visibility.Collapsed;
                _fallbackRim.Visibility = Visibility.Collapsed;
                double bezel = Math.Max(1, Math.Min(Bezel, Math.Min(w, h) / 2));
                _fx.Geo = new Point4D(w + 2 * m, h + 2 * m, r, bezel);
                _fx.Optics = new Point4D(m, Refraction, Dispersion, Saturation);
                _fx.Tint = t;
                Point L = LightDirection;
                _fx.Light = new Point4D(-L.X, -L.Y, Math.Max(0.5, GlintBand), Stroke);
                Point gp = GlowPoint;
                double gu = (gp.X * w + m) / Math.Max(1, w + 2 * m);
                double gv = (gp.Y * h + m) / Math.Max(1, h + 2 * m);
                _fx.Glow = new Point4D(gu, gv, Math.Max(1, GlowRadius), Glow);
                _fx.Misc = new Point4D(Glint, _pxPerDip, Volume, Brightness);
                _fx.Band = new Point4D(OuterRefraction, Math.Max(0.5, OuterBand), Math.Max(0.5, Profile), 0);
                _fx.Tone = new Point4D(ToneMin, ToneMax, Face, 0);
            }
            else
            {
                _fallbackTint.Visibility = Visibility.Visible;
                _fallbackRim.Visibility = Visibility.Visible;
                _fallbackTint.CornerRadius = new System.Windows.CornerRadius(r);
                _fallbackRim.CornerRadius = new System.Windows.CornerRadius(r);
                byte a = (byte)Math.Min(255, t.A + 255 * Glow * 0.6);
                _fallbackTint.Background = new SolidColorBrush(Color.FromArgb(a, t.R, t.G, t.B));
            }
            SyncViewbox();
        }

        void OnLayoutUpdated(object sender, EventArgs e) { SyncViewbox(); }

        public void SyncViewbox()
        {
            Visual src = Source;
            if (src == null || !IsLoaded) return;
            try
            {
                double e = LensMargin() + BlurPad();
                GeneralTransform tr = TransformToVisual(src);
                Rect vb = tr.TransformBounds(new Rect(-e, -e, ActualWidth + 2 * e, ActualHeight + 2 * e));
                if (_lastViewbox.IsEmpty || Math.Abs(vb.X - _lastViewbox.X) > 0.01 || Math.Abs(vb.Y - _lastViewbox.Y) > 0.01 ||
                    Math.Abs(vb.Width - _lastViewbox.Width) > 0.01 || Math.Abs(vb.Height - _lastViewbox.Height) > 0.01)
                {
                    _lastViewbox = vb;
                    _brush.Viewbox = vb;
                }
            }
            catch (InvalidOperationException) { }
        }

        /// Keeps every live surface's backdrop aligned every frame for `ms` milliseconds ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â call it while
        /// render-transform animations (which don't trigger layout) are moving glass around.
        public static void TrackAll(int ms)
        {
            int until = Environment.TickCount + ms;
            if (until - _trackUntil > 0) _trackUntil = until;
            if (_tracking) return;
            _tracking = true;
            CompositionTarget.Rendering += OnRendering;
        }

        static void OnRendering(object sender, EventArgs e)
        {
            List<WeakReference> snapshot;
            lock (Live) snapshot = new List<WeakReference>(Live);
            foreach (WeakReference w in snapshot)
            {
                GlassSurface g = w.Target as GlassSurface;
                if (g != null) g.SyncViewbox();
            }
            if (Environment.TickCount - _trackUntil > 0)
            {
                CompositionTarget.Rendering -= OnRendering;
                _tracking = false;
            }
        }
    }

    // ------------------------------------------------------------------ ring gauge
    /// Apple-style progress ring with an angular gradient and round caps.
    public class Ring : FrameworkElement
    {
        static FrameworkPropertyMetadata Md(object def) { return new FrameworkPropertyMetadata(def, FrameworkPropertyMetadataOptions.AffectsRender); }
        public static readonly DependencyProperty ProgressProperty = DependencyProperty.Register("Progress", typeof(double), typeof(Ring), Md(0.0));
        public static readonly DependencyProperty StrokeWidthProperty = DependencyProperty.Register("StrokeWidth", typeof(double), typeof(Ring), Md(10.0));
        public static readonly DependencyProperty TrackBrushProperty = DependencyProperty.Register("TrackBrush", typeof(Brush), typeof(Ring), Md(new SolidColorBrush(Color.FromArgb(40, 255, 255, 255))));
        public static readonly DependencyProperty StartColorProperty = DependencyProperty.Register("StartColor", typeof(Color), typeof(Ring), Md(Color.FromRgb(255, 55, 95)));
        public static readonly DependencyProperty EndColorProperty = DependencyProperty.Register("EndColor", typeof(Color), typeof(Ring), Md(Color.FromRgb(255, 159, 10)));

        public double Progress { get { return (double)GetValue(ProgressProperty); } set { SetValue(ProgressProperty, value); } }
        public double StrokeWidth { get { return (double)GetValue(StrokeWidthProperty); } set { SetValue(StrokeWidthProperty, value); } }
        public Brush TrackBrush { get { return (Brush)GetValue(TrackBrushProperty); } set { SetValue(TrackBrushProperty, value); } }
        public Color StartColor { get { return (Color)GetValue(StartColorProperty); } set { SetValue(StartColorProperty, value); } }
        public Color EndColor { get { return (Color)GetValue(EndColorProperty); } set { SetValue(EndColorProperty, value); } }

        static Color Mix(Color a, Color b, double t)
        {
            return Color.FromArgb((byte)(a.A + (b.A - a.A) * t), (byte)(a.R + (b.R - a.R) * t), (byte)(a.G + (b.G - a.G) * t), (byte)(a.B + (b.B - a.B) * t));
        }

        static Point At(Point c, double r, double deg)
        {
            double rad = (deg - 90) * Math.PI / 180.0;
            return new Point(c.X + r * Math.Cos(rad), c.Y + r * Math.Sin(rad));
        }

        protected override void OnRender(DrawingContext dc)
        {
            double sw = StrokeWidth;
            double size = Math.Min(ActualWidth, ActualHeight);
            if (size <= sw) return;
            Point c = new Point(ActualWidth / 2, ActualHeight / 2);
            double r = size / 2 - sw / 2;
            dc.DrawEllipse(null, new Pen(TrackBrush, sw), c, r, r);

            double p = Math.Max(0, Math.Min(1, Progress));
            if (p <= 0.0005) return;
            double sweep = p * 360.0;
            int segs = Math.Max(1, (int)Math.Ceiling(sweep / 3.0));
            double step = sweep / segs;
            for (int i = 0; i < segs; i++)
            {
                double a0 = i * step, a1 = Math.Min(sweep, (i + 1) * step + 0.6);
                Color col = Mix(StartColor, EndColor, (i + 0.5) / segs);
                StreamGeometry g = new StreamGeometry();
                using (StreamGeometryContext ctx = g.Open())
                {
                    ctx.BeginFigure(At(c, r, a0), false, false);
                    ctx.ArcTo(At(c, r, a1), new Size(r, r), 0, (a1 - a0) > 180, SweepDirection.Clockwise, true, false);
                }
                g.Freeze();
                Pen pen = new Pen(new SolidColorBrush(col), sw);
                pen.StartLineCap = PenLineCap.Flat; pen.EndLineCap = PenLineCap.Flat;
                dc.DrawGeometry(null, pen, g);
            }
            // round caps
            dc.DrawEllipse(new SolidColorBrush(StartColor), null, At(c, r, 0), sw / 2, sw / 2);
            Point end = At(c, r, sweep);
            Color endCol = EndColor;
            dc.DrawEllipse(new SolidColorBrush(Color.FromArgb(70, 0, 0, 0)), null, new Point(end.X + 0.6, end.Y + 1.0), sw / 2 + 0.6, sw / 2 + 0.6);
            dc.DrawEllipse(new SolidColorBrush(endCol), null, end, sw / 2, sw / 2);
        }
    }

    // ------------------------------------------------------------------ smooth scrolling
    public static class SmoothScroll
    {
        class State { public double Target; public bool Running; public ScrollViewer Viewer; }

        public static readonly DependencyProperty EnabledProperty = DependencyProperty.RegisterAttached("Enabled", typeof(bool), typeof(SmoothScroll),
            new PropertyMetadata(false, OnEnabledChanged));
        public static bool GetEnabled(DependencyObject d) { return (bool)d.GetValue(EnabledProperty); }
        public static void SetEnabled(DependencyObject d, bool v) { d.SetValue(EnabledProperty, v); }

        static readonly DependencyProperty StateProperty = DependencyProperty.RegisterAttached("State", typeof(State), typeof(SmoothScroll));

        static void OnEnabledChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        {
            ScrollViewer sv = d as ScrollViewer;
            if (sv == null) return;
            if ((bool)e.NewValue)
            {
                State st = new State(); st.Viewer = sv;
                sv.SetValue(StateProperty, st);
                sv.PreviewMouseWheel += OnWheel;
            }
            else sv.PreviewMouseWheel -= OnWheel;
        }

        static void OnWheel(object sender, MouseWheelEventArgs e)
        {
            ScrollViewer sv = (ScrollViewer)sender;
            State st = (State)sv.GetValue(StateProperty);
            if (st == null || sv.ScrollableHeight <= 0) return;
            e.Handled = true;
            double from = st.Running ? st.Target : sv.VerticalOffset;
            st.Target = Math.Max(0, Math.Min(sv.ScrollableHeight, from - e.Delta * 0.85));
            if (!st.Running)
            {
                st.Running = true;
                EventHandler tick = null;
                tick = delegate
                {
                    double cur = sv.VerticalOffset;
                    double next = cur + (st.Target - cur) * 0.2;
                    if (Math.Abs(st.Target - next) < 0.5) next = st.Target;
                    sv.ScrollToVerticalOffset(next);
                    if (next == st.Target)
                    {
                        CompositionTarget.Rendering -= tick;
                        st.Running = false;
                    }
                };
                CompositionTarget.Rendering += tick;
            }
        }
    }

    // ------------------------------------------------------------------ symbols
    public static class Symbols
    {
        /// SF Symbols "gearshape"-style outline built from a toothed ring.
        public static Geometry Gear(double size, int teeth)
        {
            double c = size / 2, ro = size / 2, ri = size * 0.39, hole = size * 0.17;
            StreamGeometry g = new StreamGeometry();
            g.FillRule = FillRule.EvenOdd;
            using (StreamGeometryContext ctx = g.Open())
            {
                int n = teeth * 4;
                for (int i = 0; i < n; i++)
                {
                    double a = (i / (double)n) * Math.PI * 2 - Math.PI / 2 + Math.PI / n;
                    int phase = i % 4;
                    double rad = (phase == 0 || phase == 1) ? ro : ri;
                    Point pt = new Point(c + rad * Math.Cos(a), c + rad * Math.Sin(a));
                    if (i == 0) ctx.BeginFigure(pt, true, true); else ctx.LineTo(pt, true, true);
                }
                ctx.BeginFigure(new Point(c + hole, c), true, true);
                ctx.ArcTo(new Point(c - hole, c), new Size(hole, hole), 0, false, SweepDirection.Clockwise, true, true);
                ctx.ArcTo(new Point(c + hole, c), new Size(hole, hole), 0, false, SweepDirection.Clockwise, true, true);
            }
            g.Freeze();
            return g;
        }
    }

    // ------------------------------------------------------------------ processes
    public static class ProcInfo
    {
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder sb, ref int size);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct SHFILEINFO
        {
            public IntPtr hIcon; public int iIcon; public uint dwAttributes;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
        }
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SHGetFileInfo(string path, uint attrs, ref SHFILEINFO psfi, uint cb, uint flags);
        [DllImport("shell32.dll", EntryPoint = "#727")] static extern int SHGetImageList(int iImageList, ref Guid riid, out IImageList ppv);
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);

        [ComImport, Guid("46EB5926-582E-4017-9FDF-E8998DAA0950"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IImageList
        {
            [PreserveSig] int Add(IntPtr hbmImage, IntPtr hbmMask, ref int pi);
            [PreserveSig] int ReplaceIcon(int i, IntPtr hicon, ref int pi);
            [PreserveSig] int SetOverlayImage(int iImage, int iOverlay);
            [PreserveSig] int Replace(int i, IntPtr hbmImage, IntPtr hbmMask);
            [PreserveSig] int AddMasked(IntPtr hbmImage, int crMask, ref int pi);
            [PreserveSig] int Draw(IntPtr pimldp);
            [PreserveSig] int Remove(int i);
            [PreserveSig] int GetIcon(int i, int flags, ref IntPtr picon);
        }

        static int _genericIcon = -2;

        /// System image-list index of the blank "application" icon, so callers can fall back to a monogram.
        static int GenericExeIcon()
        {
            if (_genericIcon != -2) return _genericIcon;
            SHFILEINFO info = new SHFILEINFO();
            IntPtr ok = SHGetFileInfo("placeholder.exe", 0x80 /*FILE_ATTRIBUTE_NORMAL*/, ref info, (uint)Marshal.SizeOf(typeof(SHFILEINFO)), 0x4000 | 0x10 /*SYSICONINDEX|USEFILEATTRIBUTES*/);
            _genericIcon = ok != IntPtr.Zero ? info.iIcon : -1;
            return _genericIcon;
        }

        static readonly Dictionary<string, ImageSource> IconCache = new Dictionary<string, ImageSource>(StringComparer.OrdinalIgnoreCase);
        static readonly Dictionary<string, string> NameCache = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        public static string ImagePath(int pid)
        {
            IntPtr h = OpenProcess(0x1000, false, pid);
            if (h == IntPtr.Zero) return null;
            try
            {
                StringBuilder sb = new StringBuilder(1024);
                int size = sb.Capacity;
                return QueryFullProcessImageName(h, 0, sb, ref size) ? sb.ToString(0, size) : null;
            }
            finally { CloseHandle(h); }
        }

        /// Human name from the executable's version resource ("Microsoft Edge WebView2"), else null.
        public static string FriendlyName(string path)
        {
            if (string.IsNullOrEmpty(path)) return null;
            string cached;
            lock (NameCache) { if (NameCache.TryGetValue(path, out cached)) return cached; }
            string name = null;
            try
            {
                FileVersionInfo fvi = FileVersionInfo.GetVersionInfo(path);
                name = fvi.FileDescription;
                if (name != null)
                {
                    name = name.Replace("ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â®", "").Replace("ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¾Ãƒâ€šÃ‚Â¢", "").Replace("(R)", "").Replace("(TM)", "").Trim();
                    while (name.Contains("  ")) name = name.Replace("  ", " ");
                }
                if (string.IsNullOrWhiteSpace(name)) name = null;
            }
            catch { name = null; }
            lock (NameCache) NameCache[path] = name;
            return name;
        }

        /// 48px shell icon (SHIL_EXTRALARGE) as a frozen ImageSource, or null.
        public static ImageSource Icon(string path)
        {
            if (string.IsNullOrEmpty(path)) return null;
            ImageSource cached;
            lock (IconCache) { if (IconCache.TryGetValue(path, out cached)) return cached; }
            ImageSource result = null;
            IntPtr hIcon = IntPtr.Zero;
            try
            {
                SHFILEINFO info = new SHFILEINFO();
                IntPtr ok = SHGetFileInfo(path, 0, ref info, (uint)Marshal.SizeOf(typeof(SHFILEINFO)), 0x4000 /*SYSICONINDEX*/);
                if (ok != IntPtr.Zero && info.iIcon != GenericExeIcon())
                {
                    Guid iid = new Guid("46EB5926-582E-4017-9FDF-E8998DAA0950");
                    IImageList list;
                    if (SHGetImageList(0x2 /*SHIL_EXTRALARGE*/, ref iid, out list) == 0 && list != null)
                    {
                        list.GetIcon(info.iIcon, 0x1 /*ILD_TRANSPARENT*/, ref hIcon);
                        Marshal.ReleaseComObject(list);
                    }
                }
                if (hIcon != IntPtr.Zero)
                {
                    BitmapSource bs = Imaging.CreateBitmapSourceFromHIcon(hIcon, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                    bs.Freeze();
                    result = bs;
                }
            }
            catch { result = null; }
            finally { if (hIcon != IntPtr.Zero) DestroyIcon(hIcon); }
            lock (IconCache) IconCache[path] = result;
            return result;
        }
    }

    // ------------------------------------------------------------------ animated numbers
    /// TextBlock whose numeric Value can be animated (counting-up figures in the hero gauge).
    public class NumberText : TextBlock
    {
        static void Changed(DependencyObject d, DependencyPropertyChangedEventArgs e) { ((NumberText)d).Render(); }
        public static readonly DependencyProperty ValueProperty = DependencyProperty.Register("Value", typeof(double), typeof(NumberText), new PropertyMetadata(0.0, Changed));
        public static readonly DependencyProperty DecimalsProperty = DependencyProperty.Register("Decimals", typeof(int), typeof(NumberText), new PropertyMetadata(0, Changed));
        public static readonly DependencyProperty SuffixProperty = DependencyProperty.Register("Suffix", typeof(string), typeof(NumberText), new PropertyMetadata("", Changed));
        public double Value { get { return (double)GetValue(ValueProperty); } set { SetValue(ValueProperty, value); } }
        public int Decimals { get { return (int)GetValue(DecimalsProperty); } set { SetValue(DecimalsProperty, value); } }
        public string Suffix { get { return (string)GetValue(SuffixProperty); } set { SetValue(SuffixProperty, value); } }
        public NumberText() { Render(); }
        void Render()
        {
            int d = Math.Max(0, Math.Min(4, Decimals));
            Text = Value.ToString("N" + d, System.Globalization.CultureInfo.CurrentCulture) + (Suffix ?? "");
        }
    }

    // ------------------------------------------------------------------ system notifications
    public delegate void SystemChangedHandler(string kind);

    /// Raises Changed("theme" | "wallpaper" | "display") on the UI thread, debounced.
    public class SystemWatcher
    {
        public event SystemChangedHandler Changed;
        readonly System.Windows.Threading.DispatcherTimer _debounce;
        readonly HashSet<string> _pending = new HashSet<string>();

        public SystemWatcher(Window window)
        {
            _debounce = new System.Windows.Threading.DispatcherTimer();
            _debounce.Interval = TimeSpan.FromMilliseconds(350);
            _debounce.Tick += delegate
            {
                _debounce.Stop();
                string[] kinds = new string[_pending.Count];
                _pending.CopyTo(kinds);
                _pending.Clear();
                SystemChangedHandler h = Changed;
                if (h == null) return;
                foreach (string k in kinds) { try { h(k); } catch { } }
            };
            HwndSource src = PresentationSource.FromVisual(window) as HwndSource;
            if (src != null) src.AddHook(Hook);
        }

        void Queue(string kind) { _pending.Add(kind); _debounce.Stop(); _debounce.Start(); }

        IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (msg == 0x001A) // WM_SETTINGCHANGE
            {
                string area = null;
                try { if (lParam != IntPtr.Zero) area = Marshal.PtrToStringUni(lParam); } catch { }
                if (wParam.ToInt64() == 0x0014) Queue("wallpaper");                     // SPI_SETDESKWALLPAPER
                else if (area == "ImmersiveColorSet") Queue("theme");
                else if (area == "WindowMetrics" || area == "Desktop") Queue("wallpaper");
            }
            else if (msg == 0x007E || msg == 0x02E0) Queue("display");                  // WM_DISPLAYCHANGE / WM_DPICHANGED
            else if (msg == 0x0320) Queue("theme");                                     // WM_DWMCOLORIZATIONCOLORCHANGED
            return IntPtr.Zero;
        }
    }

    public static class Native
    {
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

        [StructLayout(LayoutKind.Sequential)]
        struct MEMORYSTATUSEX
        {
            public uint dwLength, dwMemoryLoad;
            public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
        }
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX m);
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        [StructLayout(LayoutKind.Sequential)] struct AccentPolicy { public int AccentState; public int AccentFlags; public uint GradientColor; public int AnimationId; }
        [StructLayout(LayoutKind.Sequential)] struct WindowCompositionAttributeData { public int Attribute; public IntPtr Data; public int SizeOfData; }
        [DllImport("user32.dll")] static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref WindowCompositionAttributeData data);
        [DllImport("gdi32.dll")] static extern IntPtr CreateRoundRectRgn(int x1, int y1, int x2, int y2, int w, int h);
        [DllImport("user32.dll")] static extern int SetWindowRgn(IntPtr hwnd, IntPtr hrgn, bool redraw);

        /// Live, light blur of whatever is behind the window (Windows 10/11 DWM blur-behind).
        public static bool EnableBlurBehind(IntPtr hwnd)
        {
            try
            {
                AccentPolicy a = new AccentPolicy();
                a.AccentState = 3; // ACCENT_ENABLE_BLURBEHIND
                int size = Marshal.SizeOf(typeof(AccentPolicy));
                IntPtr p = Marshal.AllocHGlobal(size);
                try
                {
                    Marshal.StructureToPtr(a, p, false);
                    WindowCompositionAttributeData d = new WindowCompositionAttributeData();
                    d.Attribute = 19; // WCA_ACCENT_POLICY
                    d.Data = p;
                    d.SizeOfData = size;
                    return SetWindowCompositionAttribute(hwnd, ref d) != 0;
                }
                finally { Marshal.FreeHGlobal(p); }
            }
            catch { return false; }
        }

        /// Clips the window (and therefore the blur) to a rounded rectangle. radiusPx is in window pixels.
        public static void SetRoundedRegion(IntPtr hwnd, int radiusPx)
        {
            try
            {
                RECT r;
                if (!GetWindowRect(hwnd, out r)) return;
                IntPtr rgn = CreateRoundRectRgn(0, 0, r.Right - r.Left + 1, r.Bottom - r.Top + 1, radiusPx * 2, radiusPx * 2);
                if (rgn != IntPtr.Zero) SetWindowRgn(hwnd, rgn, true); // the system owns the region afterwards
            }
            catch { }
        }

        /// Windows 11 rounded corners + native shadow; DWM also clips the blur-behind to the rounded shape.
        public static void RoundDwmCorners(IntPtr hwnd)
        {
            try { int v = 2; DwmSetWindowAttribute(hwnd, 33 /*DWMWA_WINDOW_CORNER_PREFERENCE*/, ref v, 4); } catch { }
        }

        /// The window draws its own (larger, Apple-style) corners and shadow: ask DWM not to add its own.
        public static void DisableDwmRounding(IntPtr hwnd)
        {
            try { int v = 1; DwmSetWindowAttribute(hwnd, 33 /*DWMWA_WINDOW_CORNER_PREFERENCE*/, ref v, 4); } catch { }
        }

        public static long TotalPhysicalMemory()
        {
            MEMORYSTATUSEX m = new MEMORYSTATUSEX();
            m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            return GlobalMemoryStatusEx(ref m) ? (long)m.ullTotalPhys : 0;
        }
    }
}
