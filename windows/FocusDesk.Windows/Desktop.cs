using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using Microsoft.Win32;
using static FocusDesk.Resources;
using Forms = System.Windows.Forms;

namespace FocusDesk;
public record Palette(string Id,string Title,string Background,string Accent,bool Dark=false);
public sealed class Quote { public string Id {get;set;}="";public string Text {get;set;}="";public string Explanation {get;set;}="";public string Source {get;set;}=""; }
public sealed class Desktop {
    public static readonly Palette[] Themes = {
        new("classic","经典蓝","#F3F4F8","#4766DE"),new("vintage","纸上时光 · 复古","#F2E6CF","#875737"),
        new("terminal","深空终端 · 科技","#0C1B29","#52D5ED",true),new("minimal","留白 · 极简","#F7F7F7","#55565B"),
        new("blueprint","工程蓝图 · 理工科","#16344F","#87CCFF",true),new("cyber","霓虹夜航 · 赛博","#1D122C","#D291FF",true),
        new("gentle","奶油日光 · 温柔","#FBF0E4","#9A7259"),new("forest","林间薄雾 · 自然","#E7EEE5","#49715C"),
        new("horror","午夜档案 · 微恐怖","#211C20","#DE7275",true),new("pixel","掌上像素 · 复古游戏","#1D2924","#B4E077",true),
        new("moon","月下银幕 · 沉静","#242630","#B8B7E6",true)
    };
    public static readonly string[] EffectIds={"soft","glitch","energy","blackhole","hologram","ice","mechanical","shadow","petals","pixels"};
    public static readonly string[] EffectTitles={"柔和光晕","赛博故障","能量爆发","黑洞坍缩","全息解构","冰封碎裂","机械仪表","幽影侵蚀","花开与流萤","像素通关"};
    readonly Store store; readonly Window square,details; readonly DispatcherTimer clock=new(),hide=new();
    readonly Forms.NotifyIcon tray=new(); readonly Dictionary<string,Window> windows=new(); readonly List<TextBlock> clocks=new();
    readonly bool smoke; Window? effectWindow; DispatcherTimer? animation; DateTimeOffset quoteHour; bool rendering;
    public Palette Theme=>Themes.FirstOrDefault(x=>x.Id==store.State.Preferences.Theme)??Themes[0];
    Brush Accent=>Brush(Theme.Accent); Brush Foreground=>Brush(Theme.Dark?"#EEEFF3":"#292A30"); Brush Background=>Brush(Theme.Background);
    public static Brush Brush(string color)=>new SolidColorBrush((Color)ColorConverter.ConvertFromString(color));
    FontFamily Font=>new(Theme.Id is "vintage" or "horror" ? "Georgia" : Theme.Id is "terminal" or "blueprint" or "cyber" or "pixel" ? "Consolas" : "Segoe UI");
    public Desktop(Store storage,bool smokeTest=false) {
        store=storage;smoke=smokeTest;
        square=Panel("FocusDesk",store.State.Preferences.Size,store.State.Preferences.Size);details=Panel(L("FocusDesk 悬浮窗"),380,630);
        var area=SystemParameters.WorkArea;square.Left=Math.Clamp(store.State.Preferences.X,area.Left,Math.Max(area.Left,area.Right-square.Width));square.Top=Math.Clamp(store.State.Preferences.Y,area.Top,Math.Max(area.Top,area.Bottom-square.Height));
        square.MouseEnter+=(_,_)=>{hide.Stop();ShowDetails();};square.MouseLeave+=(_,_)=>hide.Start();details.MouseEnter+=(_,_)=>hide.Stop();details.MouseLeave+=(_,_)=>hide.Start();
        square.MouseLeftButtonDown+=(_,e)=>{if(e.OriginalSource is Thumb)return;try{square.DragMove();SavePosition();}catch(InvalidOperationException){}};
        square.LocationChanged+=(_,_)=>{if(details.IsVisible)PositionDetails();};
        hide.Interval=TimeSpan.FromMilliseconds(350);hide.Tick+=(_,_)=>{if(!square.IsMouseOver&&!details.IsMouseOver)details.Hide();hide.Stop();};
        store.Changed+=Refresh;store.Completed+=()=>PlayEffect();
        clock.Interval=TimeSpan.FromSeconds(1);clock.Tick+=(_,_)=>{store.Tick(DateTimeOffset.Now);RenderSquare();if(details.IsVisible)RenderDetails();foreach(var label in clocks.ToArray())label.Text=TimerText();UpdateQuote();};
        tray.DoubleClick+=(_,_)=>Application.Current.Dispatcher.Invoke(()=>Open("plan"));
        BuildTray();Refresh();square.Show();store.Tick(DateTimeOffset.Now);clock.Start();
    }
    Window Panel(string title,double width,double height) {
        var window=new Window{Title=title,Width=width,Height=height,WindowStyle=WindowStyle.None,ResizeMode=ResizeMode.NoResize,AllowsTransparency=true,Background=System.Windows.Media.Brushes.Transparent,ShowInTaskbar=false,ShowActivated=false,Topmost=store.State.Preferences.OnTop};
        window.SourceInitialized+=(_,_)=>{var h=new WindowInteropHelper(window).Handle;SetWindowLong(h,-20,GetWindowLong(h,-20)|0x08000000|0x80);};return window;
    }
    [DllImport("user32.dll")]static extern int GetWindowLong(IntPtr h,int i);
    [DllImport("user32.dll")]static extern int SetWindowLong(IntPtr h,int i,int value);
    void SavePosition()=>store.Commit(d=>{d.Preferences.X=square.Left;d.Preferences.Y=square.Top;});
    void PositionDetails(){var area=SystemParameters.WorkArea;details.Left=Math.Clamp(square.Left+square.Width+8,area.Left,Math.Max(area.Left,area.Right-details.Width));if(details.Left<square.Left+square.Width&&square.Left-details.Width-8>=area.Left)details.Left=square.Left-details.Width-8;details.Top=Math.Clamp(square.Top,area.Top,Math.Max(area.Top,area.Bottom-details.Height));}
    public void ShowDetails(){RenderDetails();PositionDetails();details.Show();}
    TextBlock Text(string value,double size=14,Brush? color=null)=>new(){Text=value,FontSize=size,Foreground=color??Foreground,TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,4,0,6),FontFamily=Font};
    StackPanel Stack()=>new(){Margin=new Thickness(20)};
    Button Button(string key,Action action){var b=new Button{Content=L(key),Margin=new Thickness(0,4,8,4),Padding=new Thickness(12,7,12,7),Background=Background,Foreground=Foreground,BorderBrush=Accent};b.Click+=(_,_)=>Guard(action);return b;}
    void Guard(Action action){try{action();if(store.Error!=null)ShowError(store.Error);}catch(Exception ex){ShowError(ex.Message);}}
    void ShowError(string message)=>System.Windows.MessageBox.Show(message,"FocusDesk",MessageBoxButton.OK,MessageBoxImage.Warning);
    Border Card(UIElement child)=>new(){Child=child,Background=Background,CornerRadius=new CornerRadius(18),BorderBrush=Accent,BorderThickness=new Thickness(1)};
    void BuildTray(){
        tray.Icon=System.Drawing.SystemIcons.Application;tray.Text="FocusDesk";tray.Visible=!smoke;
        var menu=new Forms.ContextMenuStrip();
        void Item(string key,Action action)=>menu.Items.Add(L(key),null,(_,_)=>Application.Current.Dispatcher.Invoke(()=>Guard(action)));
        Item(square.IsVisible?"隐藏小方块":"显示小方块",()=>{if(square.IsVisible){square.Hide();details.Hide();}else square.Show();BuildTray();});
        Item("今日计划",()=>Open("plan"));Item("事项计时",()=>Open("timers"));Item("专注记录",()=>Open("history"));Item("设置",()=>Open("settings"));Item("退出 FocusDesk",()=>Application.Current.Shutdown());
        tray.ContextMenuStrip?.Dispose();tray.ContextMenuStrip=menu;
    }
    void Refresh(){if(rendering)return;rendering=true;try{square.Topmost=details.Topmost=store.State.Preferences.OnTop;square.Width=square.Height=store.State.Preferences.Size;RenderSquare();if(details.IsVisible)RenderDetails();foreach(var pair in windows.ToArray())BuildPage(pair.Key,pair.Value);BuildTray();}finally{rendering=false;}}
    TaskItem? Current=>store.State.Tasks.FirstOrDefault(t=>t.StartMinutes<=DateTime.Now.TimeOfDay.TotalMinutes&&t.EndMinutes>DateTime.Now.TimeOfDay.TotalMinutes);
    string TimerText(){var s=store.State.Displayed;if(s==null)return "";return s.EndedAt!=null?L("已到时"):Clock(s.Target!=null?s.Remaining(DateTimeOffset.Now):s.Elapsed(DateTimeOffset.Now));}
    string ActivityName(Session s)=>store.State.Activities.FirstOrDefault(a=>a.Id==s.ActivityId)?.Name??L("事项");
    double Progress {get{var now=DateTimeOffset.Now;var s=store.State.Displayed;if(s!=null)return s.Target is {} target?Math.Clamp(s.Elapsed(now)/target,0,1):0;var t=Current;return t==null?0:Math.Clamp((DateTime.Now.TimeOfDay.TotalMinutes-t.StartMinutes)/(t.EndMinutes-t.StartMinutes),0,1);}}
    public void RenderSquare(){
        if(square.IsMouseCaptureWithin)return;
        double side=square.Width;var grid=new Grid();var ring=new Ellipse{Width=side*.7,Height=side*.7,Stroke=Accent,Opacity=.2,StrokeThickness=Math.Max(2,side*.045)};grid.Children.Add(ring);
        var drawing=new ProgressRing{Progress=Progress,Stroke=Accent,Width=side*.7,Height=side*.7};grid.Children.Add(drawing);
        var s=store.State.Displayed;string caption=s==null?"◷":s.EndedAt!=null?L("已到时"):s.RunningSince==null?L("已暂停"):TimerText();
        var label=Text(caption,side*(s==null?.32:Resources.Language=="en"?.12:.16),Accent);label.TextWrapping=TextWrapping.NoWrap;label.HorizontalAlignment=HorizontalAlignment.Center;label.VerticalAlignment=VerticalAlignment.Center;label.Margin=new Thickness(2);grid.Children.Add(label);
        var thumb=new Thumb{Width=12,Height=12,HorizontalAlignment=HorizontalAlignment.Right,VerticalAlignment=VerticalAlignment.Bottom,Cursor=Cursors.SizeNWSE,Opacity=.55};
        double resize=side;thumb.DragDelta+=(_,e)=>{resize=Math.Clamp(resize+e.HorizontalChange,32,112);square.Width=square.Height=resize;};thumb.DragCompleted+=(_,_)=>store.Commit(d=>d.Preferences.Size=resize);grid.Children.Add(thumb);
        var border=Card(grid);border.CornerRadius=new CornerRadius(Theme.Id=="pixel"?2:side*.24);square.Content=border;square.ToolTip=s==null?Current?.Title??L("自由时间"):ActivityName(s)+" · "+TimerText();
    }
    public void RenderDetails(){
        var box=Stack();var header=new DockPanel();var settings=Button("设置",()=>Open("settings"));DockPanel.SetDock(settings,Dock.Right);header.Children.Add(settings);header.Children.Add(Text("FocusDesk",18,Accent));box.Children.Add(header);
        var s=store.State.Displayed;var current=Current;box.Children.Add(Text(s!=null?(s.EndedAt!=null?L("已到时 · 可继续专注"):s.RunningSince==null?L("已暂停"):L(s.Target!=null?"倒计时":"正计时")):L(current==null?"自由时间":"正在进行"),12,Accent));
        box.Children.Add(Text(s!=null?ActivityName(s):current?.Title??L("自由时间"),25));
        box.Children.Add(Text(s!=null?L(s.EndedAt!=null?"这段专注已记录，按自己的节奏收尾。":"专注于当前事项，让时间安静地流动。"):current?.Details??L("放松一下，按照自己的节奏安排这段时间。"),13));
        box.Children.Add(Text(s!=null?TimerText():Clock(current==null?0:(current.EndMinutes-DateTime.Now.TimeOfDay.TotalMinutes)*60),34,Accent));
        box.Children.Add(new ProgressBar{Value=Progress*100,Height=5,Foreground=Accent,Margin=new Thickness(0,6,0,14)});
        var controls=new WrapPanel();if(s!=null){controls.Children.Add(Button(s.EndedAt!=null?"+5 分钟":s.RunningSince==null?"继续":"暂停",()=>{if(s.EndedAt!=null)store.Extend(DateTimeOffset.Now);else store.Pause(DateTimeOffset.Now);}));controls.Children.Add(Button(s.EndedAt!=null?"完成":"结束并记录",()=>store.Finish(DateTimeOffset.Now)));}else if(current!=null){controls.Children.Add(Button("标记完成",()=>store.Commit(d=>{var record=Store.Today(d,DateTimeOffset.Now);if(!record.Completed.Add(current.Id))record.Completed.Remove(current.Id);})));}box.Children.Add(controls);
        var links=new WrapPanel();links.Children.Add(Button("今日计划",()=>Open("plan")));links.Children.Add(Button("事项计时",()=>Open("timers")));links.Children.Add(Button("专注记录",()=>Open("history")));box.Children.Add(links);
        var next=store.State.Tasks.OrderBy(t=>t.StartMinutes).FirstOrDefault(t=>t.StartMinutes>DateTime.Now.TimeOfDay.TotalMinutes);if(s==null&&next!=null)box.Children.Add(Text(L("下一项 · %@%@","",Time(next.StartMinutes))+"\n"+next.Title,12));
        var quote=Resources.Read<List<Quote>>("quotes.json").FirstOrDefault(q=>q.Id==store.State.Preferences.QuoteId)??Resources.Read<List<Quote>>("quotes.json")[0];box.Children.Add(Text(L(quote.Text),15));box.Children.Add(Button("解释与出处",()=>System.Windows.MessageBox.Show(L(quote.Explanation)+"\n\n"+L(quote.Source),L("解释与出处"))));
        if(store.Error!=null)box.Children.Add(Text(store.Error,12,System.Windows.Media.Brushes.Orange));
        details.Content=Card(new ScrollViewer{Content=box,VerticalScrollBarVisibility=ScrollBarVisibility.Auto});
    }
    void UpdateQuote(){var now=DateTimeOffset.Now;if((now-quoteHour).TotalMinutes<1)return;quoteHour=now;if((now-store.State.Preferences.QuoteAt).TotalHours>=1||now<store.State.Preferences.QuoteAt||store.State.Preferences.QuoteId==""){var quotes=Resources.Read<List<Quote>>("quotes.json").Where(q=>q.Id!=store.State.Preferences.QuoteId).ToList();store.Commit(d=>{d.Preferences.QuoteId=quotes[Random.Shared.Next(quotes.Count)].Id;d.Preferences.QuoteAt=now;});}}
    public static string Time(int minutes)=>$"{minutes/60:00}:{minutes%60:00}";
    public void Open(string key){details.Hide();if(!windows.TryGetValue(key,out var window)){window=new Window{Width=860,Height=760,MinWidth=760,MinHeight=540,WindowStartupLocation=WindowStartupLocation.CenterScreen};windows[key]=window;window.Closed+=(_,_)=>{windows.Remove(key);clocks.Clear();};}BuildPage(key,window);window.Show();window.Activate();}
    void BuildPage(string key,Window window){window.Title=L(key=="plan"?"今日计划 · FocusDesk":key=="timers"?"事项计时 · FocusDesk":key=="history"?"专注记录 · FocusDesk":"设置 · FocusDesk");window.Background=Background;window.Foreground=Foreground;window.FontFamily=Font;var box=Stack();box.Children.Add(Text(window.Title,26,Accent));switch(key){case "plan":PlanPage(box);break;case "timers":TimersPage(box);break;case "history":HistoryPage(box);break;case "settings":SettingsPage(box);break;}if(store.Error!=null)box.Children.Add(Text(store.Error,13,System.Windows.Media.Brushes.Orange));window.Content=new ScrollViewer{Content=box,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};}
    TextBox Input(string value,string help=""){var text=new TextBox{Text=value,Margin=new Thickness(0,4,8,4),Padding=new Thickness(8),MinWidth=90,ToolTip=help,Background=Background,Foreground=Foreground,BorderBrush=Accent};return text;}
    void PlanPage(StackPanel box){box.Children.Add(Text(L("每日重复 · 完成状态按天记录 · 编辑保存后同步悬浮窗"),12));box.Children.Add(Button("新增任务",()=>EditTask(null)));
        foreach(var task in store.State.Tasks.OrderBy(t=>t.StartMinutes)){var row=new DockPanel{Margin=new Thickness(0,6,0,6)};var controls=new WrapPanel();var done=store.State.History.FirstOrDefault(x=>x.Day==DateTime.Now.ToString("yyyy-MM-dd"))?.Completed.Contains(task.Id)==true;controls.Children.Add(Button(done?"已完成":"标记完成",()=>store.Commit(d=>{var r=Store.Today(d,DateTimeOffset.Now);if(!r.Completed.Add(task.Id))r.Completed.Remove(task.Id);})));controls.Children.Add(Button("编辑",()=>EditTask(task)));controls.Children.Add(Button("删除任务",()=>{if(Confirm("删除任务"))store.Commit(d=>{d.Tasks.RemoveAll(x=>x.Id==task.Id);Store.Today(d,DateTimeOffset.Now);});}));DockPanel.SetDock(controls,Dock.Right);row.Children.Add(controls);row.Children.Add(Text(Time(task.StartMinutes)+"–"+Time(task.EndMinutes)+"  "+task.Title+"\n"+task.Details));box.Children.Add(row);}}
    bool Confirm(string key)=>System.Windows.MessageBox.Show(L(key)+"?", "FocusDesk",MessageBoxButton.YesNo,MessageBoxImage.Question)==MessageBoxResult.Yes;
    void EditTask(TaskItem? task){var window=new Window{Title=L(task==null?"新增任务":"编辑任务"),Width=540,Height=510,Background=Background,Foreground=Foreground,WindowStartupLocation=WindowStartupLocation.CenterScreen};var box=Stack();var start=Input(Time(task?.StartMinutes??540));var end=Input(Time(task?.EndMinutes??600));var name=Input(task?.Title??"");var detail=Input(task?.Details??"");foreach(var pair in new[]{("开始时间",start),("结束时间",end),("任务名称",name),("详细说明",detail)}){box.Children.Add(Text(L(pair.Item1)));box.Children.Add(pair.Item2);}box.Children.Add(Button("保存",()=>{int Parse(string text,bool isEnd){if(isEnd&&(text=="24:00"||text=="00:00"))return 1440;if(!DateTime.TryParseExact(text,"HH:mm",CultureInfo.InvariantCulture,DateTimeStyles.None,out var parsed))throw new Exception(L("开始时间格式有误，请使用 00:00～23:59。"));return parsed.Hour*60+parsed.Minute;}var updated=new TaskItem{Id=task?.Id??Guid.NewGuid(),StartMinutes=Parse(start.Text,false),EndMinutes=Parse(end.Text,true),Title=name.Text.Trim(),Details=detail.Text.Trim()};var overlaps=store.State.Tasks.Where(t=>t.Id!=updated.Id&&t.StartMinutes<updated.EndMinutes&&updated.StartMinutes<t.EndMinutes).ToList();
if(overlaps.Count>0 && MessageBox.Show(L("时间冲突：以下任务已占用这个时间段")+"\n\n"+string.Join("\n",overlaps.Select(t=>Time(t.StartMinutes)+"–"+Time(t.EndMinutes)+" "+t.Title))+"\n\n"+L("原任务未重叠的内容会保留；完整覆盖的任务将移除。移除不能在应用内撤销。")+"\n"+L("确认替换并保存"),"FocusDesk",MessageBoxButton.YesNo,MessageBoxImage.Question)!=MessageBoxResult.Yes)return;
if(store.Commit(d=>{d.Tasks.RemoveAll(x=>x.Id==updated.Id);foreach(var overlap in overlaps){d.Tasks.RemoveAll(x=>x.Id==overlap.Id);if(overlap.StartMinutes<updated.StartMinutes)d.Tasks.Add(new TaskItem{StartMinutes=overlap.StartMinutes,EndMinutes=updated.StartMinutes,Title=overlap.Title,Details=overlap.Details});if(overlap.EndMinutes>updated.EndMinutes)d.Tasks.Add(new TaskItem{StartMinutes=updated.EndMinutes,EndMinutes=overlap.EndMinutes,Title=overlap.Title,Details=overlap.Details});}d.Tasks.Add(updated);Store.Today(d,DateTimeOffset.Now);}))window.Close();}));window.Content=box;window.ShowDialog();}
    void TimersPage(StackPanel box){var session=store.State.Displayed;if(session!=null){box.Children.Add(Text(ActivityName(session),23));var label=Text(TimerText(),35,Accent);clocks.Clear();clocks.Add(label);box.Children.Add(label);var actions=new WrapPanel();actions.Children.Add(Button(session.EndedAt!=null?"+5 分钟":session.RunningSince==null?"继续":"暂停",()=>{if(session.EndedAt!=null)store.Extend(DateTimeOffset.Now);else store.Pause(DateTimeOffset.Now);}));actions.Children.Add(Button(session.EndedAt!=null?"完成":"结束并记录",()=>store.Finish(DateTimeOffset.Now)));box.Children.Add(actions);}
        var add=Input("",L("事项名称"));box.Children.Add(Text(L("开始一次计时"),19));box.Children.Add(add);box.Children.Add(Button("添加事项",()=>store.AddActivity(add.Text)));
        var activities=new ComboBox{ItemsSource=store.State.Activities,DisplayMemberPath="Name",SelectedIndex=0,Margin=new Thickness(0,8,0,8)};box.Children.Add(activities);var mode=new ComboBox{ItemsSource=new[]{L("正计时"),L("倒计时")},SelectedIndex=1};box.Children.Add(mode);var duration=Input("00:25:00",L("时长"));box.Children.Add(duration);var begin=Button("开始计时",()=>{if(activities.SelectedItem is Activity a){double? target=null;if(mode.SelectedIndex==1){if(!TimeSpan.TryParseExact(duration.Text,@"hh\:mm\:ss",CultureInfo.InvariantCulture,out var span))throw new Exception(L("请输入有效时长：小时为 0–168，分钟和秒为 0–59。"));target=span.TotalSeconds;}store.Start(a.Id,target,DateTimeOffset.Now);}});begin.IsEnabled=store.State.Active==null;box.Children.Add(begin);
        box.Children.Add(Text(L("累计时长"),20));var range=new ComboBox{ItemsSource=new[]{L("今天"),L("近 7 天"),L("近 30 天"),L("全部")},SelectedIndex=0};var sort=new ComboBox{ItemsSource=new[]{L("时长降序（长 → 短）"),L("时长升序（短 → 长）")},SelectedIndex=0};box.Children.Add(range);box.Children.Add(sort);var totals=new StackPanel();box.Children.Add(totals);
        void Totals(){totals.Children.Clear();DateTimeOffset? from=range.SelectedIndex==3?null:new DateTimeOffset(DateTime.Today.AddDays(range.SelectedIndex==0?0:range.SelectedIndex==1?-6:-29));var selected=new HashSet<Guid>();var sum=Text("",15,Accent);var ordered=store.State.Activities.Select(a=>(Activity:a,Total:store.Total(a.Id,DateTimeOffset.Now,from)));ordered=sort.SelectedIndex==0?ordered.OrderByDescending(x=>x.Total):ordered.OrderBy(x=>x.Total);
            foreach(var item in ordered){var a=item.Activity;var row=new WrapPanel();var check=new CheckBox{Content=a.Name+" · "+Clock(item.Total),Foreground=Foreground,Margin=new Thickness(0,12,15,0),MinWidth=250};void Sum(){sum.Text=L("已选 %@ 项合计",selected.Count)+" · "+Clock(selected.Sum(id=>store.Total(id,DateTimeOffset.Now,from)));}check.Checked+=(_,_)=>{selected.Add(a.Id);Sum();};check.Unchecked+=(_,_)=>{selected.Remove(a.Id);Sum();};row.Children.Add(check);row.Children.Add(Button("修改事项名称",()=>Rename(a)));row.Children.Add(Button("删除事项及记录",()=>{if(Confirm("删除计时事项？"))store.DeleteActivity(a.Id);}));totals.Children.Add(row);}totals.Children.Add(sum);}
        range.SelectionChanged+=(_,_)=>Totals();sort.SelectionChanged+=(_,_)=>Totals();Totals();box.Children.Add(Text(L("计时记录 · %@ 次",store.State.Sessions.Count(x=>x.EndedAt!=null)),20));foreach(var record in store.State.Sessions.Where(s=>s.EndedAt!=null).OrderByDescending(s=>s.StartedAt).Take(100))box.Children.Add(Text(record.StartedAt.ToLocalTime().ToString("g")+" · "+ActivityName(record)+" · "+Clock(record.Saved),12));}
    void Rename(Activity a){var dialog=new Window{Title=L("修改事项名称"),Width=460,Height=200,Background=Background,WindowStartupLocation=WindowStartupLocation.CenterScreen};var box=Stack();var name=Input(a.Name);box.Children.Add(name);box.Children.Add(Button("保存",()=>{if(store.Commit(d=>{var n=name.Text.Trim();if(n.Length==0||d.Activities.Any(x=>x.Id!=a.Id&&string.Equals(x.Name,n,StringComparison.OrdinalIgnoreCase)))throw new Exception(L("已有同名事项，请使用其他名称。"));d.Activities.Single(x=>x.Id==a.Id).Name=n;}))dialog.Close();}));dialog.Content=box;dialog.ShowDialog();}
    void HistoryPage(StackPanel box){box.Children.Add(Text(L("回顾每天的计划与完成情况"),14));foreach(var day in store.State.History.OrderByDescending(d=>d.Day)){box.Children.Add(Text(day.Day+" · "+day.Completed.Count+"/"+day.Tasks.Count+" · "+(day.Tasks.Count==0?"0":(100.0*day.Completed.Count/day.Tasks.Count).ToString("F0"))+"%",19,Accent));foreach(var task in day.Tasks)box.Children.Add(Text((day.Completed.Contains(task.Id)?"✓ ":"○ ")+Time(task.StartMinutes)+"  "+task.Title,13));}}
    void SettingsPage(StackPanel box){box.Children.Add(Text("Language / 语言",15));var language=new ComboBox{ItemsSource=new[]{"简体中文","English"},SelectedIndex=Resources.Language=="en"?1:0};language.SelectionChanged+=(_,_)=>store.Commit(d=>d.Preferences.Language=language.SelectedIndex==1?"en":"zh-Hans");box.Children.Add(language);
        box.Children.Add(Text(L("主题"),16));var themes=new ComboBox{ItemsSource=Themes.Select(t=>L(t.Title)).ToArray(),SelectedIndex=Array.IndexOf(Themes,Theme)};themes.SelectionChanged+=(_,_)=>store.Commit(d=>d.Preferences.Theme=Themes[themes.SelectedIndex].Id);box.Children.Add(themes);
        box.Children.Add(Text(L("特效"),16));var effects=new ComboBox{ItemsSource=EffectTitles.Select(x=>L(x)).ToArray(),SelectedIndex=Math.Max(0,Array.IndexOf(EffectIds,store.State.Preferences.Effect))};effects.SelectionChanged+=(_,_)=>store.Commit(d=>d.Preferences.Effect=EffectIds[effects.SelectedIndex]);box.Children.Add(effects);
        var intensity=new ComboBox{ItemsSource=new[]{L("轻柔"),L("标准"),L("夸张")},SelectedIndex=store.State.Preferences.Intensity,Margin=new Thickness(0,10,0,10)};intensity.SelectionChanged+=(_,_)=>store.Commit(d=>d.Preferences.Intensity=intensity.SelectedIndex);box.Children.Add(intensity);
        void Toggle(string title,bool value,Action<Preferences,bool> change){var check=new CheckBox{Content=L(title),IsChecked=value,Foreground=Foreground,Margin=new Thickness(0,10,0,10)};check.Click+=(_,_)=>store.Commit(d=>change(d.Preferences,check.IsChecked==true));box.Children.Add(check);}
        Toggle("启用到时特效",store.State.Preferences.Effects,(p,v)=>p.Effects=v);box.Children.Add(Button("预览桌面特效",()=>PlayEffect()));Toggle("小方块与悬浮窗始终置顶",store.State.Preferences.OnTop,(p,v)=>p.OnTop=v);
        box.Children.Add(Text(L("桌面小方块大小"),16));var size=new Slider{Minimum=32,Maximum=112,Value=store.State.Preferences.Size,TickFrequency=1,IsSnapToTickEnabled=true};size.PreviewMouseLeftButtonUp+=(_,_)=>store.Commit(d=>d.Preferences.Size=size.Value);box.Children.Add(size);
        var startup=new CheckBox{Content=L("登录 macOS 时启动").Replace("macOS","Windows"),Foreground=Foreground,Margin=new Thickness(0,14,0,14)};if(!smoke){using var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");startup.IsChecked=key?.GetValue("FocusDesk")!=null;}startup.Click+=(_,_)=>Guard(()=>{if(smoke)return;using var key=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");if(startup.IsChecked==true)key.SetValue("FocusDesk","\""+Environment.ProcessPath+"\"");else key.DeleteValue("FocusDesk",false);});box.Children.Add(startup);box.Children.Add(Text(L("计划与设置仅保存在本机"),14));box.Children.Add(Text(store.FilePath,12));}
    public void PlayEffect(){if(!store.State.Preferences.Effects||!SystemParameters.ClientAreaAnimation||!square.IsVisible)return;animation?.Stop();effectWindow?.Close();effectWindow=Panel("FocusDesk Effect",360,360);effectWindow.Left=square.Left+square.Width/2-180;effectWindow.Top=square.Top+square.Height/2-180;var surface=new EffectSurface(store.State.Preferences.Effect,Accent,store.State.Preferences.Intensity);effectWindow.Content=surface;effectWindow.SourceInitialized+=(_,_)=>{var h=new WindowInteropHelper(effectWindow).Handle;SetWindowLong(h,-20,GetWindowLong(h,-20)|0x20);};effectWindow.Show();var start=DateTime.UtcNow;double duration=new[]{1.8,2.8,4.0}[store.State.Preferences.Intensity];animation=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(16)};animation.Tick+=(_,_)=>{surface.Progress=(DateTime.UtcNow-start).TotalSeconds/duration;if(surface.Progress>=1){animation.Stop();effectWindow.Close();effectWindow=null;}};animation.Start();}
    public void Dispose(){clock.Stop();hide.Stop();animation?.Stop();tray.Dispose();}
    public void Screenshots(string directory){Directory.CreateDirectory(directory);foreach(var lang in new[]{"zh-Hans","en"}){store.Commit(d=>d.Preferences.Language=lang);foreach(var key in new[]{"plan","timers","settings","history"}){Open(key);Capture(windows[key],System.IO.Path.Combine(directory,$"windows-{key}-{lang}.png"));windows[key].Hide();}ShowDetails();Capture(details,System.IO.Path.Combine(directory,$"windows-floating-{lang}.png"));}foreach(var theme in Themes){store.Commit(d=>d.Preferences.Theme=theme.Id);ShowDetails();Capture(details,System.IO.Path.Combine(directory,$"windows-theme-{theme.Id}.png"));}}
    public static void Capture(Window window,string file){window.UpdateLayout();Application.Current.Dispatcher.Invoke(()=>{},DispatcherPriority.Render);var view=(FrameworkElement)window.Content;view.UpdateLayout();var bitmap=new RenderTargetBitmap((int)Math.Ceiling(view.ActualWidth),(int)Math.Ceiling(view.ActualHeight),96,96,PixelFormats.Pbgra32);bitmap.Render(view);var png=new PngBitmapEncoder();png.Frames.Add(BitmapFrame.Create(bitmap));using var stream=File.Create(file);png.Save(stream);}
}
public sealed class ProgressRing:FrameworkElement {
    public double Progress;public Brush Stroke=System.Windows.Media.Brushes.Blue;
    protected override void OnRender(DrawingContext dc){base.OnRender(dc);double r=Math.Min(ActualWidth,ActualHeight)/2-2;var center=new Point(ActualWidth/2,ActualHeight/2);if(Progress>=1){dc.DrawEllipse(null,new Pen(Stroke,2.5),center,r,r);return;}if(Progress<=0)return;var geometry=new StreamGeometry();using(var c=geometry.Open()){c.BeginFigure(new Point(center.X,center.Y-r),false,false);double a=Progress*2*Math.PI;c.ArcTo(new Point(center.X+Math.Sin(a)*r,center.Y-Math.Cos(a)*r),new Size(r,r),0,Progress>.5,SweepDirection.Clockwise,true,false);}dc.DrawGeometry(null,new Pen(Stroke,2.5),geometry);}
}
public sealed class EffectSurface:FrameworkElement {
    readonly string effect;readonly Brush accent;readonly int intensity;double progress;
    public double Progress{get=>progress;set{progress=value;InvalidateVisual();}}
    public EffectSurface(string style,Brush color,int strength){effect=style;accent=color;intensity=strength;IsHitTestVisible=false;}
    protected override void OnRender(DrawingContext dc){double p=Math.Clamp(progress,0,1),fade=Math.Sin(p*Math.PI),radius=150*(.5+intensity*.25);var center=new Point(180,180);dc.PushOpacity(fade);
        Point At(double a,double r)=>new(180+Math.Cos(a)*r,180+Math.Sin(a)*r);
        if(effect is "soft" or "energy" or "mechanical"){for(int j=0;j<(effect=="soft"?1:3);j++){double r=22+radius*Math.Max(0,p-j*.13);dc.DrawEllipse(null,new Pen(accent,Math.Max(1,3-j)),center,r,r);if(effect=="mechanical")for(int k=0;k<24;k++)dc.DrawLine(new Pen(accent,2),At(k*Math.PI/12+p*3,r),At(k*Math.PI/12+p*3,r+7));}}
        else if(effect=="glitch"){for(int j=0;j<12;j++)dc.DrawRectangle(j%2==0?System.Windows.Media.Brushes.Cyan:System.Windows.Media.Brushes.Magenta,null,new Rect(120+Math.Sin(p*18+j)*25,120+j*10,120,j%3==0?4:1));}
        else {if(effect=="blackhole")dc.DrawEllipse(System.Windows.Media.Brushes.Black,new Pen(accent,3),center,20+fade*20,20+fade*20);for(int j=0;j<48;j++){double a=j*2.39996+(effect is "blackhole" or "shadow"?p*4:0);double r=20+radius*(effect=="blackhole"?1-p:p)*(.4+(j%7)/10.0);var point=At(a,r);double size=effect=="shadow"?18:effect=="ice"?8:5;var color=effect=="ice"?System.Windows.Media.Brushes.Cyan:effect=="pixels"?new[]{System.Windows.Media.Brushes.Yellow,System.Windows.Media.Brushes.Pink,System.Windows.Media.Brushes.MintCream}[j%3]:effect=="petals"?System.Windows.Media.Brushes.LightPink:effect=="shadow"?System.Windows.Media.Brushes.DarkRed:accent;if(effect is "pixels" or "hologram" or "ice")dc.DrawRectangle(effect=="hologram"?null:color,new Pen(color,1),new Rect(point,new Size(size,size)));else dc.DrawEllipse(color,null,point,size,effect=="petals"?size/2:size);}}
        dc.Pop();
    }
}
