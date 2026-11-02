# Uses a disposable Startup folder, never the current user's Windows Startup folder.
$ErrorActionPreference='Stop'
$source=(Get-Item -LiteralPath (Join-Path $PSScriptRoot '../POS-Touch.bat')).FullName
$code=[IO.File]::ReadAllText($source)
Add-Type -TypeDefinition $code.Substring($code.IndexOf('/* POS_SOURCE */',[StringComparison]::Ordinal)) -ReferencedAssemblies System.Drawing,System.Windows.Forms,System.Runtime.Serialization,System.Xml
$dir=Join-Path ([IO.Path]::GetTempPath()) ('PosTouch-test-'+[guid]::NewGuid().ToString('N'))
$settings=Join-Path $dir 'coordinates.json'
$startup=Join-Path $dir 'Startup/SaltyPie153.AutoClicker.bat'
$flags=[Reflection.BindingFlags]'Instance,NonPublic,Public'
function Check($ok,$message) { if (!$ok) { throw $message } }
function Open-TestForm($file) {
    [Activator]::CreateInstance([PosTap],$flags,$null,@([string]$settings,[string]$startup,[string]$file),$null)
}
function Field($form,$name) { [PosTap].GetField($name,$flags).GetValue($form) }
function Toggle($box) { [Windows.Forms.CheckBox].GetMethod('OnClick',$flags).Invoke($box,@([EventArgs]::Empty)) }
function Show-ForTest($form) { [Windows.Forms.Form].GetMethod('OnShown',$flags).Invoke($form,@([EventArgs]::Empty)) }

$form=Open-TestForm $source
try {
    $opt=Field $form 'startAtLogin'
    Check (!$opt.Checked -and !(Test-Path -LiteralPath $startup)) 'Must be opt-in'
    Toggle $opt
    Check (!$opt.Checked -and !(Test-Path -LiteralPath $startup)) 'Registered without a schedule'
    $row=(Field $form 'rows')[0]
    $row.time.Text='09:00'
    $target=[Activator]::CreateInstance([PosTap].GetNestedType('Target','NonPublic'),$true)
    $target.point=[Windows.Forms.Screen]::PrimaryScreen.Bounds.Location
    $row.target=$target
    Toggle $opt
    Check ($opt.Checked -and (Test-Path -LiteralPath $settings)) ('Did not save schedule when opted in: '+(Field $form 'status').Text)
    Check ((Get-FileHash $startup).Hash -eq (Get-FileHash $source).Hash) 'Startup file differs from current program'
    Show-ForTest $form
    Check (!(Field $form 'clock').Enabled) 'Manual launch armed automatically'
} finally { $form.Dispose() }
[IO.File]::WriteAllText($startup,'older version')
$updated=Open-TestForm $source
try {
    [PosTap].GetMethod('Arm',$flags).Invoke($updated,@())
    Check ((Get-FileHash $startup).Hash -eq (Get-FileHash $source).Hash) 'New version did not refresh the registered copy'
} finally { $updated.Dispose() }
$login=Open-TestForm $startup
try {
    Show-ForTest $login
    Check ((Field $login 'clock').Enabled -and $login.WindowState -eq 'Minimized') 'Login launch did not auto-arm'
    Toggle (Field $login 'startAtLogin')
    Check (!(Test-Path -LiteralPath $startup)) 'Disabling did not remove startup copy'
    Toggle (Field $login 'startAtLogin')
    Check ((Test-Path -LiteralPath $startup)) 'Could not re-enable from the startup instance'
} finally { $login.Dispose() }
[IO.File]::WriteAllText($settings,'bad json')
$bad=Open-TestForm $startup
try {
    Show-ForTest $bad
    Check (!(Field $bad 'clock').Enabled -and $bad.WindowState -ne 'Minimized') 'Invalid settings armed or hid the form'
    Toggle (Field $bad 'startAtLogin')
    Check (!(Test-Path -LiteralPath $startup)) 'Could not disable with invalid settings'
} finally { $bad.Dispose() }
[IO.File]::Delete($settings)
[IO.Directory]::Delete([IO.Path]::GetDirectoryName($startup))
[IO.Directory]::Delete($dir)
Write-Output 'PASS: opt in/out, validated saved settings, manual launch idle, login launch minimized and armed, failed setup stays visible.'
