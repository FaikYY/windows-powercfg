# AllPowerSettingsManager.ps1
# Full power settings manager (WPF) for Windows:
# - Enumerates ALL power settings (visible + hidden) via powercfg /qh (fallback to /q)
# - Lets you edit Plugged-in / On-battery values (numeric or choice indexes)
# - Create & name a NEW plan from a base template (alias or GUID), then activate it
# - Shows official Description pulled from registry and resolved via SHLoadIndirectString
# - Real-time search in the LEFT panel (filters subgroups to only matching items)
# Run as Administrator

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

# Check for admin and Windows PowerShell
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  [System.Windows.MessageBox]::Show("Please run this script as Administrator.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
  Exit
}
if ($PSVersionTable.PSEdition -ne 'Desktop') {
  [System.Windows.MessageBox]::Show("This script requires Windows PowerShell (not PowerShell Core).", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
  Exit
}

# --- Load SHLoadIndirectString to resolve MUI @-style strings from the registry ---
Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class PowrprofNative {
  [DllImport("shlwapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
  public static extern int SHLoadIndirectString(string pszSource, StringBuilder pszOutBuf, int cchOutBuf, IntPtr pvReserved);
}
"@

function Resolve-MUIString {
  param([string]$s)
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  if ($s.StartsWith('@')) {
    $sb = New-Object System.Text.StringBuilder 2048
    [void][PowrprofNative]::SHLoadIndirectString($s, $sb, $sb.Capacity, [IntPtr]::Zero)
    $val = $sb.ToString()
    if (![string]::IsNullOrWhiteSpace($val)) { return $val }
  }
  return $s
}

function Get-SettingMeta {
  param([Parameter(Mandatory)][string]$SubGuid,
    [Parameter(Mandatory)][string]$SetGuid)
  $path = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\$SubGuid\$SetGuid"
  try {
    $p = Get-ItemProperty -Path $path -ErrorAction Stop
    [pscustomobject]@{
      FriendlyName = Resolve-MUIString $p.FriendlyName
      Description  = Resolve-MUIString $p.Description
    }
  }
  catch { $null }
}

# --------------------- powercfg wrappers ---------------------
function Invoke-PowerCfg {
  param([Parameter(Mandatory)][string[]]$Args)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "$env:SystemRoot\System32\powercfg.exe"
  $psi.Arguments = ($Args -join ' ')
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

function Get-ActiveSchemeGuid {
  $out = Invoke-PowerCfg @("/getactivescheme")
  if ($out.StdOut -match '(?i)GUID:\s*([a-f0-9-]+)') { return $matches[1] }
  return $null
}

function Get-Schemes {
  $out = Invoke-PowerCfg @("/list")
  $schemes = @()
  foreach ($line in ($out.StdOut -split "`r?`n")) {
    if ($line -match '([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})') {
      $guid = $matches[1]
      $name = 'Unnamed'
      if ($line -match '\((.+?)\)') { $name = $matches[1] }
      $schemes += [pscustomobject]@{ Guid = $guid; Name = $name }
    }
  }
  $schemes | Sort-Object Guid -Unique
}

# Create a new plan by duplicating a base, naming it, and (optionally) activating it
function New-Plan {
  param(
    [Parameter(Mandatory)][string]$BaseAlias, # e.g., SCHEME_BALANCED / SCHEME_MAX / SCHEME_MIN or GUID
    [Parameter(Mandatory)][string]$Name,
    [switch]$Activate
  )
  $dup = Invoke-PowerCfg @("/duplicatescheme", $BaseAlias)
  if ($dup.ExitCode -ne 0) { 
    $dup | Out-Host
    throw "Failed to duplicate from ${BaseAlias}: $($dup.StdErr)" 
  }
  if ($dup.StdOut -match '([0-9A-Fa-f-]{36})') {
    $newGuid = $matches[1]
    $quotedName = '"' + $Name.Replace('"', '""') + '"'
    $change = Invoke-PowerCfg @("/changename", $newGuid, $quotedName)
    if ($change.ExitCode -ne 0) {
      # Delete the created plan if rename fails
      [void](Invoke-PowerCfg @("/delete", $newGuid))
      throw "Failed to rename plan: $($change.StdErr)"
    }
    if ($Activate) { [void](Invoke-PowerCfg @("/setactive", $newGuid)) }
    return $newGuid
  }
  else {
    $dup | Out-Host
    throw "Could not parse new GUID from /duplicatescheme output."
  }
}

# Apply values to a plan
function Set-SettingValue {
  param(
    [Parameter(Mandatory)][string]$schemeGuid,
    [Parameter(Mandatory)][string]$subGuid,
    [Parameter(Mandatory)][string]$setGuid,
    [Parameter(Mandatory)][int]$acValue,
    [Parameter(Mandatory)][int]$dcValue
  )
  Write-Host "Applying to plan $schemeGuid, setting $setGuid, AC=$acValue, DC=$dcValue"

  $unhide = Invoke-PowerCfg @("/attributes", $subGuid, $setGuid, "-ATTRIB_HIDE")
  Write-Host "Unhide result: ExitCode=$($unhide.ExitCode), StdErr=$($unhide.StdErr)"
  if ($unhide.ExitCode -ne 0) { throw "Failed to unhide setting: $($unhide.StdErr)" }

  $acSet = Invoke-PowerCfg @("/setacvalueindex", $schemeGuid, $subGuid, $setGuid, $acValue)
  Write-Host "AC set result: ExitCode=$($acSet.ExitCode), StdErr=$($acSet.StdErr)"
  if ($acSet.ExitCode -ne 0) { throw "Failed to set AC value: $($acSet.StdErr)" }

  $dcSet = Invoke-PowerCfg @("/setdcvalueindex", $schemeGuid, $subGuid, $setGuid, $dcValue)
  Write-Host "DC set result: ExitCode=$($dcSet.ExitCode), StdErr=$($dcSet.StdErr)"
  if ($dcSet.ExitCode -ne 0) { throw "Failed to set DC value: $($dcSet.StdErr)" }

  Write-Host "Set completed successfully."
}

# --------------------- Parse powercfg /qh (robust, with /q fallback) ---------------------
function Get-AllPowerSettings {
  param([string]$schemeGuid = $null)
  
  $originalActive = $global:Active
  $tempActivate = $false
  if ($schemeGuid -and $schemeGuid -ne $originalActive) {
    # Temporarily activate the selected scheme to query its settings (including hidden)
    [void](Invoke-PowerCfg @("/setactive", $schemeGuid))
    $global:Active = $schemeGuid
    $tempActivate = $true
  }

  function Parse-Out($text) {
    $lines = @()
    foreach ($L in ($text -split "`r?`n")) { $lines += ($L -replace '[\u00A0]', ' ').TrimEnd() }
    $subs = @(); $sub = $null; $set = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
      $line = $lines[$i]

      if ($line -match '(?i)Sub\s*group\s*GUID:\s*([a-f0-9-]+)\s*\((.*?)\)') {
        $sub = [pscustomobject]@{
          SubGuid  = $matches[1]
          SubName  = $matches[2]
          SubAlias = $null
          Settings = New-Object System.Collections.ArrayList
        }
        $subs += $sub; $set = $null; continue
      }

      if ($line -match '(?i)GUID\s*Alias:\s*(\S+)') {
        if ($set) { $set.Alias = $matches[1] } elseif ($sub) { $sub.SubAlias = $matches[1] }
        continue
      }

      if ($line -match '(?i)Power\s*Setting\s*GUID:\s*([a-f0-9-]+)\s*\((.*?)\)') {
        $set = [pscustomobject]@{
          SetGuid   = $matches[1]
          SetName   = $matches[2]
          Alias     = $null
          SubGuid   = $sub.SubGuid
          SubName   = $sub.SubName
          Units     = $null
          Min       = $null
          Max       = $null
          Increment = $null
          Choices   = New-Object System.Collections.ArrayList
          AC        = $null
          DC        = $null
        }
        [void]$sub.Settings.Add($set); continue
      }

      if ($line -match '(?i)Possible\s*Setting\s*Index:\s*([0-9A-Fa-f]{3})') {
        $idx = [int]("0x" + $matches[1]); $name = $null
        if ($line -match '(?i)Friendly\s*Name:\s*(.+)$') { $name = $matches[1].Trim() }
        elseif ($i + 1 -lt $lines.Count -and ($lines[$i + 1] -match '(?i)Friendly\s*Name:\s*(.+)$')) { $name = $matches[1].Trim() }
        [void]$set.Choices.Add([pscustomobject]@{ Index = $idx; Name = $name }); continue
      }

      if ($line -match '(?i)Possible\s*Settings\s*units:\s*(.+)$') { $set.Units = $matches[1].Trim(); continue }
      if ($line -match '(?i)Minimum\s*Possible\s*Setting:\s*0x([0-9A-Fa-f]+)') { $set.Min = [int]("0x" + $matches[1]); continue }
      if ($line -match '(?i)Maximum\s*Possible\s*Setting:\s*0x([0-9A-Fa-f]+)') { $set.Max = [int]("0x" + $matches[1]); continue }
      if ($line -match '(?i)Possible\s*Settings\s*increment:\s*0x([0-9A-Fa-f]+)') { $set.Increment = [int]("0x" + $matches[1]); continue }
      if ($line -match '(?i)Current\s*AC\s*Power\s*Setting\s*Index:\s*0x([0-9A-Fa-f]+)') { $set.AC = [int]("0x" + $matches[1]); continue }
      if ($line -match '(?i)Current\s*DC\s*Power\s*Setting\s*Index:\s*0x([0-9A-Fa-f]+)') { $set.DC = [int]("0x" + $matches[1]); continue }
    }
    return $subs
  }

  # Try /qh first (hidden + visible)
  $qh = Invoke-PowerCfg @("/qh")
  $subs = Parse-Out $qh.StdOut
  if ($subs.Count -gt 0) {
    if ($tempActivate) {
      # Restore original active scheme
      [void](Invoke-PowerCfg @("/setactive", $originalActive))
      $global:Active = $originalActive
    }
    return $subs
  }

  # Fallback to /q (visible only)
  $q = Invoke-PowerCfg @("/q")
  $subs = Parse-Out $q.StdOut
  if ($tempActivate) {
    # Restore original active scheme
    [void](Invoke-PowerCfg @("/setactive", $originalActive))
    $global:Active = $originalActive
  }
  return $subs
}

# --------------------- XAML UI ---------------------
$xaml = @"
<Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
        xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Title='All Power Settings Manager'
        Height='800' Width='1500'
        FontFamily='Segoe UI' FontSize='13'
        WindowStartupLocation='CenterScreen'>

  <Grid>
    <!-- Define rows/columns BEFORE children -->
    <Grid.RowDefinitions>
      <RowDefinition Height='Auto'/>
      <RowDefinition Height='*'/>
      <RowDefinition Height='Auto'/>
    </Grid.RowDefinitions>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width='550' MinWidth='250'/>
      <ColumnDefinition Width='Auto'/>
      <ColumnDefinition Width='*'/>
    </Grid.ColumnDefinitions>

    <!-- Top bar -->
      <DockPanel Grid.Row='0' Grid.ColumnSpan='3' Margin='10'>
        <!-- Left section: Plan management buttons -->
        <ComboBox x:Name='PlanCombo' Width='420' Margin='0,0,10,0'/>
        <Button x:Name='SetActiveBtn' Content='Set Active' Width='120' Margin='0,0,10,0'/>
        <Button x:Name='RefreshBtn' Content='Refresh (/qh)' Width='140' Margin='0,0,10,0'/>
        <Button x:Name='ExportBtn' Content='Export Power Profile' Width='140'/>
        <Button x:Name='ImportBtn' Content='Import Power Profile' Width='140' Margin='8,0,0,0'/>
        <Button x:Name='TuneBtn' Content='Tune for Max Performance (AC)' Width='200' Margin='8,0,0,0'/>
        <Separator DockPanel.Dock='Left' Width='1' Margin='0,0,8,0' />
        
        <!-- Right section: Plan selection and other actions -->
        <StackPanel DockPanel.Dock='Left' Orientation='Horizontal' Margin='120,0,0,0'>
          <Button x:Name='CreatePlanBtn' Content='Create plan' Width='120'/>
          <Button x:Name='DeletePlanBtn' Content='Delete plan' Width='120' Margin='8,0,0,0'/>
        </StackPanel>
      </DockPanel>

    <!-- Left tree panel with SEARCH INSIDE -->
    <Border Grid.Row='1' Grid.Column='0' Margin='10' BorderBrush='#DDDDDD' BorderThickness='1' CornerRadius='8'>
      <DockPanel>
        <Grid DockPanel.Dock='Top' Margin='6'>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width='*'/>
            <ColumnDefinition Width='Auto'/>
          </Grid.ColumnDefinitions>
          <TextBox x:Name='SearchBox' Grid.Column='0' Height='28' VerticalContentAlignment='Center'
                   ToolTip='Type to filter settings (name, alias, GUID, subgroup)'/>
          <Button x:Name='ClearSearchBtn' Grid.Column='1' Content='Clear' Margin='6,0,0,0' Height='28' MinWidth='60'/>
        </Grid>
        <ScrollViewer DockPanel.Dock='Bottom'>
          <TreeView x:Name='SettingsTree'/>
        </ScrollViewer>
      </DockPanel>
    </Border>

    <!-- Splitter between left and right -->
    <GridSplitter Grid.Row='1' Grid.Column='1'
                  Width='6' Background='#DDDDDD'
                  HorizontalAlignment='Center' VerticalAlignment='Stretch'
                  ResizeBehavior='PreviousAndNext' ResizeDirection='Columns'/>

    <!-- Right detail panel -->
    <Border Grid.Row='1' Grid.Column='2' Margin='10' BorderBrush='#DDDDDD' BorderThickness='1' CornerRadius='8' Padding='16'>
      <StackPanel>
        <TextBlock Text='Setting' FontSize='18' FontWeight='SemiBold' Margin='0,0,0,6'/>
        <TextBlock x:Name='SelectedPath' Foreground='#666666' Margin='0,0,0,16'/>

        <Grid Margin='0,0,0,10'>
          <Grid.ColumnDefinitions><ColumnDefinition Width='200'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>
          <TextBlock Text='GUID' Grid.Column='0' VerticalAlignment='Center'/>
          <TextBox x:Name='GuidBox' Grid.Column='1' IsReadOnly='True' BorderThickness='0' Background='Transparent'/>
        </Grid>

        <Grid Margin='0,0,0,10'>
          <Grid.ColumnDefinitions><ColumnDefinition Width='200'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>
          <TextBlock Text='Units' Grid.Column='0' VerticalAlignment='Center'/>
          <TextBox x:Name='UnitsBox' Grid.Column='1' IsReadOnly='True' BorderThickness='0' Background='Transparent'/>
        </Grid>

        <!-- Official Description -->
        <Grid Margin='0,0,0,10'>
          <Grid.ColumnDefinitions><ColumnDefinition Width='200'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>
          <TextBlock Text='Description' Grid.Column='0' VerticalAlignment='Top'/>
          <TextBlock x:Name='DescBox' Grid.Column='1' TextWrapping='Wrap'/>
        </Grid>

        <Separator Margin='0,6,0,12'/>

        <StackPanel Orientation='Horizontal' Margin='0,0,0,8'>
          <TextBlock Text='Plugged in value' Width='200' VerticalAlignment='Center'/>
          <ComboBox x:Name='AcChoice' Width='320' Visibility='Collapsed'/>
          <TextBox  x:Name='AcNumeric' Width='140' Visibility='Collapsed'/>
          <TextBlock x:Name='AcHint' Margin='8,0,0,0' Foreground='#666666'/>
        </StackPanel>

        <StackPanel Orientation='Horizontal' Margin='0,0,0,18'>
          <TextBlock Text='On battery value' Width='200' VerticalAlignment='Center'/>
          <ComboBox x:Name='DcChoice' Width='320' Visibility='Collapsed'/>
          <TextBox  x:Name='DcNumeric' Width='140' Visibility='Collapsed'/>
          <TextBlock x:Name='DcHint' Margin='8,0,0,0' Foreground='#666666'/>
        </StackPanel>

        <StackPanel Orientation='Horizontal' Margin='0,0,0,0'>
          <Button x:Name='ApplyBtn' Content='Apply to plan' Width='140' Margin='0,0,10,0'/>
          <Button x:Name='RevealBtn' Content='Open in Advanced UI' Width='180'/>
        </StackPanel>

        <TextBlock x:Name='InfoText' Margin='0,12,0,0' TextWrapping='Wrap' Foreground='#666666'/>
      </StackPanel>
    </Border>

    <!-- Footer -->
    <DockPanel Grid.Row='2' Grid.ColumnSpan='3' Margin='10'>
      <TextBlock Text='Tip: values are raw indices. Many numeric settings are in Seconds or % (see Units).'
                 Foreground='#666666'/>
    </DockPanel>
  </Grid>
</Window>
"@

# Load XAML
$reader = (New-Object System.Xml.XmlNodeReader ([xml]$xaml))
$window = [Windows.Markup.XamlReader]::Load($reader)

# Controls
$PlanCombo = $window.FindName("PlanCombo")
$SetActiveBtn = $window.FindName("SetActiveBtn")
$RefreshBtn = $window.FindName("RefreshBtn")
$ExportBtn = $window.FindName("ExportBtn")
$ImportBtn = $window.FindName("ImportBtn")
$TuneBtn = $window.FindName("TuneBtn")
$CreatePlanBtn = $window.FindName("CreatePlanBtn")
$DeletePlanBtn = $window.FindName("DeletePlanBtn")

$Tree = $window.FindName("SettingsTree")
$SearchBox = $window.FindName("SearchBox")
$ClearSearchBtn = $window.FindName("ClearSearchBtn")

$ApplyBtn = $window.FindName("ApplyBtn")
$RevealBtn = $window.FindName("RevealBtn")

$SelectedPath = $window.FindName("SelectedPath")
$GuidBox = $window.FindName("GuidBox")
$UnitsBox = $window.FindName("UnitsBox")
$DescBox = $window.FindName("DescBox")
$AcChoice = $window.FindName("AcChoice")
$AcNumeric = $window.FindName("AcNumeric")
$AcHint = $window.FindName("AcHint")
$DcChoice = $window.FindName("DcChoice")
$DcNumeric = $window.FindName("DcNumeric")
$DcHint = $window.FindName("DcHint")
$InfoText = $window.FindName("InfoText")

# Globals
$global:Schemes = Get-Schemes
$global:Active = Get-ActiveSchemeGuid
$global:AllData = @()
$settingsFile = Join-Path $PSScriptRoot "app_settings.json"
$global:LastSelectedGuid = $null
if (Test-Path $settingsFile) {
  try {
    $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
    $global:LastSelectedGuid = $settings.LastSelectedGuid
  } catch { }
}

# Populate plan combo
function Refresh-Plans {
  $PlanCombo.Items.Clear()
  $global:Schemes = Get-Schemes
  foreach ($s in $global:Schemes) { [void]$PlanCombo.Items.Add("$($s.Name)   ($($s.Guid))") }
  $idx = if ($global:LastSelectedGuid) { ($global:Schemes | ForEach-Object Guid).IndexOf($global:LastSelectedGuid) } else { ($global:Schemes | ForEach-Object Guid).IndexOf($global:Active) }
  if ($idx -ge 0) { $PlanCombo.SelectedIndex = $idx } elseif ($PlanCombo.Items.Count -gt 0) { $PlanCombo.SelectedIndex = 0 }
}
Refresh-Plans

$PlanCombo.Add_SelectionChanged({
  if ($PlanCombo.SelectedIndex -lt 0) { return }
  $scheme = $global:Schemes[$PlanCombo.SelectedIndex]
  $global:LastSelectedGuid = $scheme.Guid
  $settings = @{LastSelectedGuid = $global:LastSelectedGuid}
  $settings | ConvertTo-Json | Set-Content $settingsFile
  Refresh-DataAndTree -schemeGuid $scheme.Guid
})

# Build a filtered tree from the current data + query
function Build-Tree([string]$query) {
  $Tree.Items.Clear()
  $q = if ($query) { $query.Trim() } else { "" }
  $qLower = $q.ToLowerInvariant()

  foreach ($sub in $global:AllData) {
    $matches = @()
    foreach ($set in $sub.Settings) {
      if ([string]::IsNullOrWhiteSpace($q)) {
        $matches += $set
      }
      else {
        $hay = @(
          $set.SetName,
          $set.Alias,
          $set.SetGuid,
          $sub.SubName,
          $sub.SubGuid
        ) | Where-Object { $_ -ne $null } | ForEach-Object { $_.ToString().ToLowerInvariant() }
        if ($hay -match [regex]::Escape($qLower)) { $matches += $set }
      }
    }
    if ($matches.Count -gt 0) {
      $subItem = New-Object System.Windows.Controls.TreeViewItem
      $subItem.Header = "$($sub.SubName)  ($($sub.SubGuid))"
      $subItem.Tag = $sub
      foreach ($m in $matches) {
        $setItem = New-Object System.Windows.Controls.TreeViewItem
        $aliasTxt = if ($m.Alias) { " [$($m.Alias)]" } else { "" }
        $setItem.Header = "$($m.SetName)$aliasTxt"
        $setItem.Tag = $m
        [void]$subItem.Items.Add($setItem)
      }
      [void]$Tree.Items.Add($subItem)
    }
  }
}

# Build tree data (AllData) and then render it
function Refresh-DataAndTree {
  param([string]$schemeGuid = $null)
  if (-not $schemeGuid) {
    $schemeGuid = if ($global:LastSelectedGuid) { $global:LastSelectedGuid } else { $null }
  }
  $InfoText.Text = "Enumerating power settings with 'powercfg /qh'..."
  try {
    $global:AllData = Get-AllPowerSettings -schemeGuid $schemeGuid
  }
  catch {
    $InfoText.Text = "Failed to read settings via /qh. Run PowerShell as Administrator. Details: $_"
    return
  }

  Build-Tree -query $SearchBox.Text

  $totalSettings = (($global:AllData | ForEach-Object { $_.Settings.Count }) | Measure-Object -Sum).Sum
  $schemeName = if ($schemeGuid) { ($global:Schemes | Where-Object Guid -eq $schemeGuid).Name } else { "active plan" }
  $InfoText.Text = "Loaded $($global:AllData.Count) subgroups, $totalSettings settings for $schemeName."
}
Refresh-DataAndTree

# Real-time search: filter the tree as you type
$SearchBox.Add_TextChanged({ Build-Tree -query $SearchBox.Text })
$ClearSearchBtn.Add_Click({ $SearchBox.Text = ""; Build-Tree -query "" })

# Editor view
function Show-ForSetting([object]$set) {
  if (-not $set) { return }

  # Resolve and cache official metadata (friendly name + description)
  if (-not ($set.PSObject.Properties.Name -contains 'Description') -or -not $set.Description) {
    $meta = Get-SettingMeta -SubGuid $set.SubGuid -SetGuid $set.SetGuid
    if ($meta) {
      $set | Add-Member -NotePropertyName Description -NotePropertyValue $meta.Description -Force
      if ($meta.FriendlyName) { $set.SetName = $meta.FriendlyName }
    }
    else {
      $set | Add-Member -NotePropertyName Description -NotePropertyValue $null -Force
    }
  }

  $SelectedPath.Text = "$($set.SubName)  ->  $($set.SetName)"
  $GuidBox.Text = $set.SetGuid
  $UnitsBox.Text = $set.Units
  $DescBox.Text = if ($set.Description) { $set.Description } else { "" }

  $isChoice = ($set.Choices.Count -gt 0)
  if ($isChoice) {
    $AcNumeric.Visibility = "Collapsed"; $DcNumeric.Visibility = "Collapsed"
    $AcChoice.Visibility = "Visible"; $DcChoice.Visibility = "Visible"
    $AcChoice.Items.Clear(); $DcChoice.Items.Clear()
    foreach ($c in $set.Choices) {
      $friendly = if ($c.Name) { "$($c.Index) - $($c.Name)" } else { "$($c.Index)" }
      [void]$AcChoice.Items.Add($friendly); [void]$DcChoice.Items.Add($friendly)
    }
    $acIdx = ($set.Choices | ForEach-Object Index).IndexOf([int]$set.AC); if ($acIdx -lt 0) { $acIdx = 0 }
    $dcIdx = ($set.Choices | ForEach-Object Index).IndexOf([int]$set.DC); if ($dcIdx -lt 0) { $dcIdx = 0 }
    $AcChoice.SelectedIndex = $acIdx; $DcChoice.SelectedIndex = $dcIdx
    $AcHint.Text = ""; $DcHint.Text = ""
  }
  else {
    $AcChoice.Visibility = "Collapsed"; $DcChoice.Visibility = "Collapsed"
    $AcNumeric.Visibility = "Visible"; $DcNumeric.Visibility = "Visible"
    $AcNumeric.Text = [string]$set.AC
    $DcNumeric.Text = [string]$set.DC
    $hint = @()
    if ($set.Units) { $hint += "Units: $($set.Units)" }
    if ($set.Min -ne $null -and $set.Max -ne $null) { $hint += "Range: $($set.Min)-$($set.Max)" }
    $AcHint.Text = ($hint -join "   ")
    $DcHint.Text = $AcHint.Text
  }
}

$Tree.Add_SelectedItemChanged({
    $sel = $Tree.SelectedItem
    if ($sel -and $sel.Tag -and $sel.Tag.PSObject.Properties.Name -contains 'SetGuid') { Show-ForSetting $sel.Tag }
  })

# Buttons / actions
$SetActiveBtn.Add_Click({
    if ($PlanCombo.SelectedIndex -lt 0) { return }
    $scheme = $global:Schemes[$PlanCombo.SelectedIndex]
    [void](Invoke-PowerCfg @("/setactive", $scheme.Guid))
    $global:Active = $scheme.Guid
    [System.Windows.MessageBox]::Show("Plan '$($scheme.Name)' is now active.", "Information", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
  })

$RefreshBtn.Add_Click({ Refresh-DataAndTree })

$ExportBtn.Add_Click({
    if ($PlanCombo.SelectedIndex -lt 0) { $InfoText.Text = "Select a plan to export."; return }
    $scheme = $global:Schemes[$PlanCombo.SelectedIndex]
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = Get-Location }
    $baseName = "power-backup-$($scheme.Name.Replace(' ', '_'))-$(Get-Date -Format 'yyyyMMdd-HHmm')"
    $powFile = Join-Path $scriptDir "$baseName.pow"
    $txtFile = Join-Path $scriptDir "$baseName.txt"
    
    # Export POW
    [void](Invoke-PowerCfg @("/export", ('"' + $powFile + '"'), $scheme.Guid))
    
    # Generate TXT with human-readable settings
    $txtContent = @"
Power Plan Export: $($scheme.Name)
GUID: $($scheme.Guid)
Exported on: $(Get-Date)

Settings:
"@
    foreach ($sub in $global:AllData) {
      $txtContent += "`n`nSubgroup: $($sub.SubName) ($($sub.SubGuid))"
      foreach ($set in $sub.Settings) {
        $txtContent += "`n  Setting: $($set.SetName) ($($set.SetGuid))"
        if ($set.Units) { $txtContent += "`n    Units: $($set.Units)" }
        if ($set.Min -ne $null -and $set.Max -ne $null) { $txtContent += "`n    Range: $($set.Min) - $($set.Max)" }
        $txtContent += "`n    Plugged in (AC) Value: $($set.AC)"
        $txtContent += "`n    On battery (DC) Value: $($set.DC)"
        if ($set.Description) { $txtContent += "`n    Description: $($set.Description)" }
        if ($set.Choices.Count -gt 0) {
          $txtContent += "`n    Choices:"
          foreach ($c in $set.Choices) {
            $txtContent += "`n      $($c.Index): $($c.Name)"
          }
        }
      }
    }
    $txtContent | Out-File -FilePath $txtFile -Encoding UTF8
    
    $InfoText.Text = "Exported '$($scheme.Name)' to $powFile and $txtFile"
  })

$ImportBtn.Add_Click({
    Add-Type -AssemblyName System.Windows.Forms
    $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $fileDialog.Filter = "Power Scheme Files (*.pow)|*.pow"
    $fileDialog.Title = "Select a Power Profile to Import"
    if ($fileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
      $import = Invoke-PowerCfg @("/import", ('"' + $fileDialog.FileName + '"'))
      if ($import.ExitCode -eq 0) {
        $InfoText.Text = "Imported power plan from $($fileDialog.FileName)."
        Refresh-Plans
      } else {
        $InfoText.Text = "Import failed: $($import.StdErr)"
      }
    }
  })

$RevealBtn.Add_Click({ Start-Process "control.exe" "powercfg.cpl" })

$ApplyBtn.Add_Click({
    $sel = $Tree.SelectedItem; if (-not $sel) { return }
    $set = $sel.Tag; if (-not $set -or -not $set.SetGuid) { return }
    if ($PlanCombo.SelectedIndex -lt 0) { return }
    $scheme = $global:Schemes[$PlanCombo.SelectedIndex].Guid

    try {
      if ($set.Choices.Count -gt 0) {
        $ac = $set.Choices[ [Math]::Max($AcChoice.SelectedIndex, 0) ].Index
        $dc = $set.Choices[ [Math]::Max($DcChoice.SelectedIndex, 0) ].Index
        Set-SettingValue -schemeGuid $scheme -subGuid $set.SubGuid -setGuid $set.SetGuid -acValue $ac -dcValue $dc
      }
      else {
        $ac = [int]$AcNumeric.Text; $dc = [int]$DcNumeric.Text
        Set-SettingValue -schemeGuid $scheme -subGuid $set.SubGuid -setGuid $set.SetGuid -acValue $ac -dcValue $dc
      }

      # Re-read current values for the selected plan and refresh UI
      $all = Get-AllPowerSettings -schemeGuid $scheme
      $match = ($all | ForEach-Object { $_.Settings } | Where-Object { $_.SetGuid -eq $set.SetGuid } | Select-Object -First 1)
      if ($match) { $set.AC = $match.AC; $set.DC = $match.DC }
      Show-ForSetting $set
      $InfoText.Text = "Applied to plan '$($global:Schemes[$PlanCombo.SelectedIndex].Name)'."
      if ($scheme -ne $global:Active) {
        $InfoText.Text += " Note: This plan is not active. Select it again to view the updated settings."
      }
    }
    catch {
      $InfoText.Text = "Failed to apply: $_"
    }
  })

$CreatePlanBtn.Add_Click({
    # Custom dialog XAML for creating a new plan
    $dialogXaml = @"
<Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
        xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Title='Create New Power Plan'
        Height='225' Width='450'
        WindowStartupLocation='CenterOwner'
        ResizeMode='NoResize'>
  <StackPanel Margin='20'>
    <TextBlock Text='Enter name for the new plan:' Margin='0,0,0,5'/>
    <TextBox x:Name='NameBox' Margin='0,0,0,15'/>
    <TextBlock Text='Select base template:' Margin='0,0,0,5'/>
    <ComboBox x:Name='BaseCombo' Margin='0,0,0,20'/>
    <StackPanel Orientation='Horizontal' HorizontalAlignment='Right'>
      <Button x:Name='OkBtn' Content='Create' Width='80' Margin='0,0,10,0'/>
      <Button x:Name='CancelBtn' Content='Cancel' Width='80'/>
    </StackPanel>
  </StackPanel>
</Window>
"@

    $dialogReader = New-Object System.Xml.XmlNodeReader ([xml]$dialogXaml)
    $dialog = [Windows.Markup.XamlReader]::Load($dialogReader)
    $dialog.Owner = $window

    $NameBox = $dialog.FindName("NameBox")
    $BaseCombo = $dialog.FindName("BaseCombo")
    $OkBtn = $dialog.FindName("OkBtn")
    $CancelBtn = $dialog.FindName("CancelBtn")

    # Populate base combo with current schemes
    $BaseCombo.Items.Clear()
    foreach ($s in $global:Schemes) { [void]$BaseCombo.Items.Add("$($s.Name) ($($s.Guid))") }
    $BaseCombo.SelectedIndex = 0

    $result = $null
    $OkBtn.Add_Click({
        $name = $NameBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
          [System.Windows.MessageBox]::Show("Please enter a name for the plan.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
          return
        }
        if ($name -match '[^a-zA-Z0-9\s\-_]') {
          [System.Windows.MessageBox]::Show("Plan name contains invalid characters. Use only letters, numbers, spaces, hyphens, and underscores.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
          return
        }
        if ($BaseCombo.SelectedIndex -lt 0) {
          [System.Windows.MessageBox]::Show("Please select a base template.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
          return
        }
        $script:result = @{
          Name = $name
          Base = $BaseCombo.SelectedItem.ToString()
        }
        $dialog.Close()
      })

    $CancelBtn.Add_Click({ $dialog.Close() })

    [void]$dialog.ShowDialog()

    if (-not $script:result) { $InfoText.Text = "Plan creation cancelled."; return }

    # Parse the GUID from the selected base
    if ($script:result.Base -match '\(([a-fA-F0-9-]+)\)$') {
      $baseGuid = $matches[1]
    }
    else {
      $InfoText.Text = "Invalid base template selected."; return
    }

    try {
      $newGuid = New-Plan -BaseAlias $baseGuid -Name $script:result.Name
      [System.Windows.MessageBox]::Show("Plan '$($script:result.Name)' created successfully with GUID $newGuid.", "Success", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)  # Add success pop-up
      $InfoText.Text = "Created new plan '$($script:result.Name)' ($newGuid)."
      Refresh-Plans
      # Ensure the new plan is selected in the dropdown
      $idx = ($global:Schemes | ForEach-Object Guid).IndexOf($newGuid)
      if ($idx -ge 0) { $PlanCombo.SelectedIndex = $idx }
    }
    catch {
      $InfoText.Text = "Failed to create plan: $_ | Base: $baseGuid"
    }
  })

$DeletePlanBtn.Add_Click({
    if ($PlanCombo.SelectedIndex -lt 0) { $InfoText.Text = "Select a plan to delete."; return }
    $scheme = $global:Schemes[$PlanCombo.SelectedIndex]
    if ($scheme.Guid -eq $global:Active) { [System.Windows.MessageBox]::Show("Cannot delete the active plan.", "Warning", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning); return }

    $confirm = [System.Windows.MessageBox]::Show("Are you sure you want to delete the plan '$($scheme.Name)' ($($scheme.Guid))?", "Confirm Delete", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

    try {
      [void](Invoke-PowerCfg @("/delete", $scheme.Guid))
      $InfoText.Text = "Deleted plan '$($scheme.Name)'."
      Refresh-Plans
    }
    catch {
      $InfoText.Text = "Failed to delete plan: $_"
    }
  })

$TuneBtn.Add_Click({
    if ($PlanCombo.SelectedIndex -lt 0) { $InfoText.Text = "Select a plan to tune."; return }
    $scheme = $global:Schemes[$PlanCombo.SelectedIndex]
    $schemeGuid = $scheme.Guid

    try {
      $InfoText.Text = "Applying max performance tuning to '$($scheme.Name)'... This may take a minute."

      # Tuned AC values (from the previous analysis) - AC only, DC preserved
      $tunedSettings = @(
        # Subgroup GUID, Setting GUID, Tuned AC Value
        @("fea3413e-7e05-4911-9a71-700331f1c294", "245d8541-3943-4422-b025-13a784f679b7", 0),  # Power plan type
        @("0012ee47-9041-4b5d-9b77-535fba8b1442", "6738e2c4-e8a5-4a42-b16a-e040e769756e", -1),  # Turn off hard disk after
        @("0012ee47-9041-4b5d-9b77-535fba8b1442", "80e3c60e-bb94-4ad8-bbe0-0d3195efc663", 0),   # Hard disk burst ignore time
        @("0d7dbae2-4294-402a-ba8e-26777e8488cd", "309dce9b-bef4-4119-9921-a851fb12f0f4", 0),   # Slide show
        @("19cbb8fa-5279-450e-9fac-8a3d5fedd0c1", "12bbebe6-58d6-4636-95bb-3217ef867c1a", 0),   # Power Saving Mode
        @("238c9fa8-0aad-41ed-83f4-97be242c8f20", "29f6c1db-86da-48c5-9fdb-f2b67b1f44da", -1),  # Sleep after
        @("238c9fa8-0aad-41ed-83f4-97be242c8f20", "9d7815a6-7ee4-497e-8888-515a05f02364", 0),   # Hibernate after
        @("238c9fa8-0aad-41ed-83f4-97be242c8f20", "a4b195f5-8225-47d8-8012-9d41369786e2", 1),   # Allow wake timers
        @("238c9fa8-0aad-41ed-83f4-97be242c8f20", "d4c1d4c8-d5cc-43d3-b83e-fc51215cb04d", 0),   # Allow sleep with remote opens
        @("2a737441-1930-4402-8d77-b2bebba308a3", "48e6b7a6-50f5-4782-a5d4-53bb8f07e226", 0),   # USB selective suspend
        @("2a737441-1930-4402-8d77-b2bebba308a3", "498c044a-201b-4631-a522-5c744ed4e678", 0),   # Setting IOC on all TDs
        @("2e601130-5351-4d9d-8e04-252966bad054", "3166bc41-7e98-4e03-b34e-ec0f5f2b218e", 0),   # Execution Required timeout
        @("3bcc29b5-1984-4490-8b43-9b3e8f3e9e9e", "d502f7ee-1dc7-4efd-a55d-f04b6f5c0545", 10000), # Target Load
        @("3fa863aa-894a-46ae-a581-0c36d0e7d4e8", "3619c3f2-afb2-4afc-b0e9-e7fef372de36", 0),   # Config TDP Level
        @("4f971e89-eebd-4455-a8de-9e59040e7347", "5ca83367-6e45-459f-a27b-476b1d01c936", 0),   # Lid close action
        @("4f971e89-eebd-4455-a8de-9e59040e7347", "7648efa3-dd9c-4e3e-b566-50f929386280", 0),   # Power button action
        @("4f971e89-eebd-4455-a8de-9e59040e7347", "96996bc0-ad50-47ec-923b-6f41874dd9eb", 0),   # Sleep button action
        @("4f971e89-eebd-4455-a8de-9e59040e7347", "a7066653-8d6c-40a8-910e-a1f54b84c7e5", 0),   # Start menu power button
        @("501a4d13-42af-4429-9fd1-a8218c268e20", "ee12f906-d277-404b-b6da-e5fa1a576df5", 0),   # Link State Power Management
        @("54533251-82be-4824-96c1-47b60b740d00", "0cc5b647-c1df-4637-891a-dec35c318583", 75),  # Minimum processor state
        @("54533251-82be-4824-96c1-47b60b740d00", "0cc5b647-c1df-4637-891a-dec35c318584", 100), # Maximum processor state
        @("54533251-82be-4824-96c1-47b60b740d00", "06cadf0e-64ed-448a-8927-ce7bf90eb35d", 2),   # Processor performance boost mode
        @("54533251-82be-4824-96c1-47b60b740d00", "06cadf0e-64ed-448a-8927-ce7bf90eb35e", 100), # Processor performance increase threshold
        @("54533251-82be-4824-96c1-47b60b740d00", "12a0ab44-fe28-4fa9-b3bd-4b64f44960a6", 0),   # Processor performance decrease threshold
        @("54533251-82be-4824-96c1-47b60b740d00", "12a0ab44-fe28-4fa9-b3bd-4b64f44960a7", 1),   # Processor performance autonomous mode
        @("54533251-82be-4824-96c1-47b60b740d00", "12fd031f-53d2-4bf4-ac6d-c699fc9538c7", 1),   # System cooling policy
        @("54533251-82be-4824-96c1-47b60b740d00", "1a98ad09-af22-42ca-8e61-f0a5802c270a", 0),   # Allow Throttle States
        @("54533251-82be-4824-96c1-47b60b740d00", "1facfc65-a930-4bc5-9f38-504ec097bbc0", 1),   # Processor idle disable
        @("5fb4938d-1ee8-4b0f-9a3c-5036b0ab995c", "2430ab6f-a520-44a2-9601-f7f23b5134b1", 0),   # GPU preference policy
        @("7516b95f-f776-4464-8c53-06167f40cc99", "3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e", -1),  # Dim display after
        @("7516b95f-f776-4464-8c53-06167f40cc99", "17aaa29b-8b43-4b94-aafe-35f64daaf1ee", -1),  # Turn off display after
        @("7516b95f-f776-4464-8c53-06167f40cc99", "aded5e82-b909-4619-9949-f5d71dac0bcb", 100), # Display brightness
        @("7516b95f-f776-4464-8c53-06167f40cc99", "f1fbfde2-a960-4165-9f88-50667911ce96", 100), # Dimmed display brightness
        @("7516b95f-f776-4464-8c53-06167f40cc99", "fbd9aa66-9553-4097-ba44-ed6e9d65eab8", 0),   # Enable adaptive brightness
        @("8619b916-e004-4dd8-9b66-8054335b6a1b", "0a7d6ab6-ac83-4ad1-8282-eca5b58308f3", 0),   # User Presence Prediction mode
        @("9596fb26-9850-41fd-ac3e-f7c3c00afd4b", "468fe7e5-1158-46ec-88bc-5b96c9e44fd0", 1),   # When sharing media
        @("9596fb26-9850-41fd-ac3e-f7c3c00afd4b", "49cb11a5-56e2-4afb-9d38-3df47872e21b", 1),   # Video playback quality bias
        @("9596fb26-9850-41fd-ac3e-f7c3c00afd4b", "5adbbfbc-074e-4da1-ba38-db8b36b2c8f3", 0),   # When playing video
        @("de830923-a562-41af-a086-e3a2c6bad2da", "13d09884-f74e-474a-a852-b6bde8ad03a8", 0)    # Energy Saver Policy
      )

      foreach ($setting in $tunedSettings) {
        $subGuid, $setGuid, $acValue = $setting
        # Find current DC value to preserve it
        $currentSet = ($global:AllData | Where-Object { $_.SubGuid -eq $subGuid } | ForEach-Object { $_.Settings } | Where-Object { $_.SetGuid -eq $setGuid } | Select-Object -First 1)
        $dcValue = if ($currentSet) { $currentSet.DC } else { 0 }
        Set-SettingValue -schemeGuid $schemeGuid -subGuid $subGuid -setGuid $setGuid -acValue $acValue -dcValue $dcValue
      }

      # Refresh data
      Refresh-Plans
      $InfoText.Text = "Tuning applied to '$($scheme.Name)'. Refreshing data..."
      Start-Sleep -Seconds 2
      $global:AllData = Get-AllPowerSettings -schemeGuid $schemeGuid
      Build-Tree -query $SearchBox.Text
      $InfoText.Text = "Max performance tuning completed for '$($scheme.Name)'."
    }
    catch {
      $InfoText.Text = "Tuning failed: $_"
    }
  })
# Show UI
$window.ShowDialog() | Out-Null
