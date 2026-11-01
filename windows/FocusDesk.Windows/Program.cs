using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
namespace FocusDesk;
public static class Program {
    [STAThread] public static int Main(string[] args) {
        bool smoke=args.Contains("--smoke"),test=args.Contains("--self-test");
        if(test)return SelfTests.Run();
        using var single=new Mutex(true,"Local\\FocusDesk.Desktop",out bool acquired);if(!acquired&&!smoke)return 0;
        string language=File.Exists(Path.Combine(AppContext.BaseDirectory,"default-language.txt"))?File.ReadAllText(Path.Combine(AppContext.BaseDirectory,"default-language.txt")).Trim():"zh-Hans";
        string directory=smoke?Path.Combine(Path.GetTempPath(),"FocusDesk-Smoke-"+Guid.NewGuid()):Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"FocusDesk");
        var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};Desktop? desktop=null;int exitCode=0;
        app.Startup+=(_,_)=>{
            var store=new Store(directory,language);desktop=new Desktop(store,smoke);
            if(smoke){store.AddActivity(Resources.L("运动"));store.Start(store.State.Activities[0].Id,1500,DateTimeOffset.Now);var timer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(800)};timer.Tick+=(_,_)=>{timer.Stop();try{desktop.Screenshots(Path.GetFullPath("build/windows-screenshots"));Console.WriteLine("PASS: native Windows desktop rendering, both languages and all themes");}catch(Exception ex){File.WriteAllText("windows-smoke-error.txt",ex.ToString());exitCode=1;}finally{app.Shutdown();}};timer.Start();}
        };
        app.Exit+=(_,_)=>{desktop?.Dispose();if(smoke)try{Directory.Delete(directory,true);}catch{}};
        app.DispatcherUnhandledException+=(_,e)=>{MessageBox.Show(e.Exception.Message,"FocusDesk");e.Handled=true;exitCode=1;if(smoke)app.Shutdown();};
        app.Run();return exitCode;
    }
}
