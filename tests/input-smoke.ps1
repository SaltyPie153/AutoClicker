# Run on an unlocked Windows desktop. Each input is aimed at the temporary test window.
$ErrorActionPreference='Stop'
$path=Join-Path $PSScriptRoot '../POS-Touch.bat'
$source=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $path))
$source=$source.Substring($source.IndexOf('/* POS_SOURCE */',[StringComparison]::Ordinal))
$source += @'

public sealed class InputSurface : System.Windows.Forms.Form {
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern System.IntPtr WindowFromPoint(System.Drawing.Point p);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool GetCursorPos(out System.Drawing.Point p);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetCursorPos(int x,int y);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool GetPointerType(uint id, out uint type);
    int pd,pu,md,mu;
    System.Drawing.Point received;
    protected override void WndProc(ref System.Windows.Forms.Message m) {
        int xy=unchecked((int)m.LParam.ToInt64());
        if (m.Msg==0x246 || m.Msg==0x247) {
            uint type;
            if (GetPointerType((uint)(m.WParam.ToInt64() & 65535),out type) && type==2) {
                if (m.Msg==0x246) pd++; else pu++;
                received=new System.Drawing.Point((short)xy,(short)(xy>>16));
            }
        }
        if (m.Msg==0x201 || m.Msg==0x202) {
            if (m.Msg==0x201) md++; else mu++;
            received=PointToScreen(new System.Drawing.Point((short)xy,(short)(xy>>16)));
        }
        base.WndProc(ref m);
    }
    public static void Test(string method,string sourcePath) {
        var flags=System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Static;
        var t=typeof(PosTap);
        t.GetMethod("SetThreadDpiAwarenessContext",flags).Invoke(null,new object[]{new System.IntPtr(-4)});
        var instance=System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance;
        var dir=System.IO.Path.Combine(System.IO.Path.GetTempPath(),System.Guid.NewGuid().ToString("N"));
        using (var app=(PosTap)System.Activator.CreateInstance(t,instance,null,new object[]{
            System.IO.Path.Combine(dir,"coordinates.json"),System.IO.Path.Combine(dir,"login.bat"),sourcePath},null))
        using (var f=new InputSurface()){
            var mode=(System.Windows.Forms.CheckBox)t.GetField("touchOnly",instance).GetValue(app);
            if (mode.Checked) throw new System.Exception("New settings should default to left click");
            mode.Checked=method=="Touch";
            f.Text="AutoClicker input test";
            f.BackColor=System.Drawing.Color.DarkSlateGray;
            f.StartPosition=System.Windows.Forms.FormStartPosition.CenterScreen;
            f.ClientSize=new System.Drawing.Size(240,120);
            f.TopMost=true;
            f.Show(); f.Activate();
            System.Drawing.Point prior;
            bool gotPrior=GetCursorPos(out prior);
            var p=f.PointToScreen(new System.Drawing.Point(120,60));
            try {
                for(int i=0;i<12;i++) { System.Windows.Forms.Application.DoEvents(); System.Threading.Thread.Sleep(25); }
                if (method=="Touch" && !(bool)t.GetMethod("InitializeTouchInjection",flags).Invoke(null,new object[]{1u,1u}))
                    throw new System.Exception("Could not initialize touch");
                if (WindowFromPoint(p)!=f.Handle) throw new System.Exception("Test window is not at target; abort");
                if (!(bool)t.GetMethod("SendSelectedInput",instance).Invoke(app,new object[]{p})) throw new System.Exception("Input unavailable");
                for(int i=0;i<35;i++) { System.Windows.Forms.Application.DoEvents(); System.Threading.Thread.Sleep(15); }
                System.Console.WriteLine("Method="+method+" expected="+p+" received="+f.received+
                    " touchDown/up="+f.pd+"/"+f.pu+" mouseDown/up="+f.md+"/"+f.mu);
                bool ok=method=="Touch" ? f.pd==1 && f.pu==1 : f.md==1 && f.mu==1 && f.pd==0;
                if (!ok || f.received!=p) throw new System.Exception("Input target did not receive the expected pair at the selected pixel");
            } finally {
                System.Drawing.Point current;
                if (gotPrior && GetCursorPos(out current) && current==p) SetCursorPos(prior.X,prior.Y);
                f.Close();
            }
        }
    }
}
'@
Add-Type -TypeDefinition $source -ReferencedAssemblies System.Drawing,System.Windows.Forms,System.Runtime.Serialization,System.Xml
[InputSurface]::Test('MouseClickAt',(Resolve-Path $path).Path)
[InputSurface]::Test('Touch',(Resolve-Path $path).Path)
