using System;
using System.Windows;
using System.Windows.Media;

namespace FocusDesk;
public sealed class EffectConfiguration {
    public double Coverage {get;set;}=.5; public double Opacity {get;set;}=.55; public double Duration {get;set;}=4; public double Speed {get;set;}=1;
    public int Waves {get;set;}=1; public int Density {get;set;}=1;
    public double EdgeGlow {get;set;}=2; public double Dim {get;set;}=0; public bool AllScreens {get;set;}=false;
    public double Tail=>Math.Min(EdgeGlow,Duration*.4); public double ActiveDuration=>Duration-Tail;
    public static EffectConfiguration Preset(int index)=>index switch {
        0=>new(){Coverage=.15,Opacity=.35,Duration=2.5,Speed=.8,Waves=1,Density=1,EdgeGlow=1},
        2=>new(){Coverage=.85,Opacity=.8,Duration=5,Speed=1.15,Waves=2,Density=3,EdgeGlow=2},
        3=>new(){Coverage=1,Opacity=.85,Duration=7,Speed=.9,Waves=3,Density=3,EdgeGlow=3,Dim=.15},
        _=>new()
    };
    public EffectConfiguration Normalized(){
        double Clamp(double x,double min,double max,double fallback)=>double.IsFinite(x)?Math.Clamp(x,min,max):fallback;
        return new(){Coverage=Clamp(Coverage,.1,1,.5),Opacity=Clamp(Opacity,.1,1,.55),Duration=Clamp(Duration,1,12,4),Speed=Clamp(Speed,.6,1.6,1),Waves=Math.Clamp(Waves,1,3),Density=Math.Clamp(Density,0,3),EdgeGlow=Clamp(EdgeGlow,0,6,2),Dim=Clamp(Dim,0,.3,0),AllScreens=AllScreens};
    }
}
public static class EffectGeometry {
    public static double Area(Size size,Point origin,double radius){
        double left=Math.Max(0,origin.X-radius),right=Math.Min(size.Width,origin.X+radius);if(right<=left)return 0;
        double dx=(right-left)/256,sum=0;
        for(int i=0;i<256;i++){double x=left+(i+.5)*dx,h=Math.Sqrt(Math.Max(0,radius*radius-(x-origin.X)*(x-origin.X)));sum+=Math.Max(0,Math.Min(size.Height,origin.Y+h)-Math.Max(0,origin.Y-h))*dx;}return sum;
    }
    public static double Radius(Size size,Point origin,double coverage){
        double far=Math.Sqrt(Math.Pow(Math.Max(origin.X,size.Width-origin.X),2)+Math.Pow(Math.Max(origin.Y,size.Height-origin.Y),2));if(coverage>=1)return far;
        double low=0,high=far;for(int i=0;i<30;i++){double mid=(low+high)/2;if(Area(size,origin,mid)<size.Width*size.Height*coverage)low=mid;else high=mid;}return high;
    }
}
public sealed class EffectSurface:FrameworkElement {
    readonly string effect;readonly Brush accent;readonly EffectConfiguration options;readonly Point normalizedOrigin;
    Point origin;double radius,elapsed;
    public double Elapsed{get=>elapsed;set{elapsed=value;InvalidateVisual();}}
    public EffectSurface(string style,Brush color,EffectConfiguration configuration,Point anchor){effect=style;accent=color;options=configuration;normalizedOrigin=anchor;IsHitTestVisible=false;SizeChanged+=(_,_)=>{origin=new Point(ActualWidth*normalizedOrigin.X,ActualHeight*normalizedOrigin.Y);radius=EffectGeometry.Radius(new Size(ActualWidth,ActualHeight),origin,options.Coverage);};}
    protected override void OnRender(DrawingContext dc){
        var c=options;if(elapsed<=0||elapsed>=c.Duration||ActualWidth<=0||ActualHeight<=0)return;
        var screen=new Rect(0,0,ActualWidth,ActualHeight);double fadeOut=Math.Min(1,(c.Duration-elapsed)/Math.Max(.25,c.Tail));
        dc.PushOpacity(c.Dim*Math.Min(1,elapsed/.18)*fadeOut);dc.DrawRectangle(Brushes.Black,null,screen);dc.Pop();
        if(c.EdgeGlow>0){double edge=Math.Min(1,Math.Max(0,(elapsed-c.ActiveDuration*.65)/.4))*fadeOut*c.Opacity;for(int layer=0;layer<8;layer++){var inset=screen;inset.Inflate(-layer*3-2,-layer*3-2);dc.PushOpacity(edge*.065*(1-layer/9.0));dc.DrawRoundedRectangle(null,new Pen(accent,7),inset,18,18);dc.Pop();}}
        dc.PushClip(new EllipseGeometry(origin,radius,radius));
        Point At(double angle,double r)=>new(origin.X+Math.Cos(angle)*r,origin.Y+Math.Sin(angle)*r);
        if(elapsed<.6){dc.PushOpacity(c.Opacity*(1-elapsed/.6)*.5);dc.DrawEllipse(accent,null,origin,22+elapsed*38,22+elapsed*38);dc.Pop();}
        for(int wave=0;wave<c.Waves;wave++){
            double delay=wave*c.ActiveDuration*.16,raw=(elapsed-delay)/Math.Max(.1,c.ActiveDuration-delay);if(raw<=0||raw>=1)continue;
            double p=Math.Pow(raw,1/c.Speed),r=20+(radius-20)*(1-Math.Pow(1-p,2)),fade=Math.Min(1,raw*8)*Math.Min(1,(1-raw)*5)*c.Opacity;
            dc.PushOpacity(fade*.12);dc.DrawEllipse(null,new Pen(accent,30),origin,r,r);dc.Pop();
            dc.PushOpacity(fade*.32);dc.DrawEllipse(null,new Pen(accent,12),origin,r,r);dc.Pop();
            dc.PushOpacity(fade);dc.DrawEllipse(null,new Pen(accent,effect=="soft"?3:5),origin,r,r);
            if(effect=="mechanical")for(int tick=0;tick<72;tick++){double a=tick*Math.PI/36+p;dc.DrawLine(new Pen(accent,2),At(a,r),At(a,r+(tick%3==0?20:9)));}
            if(effect is "blackhole" or "shadow")for(int arm=0;arm<6;arm++){
                var path=new StreamGeometry();using(var ctx=path.Open()){for(int step=0;step<60;step++){double t=step/59.0;var pt=At(t*4+p*3+arm*Math.PI/3,r*t);if(step==0)ctx.BeginFigure(pt,false,false);else ctx.LineTo(pt,true,false);}}
                dc.PushOpacity(.45);dc.DrawGeometry(null,new Pen(effect=="shadow"?Brushes.Red:accent,effect=="shadow"?12:3),path);dc.Pop();
            }
            int count=new[]{0,48,96,180}[c.Density];
            for(int index=0;index<count;index++){
                double t=(index%13)/13.0,a=index*2.39996+p*(effect=="petals"?.5:.1),scale=Math.Min(2,Math.Max(1,radius/700));var location=At(a,r*(.55+t*.45));
                double size=(effect=="shadow"?18+t*24:3+t*7)*scale;
                Brush color=effect=="ice"?Brushes.Cyan:effect=="petals"?(index%2==0?Brushes.Pink:Brushes.Yellow):effect=="pixels"?new[]{Brushes.Yellow,Brushes.MintCream,Brushes.Pink,Brushes.Cyan}[index%4]:effect=="glitch"?(index%2==0?Brushes.Cyan:Brushes.Pink):accent;
                var rect=new Rect(location,new Size(effect=="glitch"?size*6:size,effect is "petals" or "glitch"?size*.4:size));
                dc.PushOpacity(effect=="shadow"?.25:.9);
                if(effect is "pixels" or "ice" or "hologram" or "glitch")dc.DrawRectangle(effect=="hologram"?null:color,effect=="hologram"?new Pen(color,2):null,rect);
                else dc.DrawEllipse(color,null,new Point(rect.X+rect.Width/2,rect.Y+rect.Height/2),rect.Width/2,rect.Height/2);dc.Pop();
            }
            dc.Pop();
        }
        dc.Pop();
    }
}
