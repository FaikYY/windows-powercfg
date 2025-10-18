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
    [void](Invoke-PowerCfg @("/changename", $newGuid, $quotedName))
    if ($Activate) { [void](Invoke-PowerCfg @("/setactive", $newGuid)) }
    return $newGuid
  }
  else {
    $dup | Out-Host
    throw "Could not parse new GUID from /duplicatescheme output."
  }
}

# Unhide a setting (safe if already visible)
function Unhide-Setting {
  param([string]$subGuid, [string]$setGuid)
  [void](Invoke-PowerCfg @("/attributes", $subGuid, $setGuid, "-ATTRIB_HIDE"))
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
  $unhide = Invoke-PowerCfg @("/attributes", $subGuid, $setGuid, "-ATTRIB_HIDE")
  if ($unhide.ExitCode -ne 0) { throw "Failed to unhide setting: $($unhide.StdErr)" }
  
  $acSet = Invoke-PowerCfg @("/setacvalueindex", $schemeGuid, $subGuid, $setGuid, $acValue)
  if ($acSet.ExitCode -ne 0) { throw "Failed to set AC value: $($acSet.StdErr)" }
  
  $dcSet = Invoke-PowerCfg @("/setdcvalueindex", $schemeGuid, $subGuid, $setGuid, $dcValue)
  if ($dcSet.ExitCode -ne 0) { throw "Failed to set DC value: $($dcSet.StdErr)" }
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
          <Button x:Name='UnhideBtn' Content='Unhide setting' Width='140' Margin='0,0,10,0'/>
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
$ImportBtn = $window.FindName("ImportBtn")  # Add this
$CreatePlanBtn = $window.FindName("CreatePlanBtn")
$DeletePlanBtn = $window.FindName("DeletePlanBtn")

$Tree = $window.FindName("SettingsTree")
$SearchBox = $window.FindName("SearchBox")
$ClearSearchBtn = $window.FindName("ClearSearchBtn")

$ApplyBtn = $window.FindName("ApplyBtn")
$UnhideBtn = $window.FindName("UnhideBtn")
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

# Populate plan combo
function Refresh-Plans {
  $PlanCombo.Items.Clear()
  $global:Schemes = Get-Schemes
  foreach ($s in $global:Schemes) { [void]$PlanCombo.Items.Add("$($s.Name)   ($($s.Guid))") }
  $idx = ($global:Schemes | ForEach-Object Guid).IndexOf($global:Active)
  if ($idx -ge 0) { $PlanCombo.SelectedIndex = $idx } elseif ($PlanCombo.Items.Count -gt 0) { $PlanCombo.SelectedIndex = 0 }
}
Refresh-Plans

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
    $file = Join-Path $scriptDir "power-backup-$($scheme.Name.Replace(' ', '_'))-$(Get-Date -Format 'yyyyMMdd-HHmm').pow"
    [void](Invoke-PowerCfg @("/export", ('"' + $file + '"'), $scheme.Guid))
    $InfoText.Text = "Exported '$($scheme.Name)' to $file"
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

$UnhideBtn.Add_Click({
    $sel = $Tree.SelectedItem; if (-not $sel) { return }
    $set = $sel.Tag; if (-not $set -or -not $set.SetGuid) { return }
    Unhide-Setting -subGuid $set.SubGuid -setGuid $set.SetGuid
    $InfoText.Text = "Unhid $($set.SetName)."
  })

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

# Show UI
$window.ShowDialog() | Out-Null
