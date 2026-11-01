using System;
using System.IO;
using System.Linq;
using static FocusDesk.Resources;
namespace FocusDesk;
public static class SelfTests {
    public static int Run(){int checks=0;void Check(bool condition,string message){checks++;if(!condition)throw new Exception(message);}
        var directory=Path.Combine(Path.GetTempPath(),"FocusDesk-Test-"+Guid.NewGuid());try{
            var store=new Store(directory,"en");var start=DateTimeOffset.Parse("2026-11-01T10:00:00+08:00");
            Check(store.State.Tasks.Count==28,"Shared daily plan");Check(store.State.Tasks.All(t=>!t.Title.Any(c=>c>='\u3400'&&c<='\u9fff')),"English defaults");
            Check(store.AddActivity("Reading"),"Add activity");var id=store.State.Activities[0].Id;Check(!store.AddActivity("reading"),"Duplicate rejected");
            Check(store.Start(id,120,start),"Countdown start");Check(!store.Start(id,null,start),"Single active timer");store.Pause(start.AddSeconds(30));Check(store.State.Active!.Elapsed(start.AddSeconds(300))==30,"Pause excludes time");store.Pause(start.AddSeconds(300));store.Tick(start.AddSeconds(1000));Check(store.State.Active==null&&store.State.Pending!=null,"Completion retained");Check(store.State.Sessions[0].EndedAt==start.AddSeconds(390),"Deadline capped");Check(store.Total(id,start.AddSeconds(1000))==120,"No overtime");
            var reload=new Store(directory,"zh-Hans");Check(reload.State.Pending!=null&&reload.State.Preferences.Language=="en","Reminder and language reload");Check(reload.Extend(start.AddSeconds(2000)),"Extension");Check(reload.State.Active!.Remaining(start.AddSeconds(2000))==300,"Extension from click");Check(reload.Total(id,start.AddSeconds(2010))==130,"Waiting excluded");reload.Tick(start.AddSeconds(2300));Check(reload.Total(id,start.AddSeconds(5000))==420,"Extension accumulation");reload.Finish(start.AddSeconds(5000));Check(reload.State.Displayed==null,"Acknowledgement");
            reload.Start(id,null,start.AddSeconds(6000));reload.Finish(start.AddSeconds(6060));Check(reload.Total(id,start.AddSeconds(7000))==480,"Stopwatch accumulation");Check(reload.Total(id,start.AddSeconds(7000),start.AddSeconds(6020))==40,"Range clipping");
            var before=File.ReadAllBytes(reload.FilePath);Directory.CreateDirectory(reload.FilePath+".tmp");Check(!reload.AddActivity("Must not save"),"Failed save reported");Check(reload.State.Activities.Count==1&&File.ReadAllBytes(reload.FilePath).SequenceEqual(before),"Failed save rolls back");Directory.Delete(reload.FilePath+".tmp");
            reload.Commit(d=>d.Activities[0].Name="Books");Check(reload.Total(id,start.AddSeconds(7000))==480,"Rename preserves totals");
            Check(!reload.Commit(d=>d.Tasks.Add(new TaskItem{StartMinutes=10,EndMinutes=20,Title="Conflict"})),"Overlapping plan rejected");
            reload.Commit(d=>{Store.Today(d,start).Completed.Add(d.Tasks[0].Id);});reload.Commit(d=>Store.Today(d,start.AddDays(1)));Check(reload.State.History.Single(d=>d.Day==start.LocalDateTime.ToString("yyyy-MM-dd")).Completed.Count==1,"Historical snapshots");Check(reload.State.History.Single(d=>d.Day==start.AddDays(1).LocalDateTime.ToString("yyyy-MM-dd")).Completed.Count==0,"New day resets completion");
            Check(reload.DeleteActivity(id)&&reload.State.Sessions.Count==0,"Delete removes activity history");
            File.WriteAllText(reload.FilePath,"broken");var damaged=new Store(directory,"en");Check(damaged.Blocked&&!damaged.AddActivity("Blocked")&&File.ReadAllText(reload.FilePath)=="broken","Corruption protection");Check(Directory.GetFiles(directory,"*.corrupt-*").Length==1,"Corruption backup");
            Language="en";Check(L("已到时")=="Time's up","English translation");Check(L("%@，%@","用户名称","done")=="用户名称, done","User text unchanged");
            foreach(var size in new[]{new System.Windows.Size(1920,1080),new System.Windows.Size(3440,1440),new System.Windows.Size(900,1600)})
                foreach(var origin in new[]{new System.Windows.Point(0,0),new System.Windows.Point(size.Width/2,size.Height/2),new System.Windows.Point(size.Width-20,10)})
                    foreach(var coverage in new[]{.1,.5,.75,.85,1.0}){
                        double radius=EffectGeometry.Radius(size,origin,coverage),ratio=EffectGeometry.Area(size,origin,radius)/(size.Width*size.Height);
                        Check(Math.Abs(ratio-coverage)<.003,"Coverage reaches requested screen area");
                    }
            var old=System.Text.Json.JsonSerializer.Deserialize<Preferences>("{\"intensity\":2}",Resources.Json)!;
            Check(old.EffectOptions.Coverage==.85,"Old dramatic preset migration");
            var custom=EffectConfiguration.Preset(3);custom.Coverage=.72;custom.AllScreens=true;
            var roundTrip=System.Text.Json.JsonSerializer.Deserialize<EffectConfiguration>(System.Text.Json.JsonSerializer.Serialize(custom,Resources.Json),Resources.Json)!;
            Check(roundTrip.Coverage==.72&&roundTrip.AllScreens&&roundTrip.Waves==3,"Fine settings round trip");
            var bounded=new EffectConfiguration{Coverage=double.NaN,Duration=50,Waves=8,Dim=-1}.Normalized();
            Check(bounded.Coverage==.5&&bounded.Duration==12&&bounded.Waves==3&&bounded.Dim==0,"Effect bounds");
            Check(Desktop.Themes.Length==11&&Desktop.EffectIds.Length==10,"Desktop feature parity");Console.WriteLine($"PASS: {checks} Windows core checks");return 0;
        }catch(Exception ex){Console.Error.WriteLine(ex);return 1;}finally{try{Directory.Delete(directory,true);}catch{}}
    }
}
