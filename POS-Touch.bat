@echo off
setlocal DisableDelayedExpansion
set "POS_TOUCH_SOURCE=%~f0"
start "POS Touch" /min "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -Command "$ErrorActionPreference='Stop'; try { $s=[IO.File]::ReadAllText($env:POS_TOUCH_SOURCE); $s=$s.Substring($s.IndexOf('/* POS'+'_SOURCE */')); Add-Type -TypeDefinition $s -ReferencedAssemblies System.Drawing,System.Windows.Forms,System.Runtime.Serialization,System.Xml; [PosTap]::Run() } catch { Add-Type -AssemblyName System.Windows.Forms; [void][Windows.Forms.MessageBox]::Show($_.Exception.GetBaseException().Message,'POS Touch') }"
exit /b
/* POS_SOURCE */
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Threading;
using System.Windows.Forms;
using Timer = System.Windows.Forms.Timer;

public sealed class DailyTimes {
    readonly HashSet<int> slots = new HashSet<int>();
    long lastMinute;

    public DailyTimes(string text, DateTime armed) {
        foreach (string part in text.Split(',')) {
            DateTime t;
            if (!DateTime.TryParseExact(part.Trim(), new string[] { "H:mm", "HH:mm" },
                    CultureInfo.InvariantCulture, DateTimeStyles.None, out t))
                throw new FormatException("시각을 24시간제로 입력하세요. 예: 09:00 또는 09:00, 13:30");
            slots.Add(t.Hour * 60 + t.Minute);
        }
        lastMinute = armed.Ticks / TimeSpan.TicksPerMinute;
    }

    public bool Overlaps(DailyTimes other) { return slots.Overlaps(other.slots); }

    public bool Take(DateTime now) {
        long minute = now.Ticks / TimeSpan.TicksPerMinute;
        if (minute <= lastMinute) return false;
        lastMinute = minute;
        return now.Second < 5 && slots.Contains(now.Hour * 60 + now.Minute);
    }
}

