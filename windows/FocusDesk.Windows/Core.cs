using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.Json;

namespace FocusDesk;
public static class Resources {
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    public static T Read<T>(string name) {
        var assembly = Assembly.GetExecutingAssembly();
        using var stream = assembly.GetManifestResourceStream(assembly.GetManifestResourceNames().Single(x => x.EndsWith(name, StringComparison.Ordinal)))!;
        return JsonSerializer.Deserialize<T>(stream, Json)!;
    }
    static readonly Dictionary<string,string> English = Read<Dictionary<string,string>>("en.json");
    public static string Language = "zh-Hans";
    public static string L(string key, params object[] args) {
        var text = Language == "en" ? English.GetValueOrDefault(key, key) : key;
        var parts=text.Split("%@",StringSplitOptions.None);
        text=string.Concat(parts.Select((part,index)=>part+(index<parts.Length-1?(index<args.Length?args[index].ToString():"%@"):"")));
        return text;
    }
    public static string Clock(double seconds) => TimeSpan.FromSeconds(Math.Max(0,Math.Ceiling(seconds))).ToString(@"dd\.hh\:mm\:ss").TrimStart('0').TrimStart('.');
}
public sealed class TaskItem {
    public Guid Id { get; set; } = Guid.NewGuid();
    public int StartMinutes {get;set;} public int EndMinutes {get;set;}
    public string Title {get;set;} = ""; public string Details {get;set;} = "";
}
public sealed class Activity { public Guid Id {get;set;} = Guid.NewGuid(); public string Name {get;set;} = ""; }
public sealed class Segment {
    public DateTimeOffset Start {get;set;} public DateTimeOffset End {get;set;}
    public double Duration => Math.Max(0,(End-Start).TotalSeconds);
}
public sealed class Session {
    public Guid Id {get;set;} = Guid.NewGuid(); public Guid ActivityId {get;set;}
    public double? Target {get;set;} public DateTimeOffset StartedAt {get;set;}
    public DateTimeOffset? RunningSince {get;set;} public DateTimeOffset? EndedAt {get;set;}
    public List<Segment> Segments {get;set;} = new();
    public double Saved => Segments.Sum(x=>x.Duration);
    public Segment? Live(DateTimeOffset now) => RunningSince is {} start ? new Segment { Start=start, End=start.AddSeconds(Math.Min(Math.Max(0,(now-start).TotalSeconds),Target is {} target ? Math.Max(0,target-Saved) : double.MaxValue)) } : null;
    public double Elapsed(DateTimeOffset now) => Saved + (Live(now)?.Duration??0);
    public double Remaining(DateTimeOffset now) => Math.Max(0,(Target??0)-Elapsed(now));
    public void Pause(DateTimeOffset now) { if(Live(now) is {} segment && segment.Duration>0) Segments.Add(segment); RunningSince=null; }
    public void Finish(DateTimeOffset now) { var end=Live(now)?.End??now; Pause(now); EndedAt=end < (Segments.LastOrDefault()?.End??StartedAt) ? Segments.LastOrDefault()?.End??StartedAt : end; }
    public double Duration(DateTimeOffset now, DateTimeOffset? from) => Segments.Concat(Live(now) is {} live ? new[]{live}:Array.Empty<Segment>()).Sum(s=>Math.Max(0,(s.End-(from is {} f && f>s.Start?f:s.Start)).TotalSeconds));
}
public sealed class DayRecord {
    public string Day {get;set;}=""; public List<TaskItem> Tasks {get;set;}=new(); public HashSet<Guid> Completed {get;set;}=new();
}
public sealed class Preferences {
    public string Language {get;set;}="zh-Hans"; public string Theme {get;set;}="classic"; public string Effect {get;set;}="soft";
    public EffectConfiguration? ScreenEffect {get;set;}
    [System.Text.Json.Serialization.JsonIgnore] public EffectConfiguration EffectOptions => ScreenEffect??EffectConfiguration.Preset(Intensity);
    public int Intensity {get;set;}=1; public bool Effects {get;set;}=true; public bool OnTop {get;set;}=true; public double Size {get;set;}=56;
    public double X {get;set;}=80; public double Y {get;set;}=80; public string QuoteId {get;set;}=""; public DateTimeOffset QuoteAt {get;set;}
}
public sealed class Document {
    public int Version {get;set;}=1; public List<TaskItem> Tasks {get;set;}=new(); public List<DayRecord> History {get;set;}=new();
    public List<Activity> Activities {get;set;}=new(); public List<Session> Sessions {get;set;}=new(); public Guid? Pending {get;set;}
    public Preferences Preferences {get;set;}=new();
    public Session? Active => Sessions.FirstOrDefault(s=>s.EndedAt==null);
    public Session? Displayed => Active??Sessions.FirstOrDefault(s=>s.Id==Pending);
    public void Validate() {
        if(Version!=1) throw new InvalidDataException(Resources.L("无法识别数据文件版本，请使用兼容的 FocusDesk 版本打开。"));
        if(Tasks.Select(x=>x.Id).Distinct().Count()!=Tasks.Count || Activities.Select(x=>x.Id).Distinct().Count()!=Activities.Count || Sessions.Select(x=>x.Id).Distinct().Count()!=Sessions.Count || Sessions.Count(x=>x.EndedAt==null)>1) throw new InvalidDataException("Invalid identifiers or active sessions");
        var ordered=Tasks.OrderBy(t=>t.StartMinutes).ToList();
        for(int i=0;i<ordered.Count;i++) { var t=ordered[i]; if(string.IsNullOrWhiteSpace(t.Title)||t.StartMinutes<0||t.EndMinutes>1440||t.EndMinutes<=t.StartMinutes||(i>0&&ordered[i-1].EndMinutes>t.StartMinutes)) throw new InvalidDataException(Resources.L("“%@”与“%@”的时间段重叠，请调整时间。",t.Title,i>0?ordered[i-1].Title:t.Title)); }
        foreach(var s in Sessions) {
            if(!Activities.Any(a=>a.Id==s.ActivityId)||s.EndedAt!=null&&s.RunningSince!=null||s.Target is {} target&&(!double.IsFinite(target)||target<1||target>604800||s.Saved>target+0.001)) throw new InvalidDataException("Invalid timer");
            var previous=s.StartedAt;
            foreach(var segment in s.Segments) { if(segment.Start<previous||segment.End<segment.Start) throw new InvalidDataException("Invalid time segment");previous=segment.End; }
            if(s.RunningSince<previous||s.EndedAt<previous) throw new InvalidDataException("Invalid timer sequence");
        }
        if(Pending is {} id && (Active!=null||Sessions.All(s=>s.Id!=id||s.EndedAt==null||s.Target==null||Math.Abs(s.Saved-s.Target.Value)>0.001))) throw new InvalidDataException("Invalid pending reminder");
        Preferences.ScreenEffect = Preferences.EffectOptions.Normalized();
        var p=Preferences; if(!double.IsFinite(p.Size)||!double.IsFinite(p.X)||!double.IsFinite(p.Y)||p.Size<32||p.Size>112||p.Intensity<0||p.Intensity>3) throw new InvalidDataException("Invalid window preferences");
    }
}
public sealed class Store {
    public Document State {get;private set;} = new(); public string? Error {get;private set;} public bool Blocked {get;private set;}
    public readonly string FilePath;
    public event Action? Changed; public event Action? Completed;
    public Store(string directory,string language) {
        FilePath=Path.Combine(directory,"desktop.json"); Resources.Language=language;
        if(File.Exists(FilePath)) {
            try { State=JsonSerializer.Deserialize<Document>(File.ReadAllText(FilePath),Resources.Json)!;State.Validate(); }
            catch(Exception ex) { Blocked=true;Error=ex.Message;try{File.Copy(FilePath,FilePath+".corrupt-"+Guid.NewGuid());}catch{} }
        } else { State.Preferences.Language=language;State.Tasks=Resources.Read<List<TaskItem>>("default-plan.json");foreach(var t in State.Tasks){t.Title=Resources.L(t.Title);t.Details=Resources.L(t.Details);} }
        Resources.Language=State.Preferences.Language;
    }
    public bool Commit(Action<Document> change) {
        if(Blocked) return false;
        try {
            var next=JsonSerializer.Deserialize<Document>(JsonSerializer.Serialize(State,Resources.Json),Resources.Json)!;
            change(next);next.Validate();Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            var temp=FilePath+".tmp";File.WriteAllText(temp,JsonSerializer.Serialize(next,Resources.Json));File.Move(temp,FilePath,true);
            State=next;Resources.Language=next.Preferences.Language;Error=null;Changed?.Invoke();return true;
        } catch(Exception ex) { Error=ex.Message;Changed?.Invoke();return false; }
    }
    public static DayRecord Today(Document d,DateTimeOffset now) {
        string day=now.LocalDateTime.ToString("yyyy-MM-dd",CultureInfo.InvariantCulture);
        var record=d.History.FirstOrDefault(x=>x.Day==day);
        if(record==null) {record=new DayRecord{Day=day};d.History.Add(record);}
        record.Tasks=d.Tasks.Select(x=>new TaskItem{Id=x.Id,StartMinutes=x.StartMinutes,EndMinutes=x.EndMinutes,Title=x.Title,Details=x.Details}).ToList();
        record.Completed.IntersectWith(record.Tasks.Select(x=>x.Id));return record;
    }
    public void Tick(DateTimeOffset now) {
        var s=State.Active;
        if(s is {Target:not null,RunningSince:not null} && s.Remaining(now)<=0) {
            if(Commit(d=>{d.Active!.Finish(now);d.Pending=s.Id;Today(d,now);})) Completed?.Invoke();
        } else if(!State.History.Any(x=>x.Day==now.LocalDateTime.ToString("yyyy-MM-dd"))) Commit(d=>Today(d,now));
    }
    public bool Start(Guid activity,double? target,DateTimeOffset now) => Commit(d=>{
        if(d.Active!=null) throw new InvalidOperationException(Resources.L("请先结束当前计时，再开始其他计时。"));
        if(!d.Activities.Any(a=>a.Id==activity)) throw new InvalidOperationException(Resources.L("请选择一个事项。"));
        d.Pending=null;d.Sessions.Add(new Session{ActivityId=activity,Target=target,StartedAt=now,RunningSince=now});
    });
    public bool Pause(DateTimeOffset now) => Commit(d=>{if(d.Active is {} s){if(s.RunningSince!=null) { if(s.Target!=null&&s.Remaining(now)<=0){s.Finish(now);d.Pending=s.Id;}else s.Pause(now);}else s.RunningSince=now<(s.Segments.LastOrDefault()?.End??s.StartedAt)?s.Segments.LastOrDefault()?.End??s.StartedAt:now;}});
    public bool Finish(DateTimeOffset now)=>Commit(d=>{d.Active?.Finish(now);d.Pending=null;});
    public bool Extend(DateTimeOffset now) { if(State.Pending==null)return false;var id=State.Displayed!.ActivityId;return Start(id,300,now); }
    public double Total(Guid id, DateTimeOffset now,DateTimeOffset? from=null)=>State.Sessions.Where(x=>x.ActivityId==id).Sum(x=>x.Duration(now,from));
    public bool AddActivity(string name)=>Commit(d=>{name=name.Trim();if(name.Length==0||d.Activities.Any(a=>string.Equals(a.Name,name,StringComparison.OrdinalIgnoreCase)))throw new InvalidOperationException(Resources.L("已有同名事项，请使用其他名称。"));d.Activities.Add(new Activity{Name=name});});
    public bool DeleteActivity(Guid id)=>Commit(d=>{d.Activities.RemoveAll(a=>a.Id==id);d.Sessions.RemoveAll(s=>s.ActivityId==id);if(!d.Sessions.Any(s=>s.Id==d.Pending))d.Pending=null;});
}