public sealed class PosTap : Form {
    [StructLayout(LayoutKind.Sequential)]
    struct Box { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)]
    struct Pointer {
        public uint type, id, frame, flags;
        public IntPtr device, window;
        public Point pixel, metric, rawPixel, rawMetric;
        public uint time, history;
        public int data;
        public uint keys;
        public ulong performance;
        public uint change;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct Contact {
        public Pointer pointer;
        public uint flags, mask;
        public Box area, rawArea;
        public uint orientation, pressure;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct MouseData {
        public int x, y;
        public uint data, flags, time;
        public UIntPtr extra;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct MouseEntry {
        public uint type; // INPUT_MOUSE = 0
        public MouseData mouse;
    }
    [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint count, [In] MouseEntry[] entries, int entrySize);
    [DllImport("user32.dll", SetLastError=true)] static extern bool InitializeTouchInjection(uint count, uint feedback);
    [DllImport("user32.dll", SetLastError=true)] static extern bool InjectTouchInput(uint count, ref Contact contact);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    [DataContract]
    sealed class Target {
        [DataMember(IsRequired=true)] public Point point;
    }
    [DataContract]
    sealed class SavedRow {
        [DataMember(IsRequired=true)] public string name, time;
        [DataMember(IsRequired=true)] public Target target;
        [DataMember(EmitDefaultValue=false)] public bool touchOnly;
    }
    sealed class Row {
        public string name;
        public readonly TextBox time = new TextBox();
        public readonly Button select = new Button();
        public readonly Label result = new Label();
        public Target target;
        public DailyTimes schedule;
    }
    readonly Row[] rows = { new Row { name="오픈" }, new Row { name="클로즈" } };
    readonly Timer clock = new Timer { Interval=300 };
    readonly Timer captureDelay = new Timer { Interval=5000 };
    readonly Button start = new Button();
    readonly CheckBox touchOnly = new CheckBox();
    readonly Label status = new Label();
    Row picking;
    readonly string settingsPath;
    bool initialized, dirty;

    public static void Run() {
        try {
            if (SetThreadDpiAwarenessContext(new IntPtr(-4)) == IntPtr.Zero) SetProcessDPIAware();
        } catch (EntryPointNotFoundException) { SetProcessDPIAware(); }
        bool first;
        using (Mutex mutex = new Mutex(true, @"Local\POS-Daily-Attendance-Touch-v1", out first)) {
            if (!first) { MessageBox.Show("이미 실행 중입니다. 작업 표시줄에서 예약 창을 여세요.", "POS 예약 터치"); return; }
            Application.EnableVisualStyles();
            string settings = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "POS-Touch","coordinates.json");
            using (PosTap form = new PosTap(settings)) Application.Run(form);
        }
    }

    void Put(Control c, string text, int x, int y, int width, int height) {
        c.Text = text;
        c.SetBounds(x,y,width,height);
        Controls.Add(c);
    }
    PosTap(string settingsPath) {
        this.settingsPath=settingsPath;
        Text = "포스기 오픈·클로즈 좌표 클릭";
        Font = new Font("Malgun Gothic", 10);
        AutoScaleDimensions = new SizeF(96,96);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(575,325);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        Put(new Label(), "매일 실행할 시각을 입력하세요. 예: 09:00, 13:30", 16,14,550,23);
        Put(new Label(), "위치 선택을 누르면 5초 뒤 화면 사진이 뜹니다.\n버튼이 아직 없어도 됩니다. 사진에서 나중에 누를 지점을 선택하세요.", 16,42,550,48);
        for (int i=0; i<rows.Length; i++) {
            Row row = rows[i];
            int y = 99 + i*44;
            Put(new Label(), row.name, 16,y+4,50,25);
            Put(row.time, "", 70,y,134,30);
            Put(row.select, row.name+" 위치 선택", 216,y-2,136,32);
            Put(row.result, "위치 미등록", 363,y+4,205,34);
            row.select.Click += delegate { picking=row; Hide(); captureDelay.Start(); };
        }
        Put(touchOnly,"터치 전용 포스 입력 (기본은 마우스 왼쪽 클릭)",16,183,540,30);
        Put(start, "예약 시작", 16,224,188,37);
        Put(new Label(), "다른 화면이 열려 있어도 같은 좌표를 누릅니다.", 217,232,350,28);
        Put(status, "시각과 위치를 모두 등록한 항목만 실행합니다.",16,277,548,40);
        start.Click += delegate { if (clock.Enabled) Stop("예약을 중지했습니다."); else Arm(); };
        clock.Tick += delegate { TickSchedule(DateTime.Now,SendSelectedInput); };
        captureDelay.Tick += delegate {
            captureDelay.Stop();
            try { Pick(picking); }
            catch (Exception e) { status.Text="위치 등록 실패 · "+e.Message; }
            finally { Show(); Activate(); }
        };
        try { LoadSettings(); }
        catch (Exception) { status.Text="저장한 설정을 읽을 수 없습니다. 시각과 위치를 다시 등록하세요."; }
        foreach (Row row in rows) row.time.TextChanged += delegate { dirty=true; };
        touchOnly.CheckedChanged += delegate { dirty=true; };
        FormClosing += delegate(object sender, FormClosingEventArgs e) {
            if (!dirty) return;
            try { SaveSettings(); }
            catch (Exception ex) {
                e.Cancel=MessageBox.Show(this,"설정을 저장하지 못했습니다. 변경 내용을 저장하지 않고 닫을까요?\n"+ex.Message,
                    Text,MessageBoxButtons.YesNo,MessageBoxIcon.Warning)!=DialogResult.Yes;
            }
        };
        FormClosed += delegate { clock.Dispose(); captureDelay.Dispose(); };
    }

    void SaveSettings() {
        SavedRow[] saved=Array.ConvertAll(rows,r => new SavedRow { name=r.name, time=r.time.Text, target=r.target, touchOnly=touchOnly.Checked });
        Directory.CreateDirectory(Path.GetDirectoryName(settingsPath));
        string tmp=settingsPath+"."+Guid.NewGuid().ToString("N")+".tmp";
        try {
            using (FileStream file=File.Open(tmp,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {
                new DataContractJsonSerializer(typeof(SavedRow[])).WriteObject(file,saved);
                file.Flush(true);
            }
            if (File.Exists(settingsPath)) File.Replace(tmp,settingsPath,null);
            else File.Move(tmp,settingsPath);
            dirty=false;
        } finally { if (File.Exists(tmp)) File.Delete(tmp); }
    }
    void LoadSettings() {
        string source=File.Exists(settingsPath) ? settingsPath : Path.Combine(Path.GetDirectoryName(settingsPath),"open-close.json");
        if (!File.Exists(source)) return;
        SavedRow[] saved;
        using (FileStream file=File.OpenRead(source)) {
            if (file.Length>512*1024) throw new InvalidDataException();
            saved=(SavedRow[])new DataContractJsonSerializer(typeof(SavedRow[])).ReadObject(file);
        }
        if (saved==null || saved.Length!=rows.Length) throw new InvalidDataException();
        for (int i=0;i<rows.Length;i++) {
            SavedRow s=saved[i];
            if (s==null || s.name!=rows[i].name || s.time==null || s.time.Length>rows[i].time.MaxLength)
                throw new InvalidDataException();
        }
        for (int i=0;i<rows.Length;i++) {
            rows[i].time.Text=saved[i].time;
            SetTarget(rows[i],saved[i].target);
        }
        touchOnly.Checked=saved[0].touchOnly;
        dirty=source!=settingsPath;
        status.Text="저장한 좌표와 시각을 불러왔습니다. 확인 후 예약 시작을 누르세요.";
    }
    static void SetTarget(Row row, Target target) {
        row.target=target;
        row.result.Text=target==null ? "위치 미등록" : String.Format("등록됨 ({0}, {1})",target.point.X,target.point.Y);
    }

    static bool OnScreen(Point point) {
        return Array.Exists(Screen.AllScreens, screen => screen.Bounds.Contains(point));
    }
    static Bitmap Grab(Rectangle area) {
        Bitmap image = new Bitmap(area.Width,area.Height,PixelFormat.Format24bppRgb);
        try {
            using (Graphics g=Graphics.FromImage(image))
                g.CopyFromScreen(area.Location,Point.Empty,area.Size,CopyPixelOperation.SourceCopy);
            return image;
        } catch { image.Dispose(); throw; }
    }
    public static Point ImagePoint(Size view, Size photo, Point p) {
        float scale = Math.Min((float)view.Width/photo.Width,(float)view.Height/photo.Height);
        int w=(int)(photo.Width*scale), h=(int)(photo.Height*scale);
        Rectangle shown = new Rectangle((view.Width-w)/2,(view.Height-h)/2,w,h);
        if (!shown.Contains(p)) return new Point(-1,-1);
        return new Point((int)((long)(p.X-shown.X)*photo.Width/w), (int)((long)(p.Y-shown.Y)*photo.Height/h));
    }
    static Point Choose(Bitmap image, string name) {
        Point choice = new Point(-1,-1);
        using (Form picker=new Form())
        using (PictureBox picture=new PictureBox()) {
            picker.Text="캡처 사진 · "+name+" 등록 버튼이 뜰 예상 위치의 중앙을 누르세요.";
            picker.StartPosition=FormStartPosition.CenterScreen;
            picker.WindowState=FormWindowState.Maximized;
            picture.Dock=DockStyle.Fill;
            picture.BackColor=Color.DimGray;
            picture.SizeMode=PictureBoxSizeMode.Zoom;
            picture.Image=image;
            picture.MouseClick += delegate(object sender, MouseEventArgs e) {
                if (e.Button!=MouseButtons.Left) return;
                choice=ImagePoint(picture.ClientSize,image.Size,e.Location);
                if (choice.X>=0) picker.Close();
            };
            picker.Controls.Add(picture);
            picker.ShowDialog();
            picture.Image=null;
        }
        return choice;
    }
    void Pick(Row row) {
        Rectangle area=SystemInformation.VirtualScreen;
        using (Bitmap image=Grab(area)) {
            Point p=Choose(image,row.name);
            if (p.X<0) { status.Text="위치 선택을 취소했습니다."; return; }
            p.Offset(area.Location);
            if (!OnScreen(p)) throw new InvalidOperationException("모니터에 표시되는 지점을 선택하세요.");
            SetTarget(row,new Target { point=p });
            dirty=true;
            try { SaveSettings(); status.Text=row.name+" 위치를 저장했습니다."; }
            catch (Exception ex) { status.Text="현재 위치는 등록됐지만 파일 저장에 실패했습니다. "+ex.Message; }
        }
    }
    void EnableSetup(bool enabled) {
        foreach (Row row in rows) { row.time.Enabled=enabled; row.select.Enabled=enabled; }
        touchOnly.Enabled=enabled;
        start.Text=enabled ? "예약 시작" : "예약 중지";
    }
    void Stop(string message) { clock.Stop(); EnableSetup(true); status.Text=message; }
    void Arm() {
        try {
            DateTime now=DateTime.Now;
            foreach (Row row in rows) {
                row.schedule=null;
                if (String.IsNullOrWhiteSpace(row.time.Text)) continue;
                if (row.target==null) throw new FormatException(row.name+" 버튼 위치를 먼저 선택하세요.");
                if (!OnScreen(row.target.point)) throw new FormatException(row.name+" 좌표가 현재 모니터 밖에 있습니다. 위치를 다시 선택하세요.");
                row.schedule=new DailyTimes(row.time.Text,now);
            }
            if (rows[0].schedule==null && rows[1].schedule==null) throw new FormatException("예약할 시각을 입력하세요.");
            if (rows[0].schedule!=null && rows[1].schedule!=null && rows[0].schedule.Overlaps(rows[1].schedule))
                throw new FormatException("오픈과 클로즈 시각이 겹칩니다.");
            if (dirty) SaveSettings();
            if (touchOnly.Checked && !initialized) {
                if (!InitializeTouchInjection(1,1)) throw new Win32Exception(Marshal.GetLastWin32Error());
                initialized=true;
            }
            EnableSetup(false);
            status.Text="예약 중 · 저장한 좌표에 "+(touchOnly.Checked ? "터치" : "왼쪽 클릭")+" 한 번을 보냅니다.";
            clock.Start(); WindowState=FormWindowState.Minimized;
        } catch (Exception e) { status.Text="예약 시작 실패 · "+e.Message; }
    }

    static void Frame(ref Contact tap, uint flags) {
        tap.pointer.flags=flags;
        for (int i=0; ; i++) {
            if (InjectTouchInput(1,ref tap)) return;
            int error=Marshal.GetLastWin32Error();
            if (error!=21 || i>=3) throw new Win32Exception(error);
            Thread.Sleep(2);
        }
    }
    static bool InputAvailable(Point p) {
        Point cursor;
        // GetCursorPos fails when this process does not have access to the input desktop.
        return OnScreen(p) && GetCursorPos(out cursor);
    }
    bool SendSelectedInput(Point p) {
        return touchOnly.Checked ? Touch(p) : MouseClickAt(p);
    }
    static bool MouseClickAt(Point p) {
        if (!InputAvailable(p)) return false;
        Rectangle desktop=SystemInformation.VirtualScreen;
        // Aim at the middle of the pixel's 0..65535 absolute-coordinate interval.
        MouseEntry move=new MouseEntry();
        move.mouse.x=(int)((((long)p.X-desktop.Left)*65536+32768)/desktop.Width);
        move.mouse.y=(int)((((long)p.Y-desktop.Top)*65536+32768)/desktop.Height);
        move.mouse.flags=0xC001; // MOVE | VIRTUALDESK | ABSOLUTE
        MouseEntry down=new MouseEntry(), up=new MouseEntry();
        down.mouse.flags=2; up.mouse.flags=4; // LEFTDOWN, LEFTUP
        int size=Marshal.SizeOf(typeof(MouseEntry));
        uint sent=SendInput(3,new MouseEntry[] { move,down,up },size);
        if (sent==3) return true;
        int error=Marshal.GetLastWin32Error();
        if (sent==2) SendInput(1,new MouseEntry[] { up },size);
        throw new InvalidOperationException(String.Format("왼쪽 클릭 전송 실패 (입력 {0}/3, Windows {1})",sent,error));
    }
    static bool Touch(Point p) {
        if (!InputAvailable(p)) return false;
        Contact tap=new Contact();
        tap.pointer.type=2; // PT_TOUCH
        tap.pointer.id=0; // The single initialized contact occupies slot zero.
        tap.pointer.pixel=p;
        tap.mask=1; // TOUCH_MASK_CONTACTAREA
        tap.area=new Box { left=p.X-2,top=p.Y-2,right=p.X+2,bottom=p.Y+2 };
        Frame(ref tap,0x10006); // DOWN | INRANGE | INCONTACT
        try {
            Thread.Sleep(16); Frame(ref tap,0x20006); // UPDATE | INRANGE | INCONTACT
            Thread.Sleep(16); Frame(ref tap,0x40000); // UP
        } catch {
            tap.pointer.flags=0x48000; // CANCELED | UP
            InjectTouchInput(1,ref tap);
            throw;
        }
        return true;
    }
    void TickSchedule(DateTime now, Func<Point,bool> sendTouch) {
        foreach (Row row in rows) {
            if (row.schedule==null || !row.schedule.Take(now)) continue;
            try {
                bool sent=sendTouch(row.target.point);
                row.result.Text=now.ToString("HH:mm")+" "+(sent ? (touchOnly.Checked ? "터치 전송" : "클릭 전송") : "화면 사용 불가 · 건너뜀");
            } catch (Exception e) {
                row.result.Text=now.ToString("HH:mm")+" 오류";
                Stop(row.name+" 예약 중지 · "+e.Message);
                return;
            }
        }
    }
}
