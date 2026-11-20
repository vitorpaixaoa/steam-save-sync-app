param([switch]$SelfTest, [string]$ShotDir)

# Steam Save Sync
# Copia o save de um jogo de uma conta Steam para outra(s) no mesmo PC.
# Jogos com perfil conhecido tem o save reassinado para a conta destino;
# os demais usam copia simples da pasta userdata\<conta>\<appid>\remote.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:SteamBase  = [uint64]76561197960265728
$script:DataDir    = Join-Path $env:LOCALAPPDATA 'SaveSync'
$script:BackupRoot = Join-Path $script:DataDir 'backups'
$script:ConfigPath = Join-Path $script:DataDir 'config.json'
$script:Latin1     = [Text.Encoding]::GetEncoding(28591)

# ---------------------------------------------------------------- Perfis de jogo
# Para dar suporte completo a um novo jogo, adicione o AppID aqui.
#   Method  'xor-steamid64': index.save/data.save cifrados com XOR do SteamID64 (motor Glacier, IO Interactive)
#           'copy'         : copia simples (padrao para jogos sem perfil)
#   Options : pastas opcionais dentro de "remote" que o usuario pode deixar de fora

$script:Profiles = @{
    '3768760' = @{   # 007 First Light
        Method  = 'xor-steamid64'
        Options = @(
            @{ Label = 'Copiar estatísticas e conquistas'; Container = 'LocalProfile' }
            @{ Label = 'Copiar configurações de vídeo, áudio e HUD'; Container = 'SystemData' }
        )
    }
}

function Get-GameProfile([string]$appId) {
    if ($script:Profiles.ContainsKey($appId)) { return $script:Profiles[$appId] }
    return @{ Method = 'copy'; Options = @() }
}

# ---------------------------------------------------------------- Steam

function Get-SteamPath {
    $candidates = @()
    try { $candidates += (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch {}
    try { $candidates += (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction Stop).InstallPath } catch {}
    $candidates += 'C:\Program Files (x86)\Steam'
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'userdata'))) { return (Resolve-Path $c).Path }
    }
    throw 'Instalação do Steam não encontrada.'
}

function Get-PersonaNames([string]$steam) {
    $names = @{}
    $file = Join-Path $steam 'config\loginusers.vdf'
    if (-not (Test-Path $file)) { return $names }
    $text = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    foreach ($m in [regex]::Matches($text, '"(7656\d{13})"\s*\{([^}]*)\}')) {
        $accountId = [string]([uint64]$m.Groups[1].Value - $script:SteamBase)
        $p = [regex]::Match($m.Groups[2].Value, '"PersonaName"\s+"([^"]*)"')
        $a = [regex]::Match($m.Groups[2].Value, '"AccountName"\s+"([^"]*)"')
        if ($p.Success) { $names[$accountId] = $p.Groups[1].Value }
        elseif ($a.Success) { $names[$accountId] = $a.Groups[1].Value }
    }
    return $names
}

# AppID -> nome, a partir das bibliotecas Steam instaladas neste PC.
function Get-InstalledGames([string]$steam) {
    $libs = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches([IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"')) {
            $libs += $m.Groups[1].Value.Replace('\\', '\')
        }
    }
    $games = @{}
    foreach ($lib in ($libs | Select-Object -Unique)) {
        # Bibliotecas em unidades desconectadas sao ignoradas
        $apps = [IO.Path]::Combine($lib, 'steamapps')
        if (-not [IO.Directory]::Exists($apps)) { continue }
        foreach ($acf in Get-ChildItem $apps -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue) {
            try {
                $t = [IO.File]::ReadAllText($acf.FullName, [Text.Encoding]::UTF8)
                $id = [regex]::Match($t, '"appid"\s+"(\d+)"').Groups[1].Value
                $name = [regex]::Match($t, '"name"\s+"([^"]*)"').Groups[1].Value
                if ($id -and $name) { $games[$id] = $name }
            } catch {}
        }
    }
    return $games
}

function Get-GameImage([string]$steam, [string]$appId) {
    $cache = Join-Path $steam 'appcache\librarycache'
    $path = $null
    foreach ($c in @((Join-Path $cache "$appId`_header.jpg"), (Join-Path $cache "$appId\header.jpg"))) {
        if (Test-Path $c) { $path = $c; break }
    }
    if (-not $path -and (Test-Path (Join-Path $cache $appId))) {
        # Versoes novas do Steam guardam as capas em subpastas com hash
        $f = Get-ChildItem (Join-Path $cache $appId) -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in 'header.jpg', 'library_header.jpg' } | Select-Object -First 1
        if ($f) { $path = $f.FullName }
    }
    if (-not $path) { return $null }
    try {
        # Algumas capas trazem DPI invalido (ex.: 2,54) e o WPF as desenha fora de escala; normaliza para 96
        $frame = [Windows.Media.Imaging.BitmapDecoder]::Create([Uri]$path, 'None', 'OnLoad').Frames[0]
        $conv = New-Object Windows.Media.Imaging.FormatConvertedBitmap($frame, [Windows.Media.PixelFormats]::Bgra32, $null, 0)
        $stride = $conv.PixelWidth * 4
        $pixels = New-Object byte[] ($stride * $conv.PixelHeight)
        $conv.CopyPixels($pixels, $stride, 0)
        $img = [Windows.Media.Imaging.BitmapSource]::Create($conv.PixelWidth, $conv.PixelHeight, 96, 96,
            [Windows.Media.PixelFormats]::Bgra32, $null, $pixels, $stride)
        $img.Freeze()
        return $img
    } catch { return $null }
}

function Get-UserDirs([string]$steam) {
    return @(Get-ChildItem (Join-Path $steam 'userdata') -Directory | Where-Object { $_.Name -match '^\d+$' -and $_.Name -ne '0' })
}

# Jogos instalados que tem save em userdata para pelo menos uma conta.
function Get-Games([string]$steam) {
    $installed = Get-InstalledGames $steam
    $count = @{}
    foreach ($user in Get-UserDirs $steam) {
        foreach ($app in Get-ChildItem $user.FullName -Directory -ErrorAction SilentlyContinue) {
            if (-not $installed.ContainsKey($app.Name)) { continue }
            $remote = Join-Path $app.FullName 'remote'
            if (-not (Test-Path $remote)) { continue }
            if (Get-ChildItem $remote -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1) {
                $count[$app.Name] = 1 + [int]$count[$app.Name]
            }
        }
    }
    $list = @()
    foreach ($id in $count.Keys) {
        $prof = Get-GameProfile $id
        $supported = $prof.Method -ne 'copy'
        $img = Get-GameImage $steam $id
        $n = $count[$id]
        $list += [pscustomobject]@{
            AppId = $id; Name = $installed[$id]; Method = $prof.Method; Options = $prof.Options
            Supported = $supported
            MethodText = if ($supported) { 'Suporte completo' } else { 'Cópia simples' }
            AccountsText = if ($n -eq 1) { '1 conta' } else { "$n contas" }
            Image = $img; HasImage = [bool]$img
        }
    }
    return @($list | Sort-Object @{ Expression = 'Supported'; Descending = $true }, Name)
}

function Get-Accounts([string]$steam, [string]$appId) {
    $names = Get-PersonaNames $steam
    $list = @()
    foreach ($dir in Get-UserDirs $steam) {
        $appDir = Join-Path $dir.FullName $appId
        $remote = Join-Path $appDir 'remote'
        if (-not (Test-Path $remote)) { continue }
        $files = @(Get-ChildItem $remote -Recurse -File -ErrorAction SilentlyContinue)
        if (-not $files.Count) { continue }
        $last = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
        $size = ($files | Measure-Object Length -Sum).Sum
        $name = $names[$dir.Name]
        if (-not $name) { $name = 'Conta sem nome' }
        $list += [pscustomobject]@{
            Id = $dir.Name; Name = $name; AppDir = $appDir; Remote = $remote
            LastSave = $last; Size = $size
            IdText   = "ID $($dir.Name)"
            LastText = $last.ToString('dd/MM/yyyy HH:mm')
            SizeText = if ($size -ge 1MB) { '{0:N1} MB' -f ($size / 1MB) } else { '{0:N1} KB' -f ($size / 1KB) }
        }
    }
    return $list
}

function Test-SteamRunning {
    return [bool](Get-Process steam -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------- Metodo xor-steamid64

function Get-KeyBytes([string]$accountId) {
    return , [BitConverter]::GetBytes([uint64]($script:SteamBase + [uint64]$accountId))
}

function Invoke-Xor([byte[]]$data, [byte[]]$key) {
    $out = New-Object byte[] $data.Length
    for ($i = 0; $i -lt $data.Length; $i++) { $out[$i] = $data[$i] -bxor $key[$i % 8] }
    return , $out
}

# Descobre a chave real pelo texto conhecido "meHeader" no offset 16 do index.save.
function Get-IndexKey([byte[]]$index) {
    if ($index.Length -lt 24) { return $null }
    $pattern = $script:Latin1.GetBytes('meHeader')
    $key = New-Object byte[] 8
    for ($i = 0; $i -lt 8; $i++) { $key[$i] = $index[16 + $i] -bxor $pattern[$i] }
    $plain = Invoke-Xor $index $key
    if ($script:Latin1.GetString($plain).Contains('SSaveGameHeader')) { return , $key }
    return $null
}

function Test-ZlibPayload([byte[]]$plain) {
    if ($plain.Length -lt 3 -or $plain[0] -ne 0x78) { return $false }
    try {
        $ms = New-Object IO.MemoryStream(, $plain)
        $null = $ms.ReadByte(); $null = $ms.ReadByte()
        $ds = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionMode]::Decompress)
        $sink = New-Object IO.MemoryStream
        $ds.CopyTo($sink)
        return ($sink.Length -gt 0)
    } catch { return $false }
}

# Converte tudo em memoria e valida antes de qualquer escrita em disco.
function Convert-XorContainers($src, $dst, [string[]]$skip) {
    $dstKey = Get-KeyBytes $dst.Id
    $folderKey = Get-KeyBytes $src.Id
    $items = @()
    foreach ($container in Get-ChildItem $src.Remote -Directory) {
        if ($skip -contains $container.Name) { continue }
        $indexPath = Join-Path $container.FullName 'index.save'
        $dataPath  = Join-Path $container.FullName 'data.save'
        $key = $null
        if (Test-Path $indexPath) { $key = Get-IndexKey ([IO.File]::ReadAllBytes($indexPath)) }
        if (-not $key) { $key = $folderKey }

        foreach ($path in @($indexPath, $dataPath)) {
            if (-not (Test-Path $path)) { continue }
            $plain = Invoke-Xor ([IO.File]::ReadAllBytes($path)) $key
            $leaf = Split-Path $path -Leaf
            if ($leaf -eq 'data.save' -and -not (Test-ZlibPayload $plain)) {
                throw "Não foi possível decifrar $($container.Name)\data.save com a chave da conta origem. Nada foi alterado."
            }
            if ($leaf -eq 'index.save' -and -not $script:Latin1.GetString($plain).Contains('SSaveGameHeader')) {
                throw "Cabeçalho inválido em $($container.Name)\index.save. Nada foi alterado."
            }
            $items += [pscustomobject]@{
                Rel = Join-Path $container.Name $leaf; Bytes = (Invoke-Xor $plain $dstKey); Source = $null
            }
        }
    }
    return $items
}

# ---------------------------------------------------------------- Sincronizacao

function Get-SyncItems($game, $src, $dst, [string[]]$skip) {
    if ($game.Method -eq 'xor-steamid64') {
        $items = @(Convert-XorContainers $src $dst $skip)
    } else {
        $items = @(Get-ChildItem $src.Remote -Recurse -File | ForEach-Object {
            [pscustomobject]@{ Rel = $_.FullName.Substring($src.Remote.Length + 1); Bytes = $null; Source = $_.FullName }
        })
    }
    if (-not $items.Count) { throw 'Nenhum arquivo de save encontrado na conta origem.' }
    return $items
}

function Get-Sha1([byte[]]$bytes) {
    $sha = [Security.Cryptography.SHA1]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($bytes)) } finally { $sha.Dispose() }
}

function Sync-Save($game, $src, $dst, [string[]]$skip, [scriptblock]$log) {
    if ($src.Id -eq $dst.Id) { throw 'Origem e destino são a mesma conta.' }
    if (Test-SteamRunning) { throw 'O Steam está aberto. Feche o Steam antes de sincronizar.' }

    & $log "$($game.Name): $($src.Name) -> $($dst.Name)"
    $items = Get-SyncItems $game $src $dst $skip
    & $log "$($items.Count) arquivos preparados."

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $script:BackupRoot "$($game.AppId)\$stamp`_destino-$($dst.Id)"
    New-Item -ItemType Directory -Force (Split-Path $backup) | Out-Null
    Copy-Item $dst.AppDir $backup -Recurse
    & $log "Backup do destino: $backup"

    foreach ($item in $items) {
        $target = Join-Path $dst.Remote $item.Rel
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        if ($item.Source) { Copy-Item -LiteralPath $item.Source -Destination $target -Force }
        else { [IO.File]::WriteAllBytes($target, $item.Bytes) }
    }
    foreach ($item in $items) {
        $target = Join-Path $dst.Remote $item.Rel
        $ok = if ($item.Source) { (Get-FileHash -LiteralPath $target -Algorithm SHA1).Hash -eq (Get-FileHash -LiteralPath $item.Source -Algorithm SHA1).Hash }
              else { (Get-Sha1 ([IO.File]::ReadAllBytes($target))) -eq (Get-Sha1 $item.Bytes) }
        if (-not $ok) { throw "Falha na conferência de $($item.Rel). Restaure o backup: $backup" }
    }
    & $log "Concluído e conferido: $($dst.Name)."
}

# ---------------------------------------------------------------- Config

function Read-Config {
    $h = @{}
    try {
        if (Test-Path $script:ConfigPath) {
            (Get-Content $script:ConfigPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
        }
    } catch {}
    return $h
}

function Save-Config([string]$key, $value) {
    try {
        $h = Read-Config; $h[$key] = $value
        New-Item -ItemType Directory -Force $script:DataDir | Out-Null
        $h | ConvertTo-Json -Depth 4 | Out-File $script:ConfigPath -Encoding utf8
    } catch {}
}

# ---------------------------------------------------------------- Interface (WPF)

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Steam Save Sync" Width="1080" Height="740"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize"
        Background="#14161A" Foreground="#E8E6E1" FontFamily="Segoe UI" FontSize="13"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#E8E6E1"/>
      <Setter Property="Background" Value="#1E2127"/>
      <Setter Property="BorderBrush" Value="#343944"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.82"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.65"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#D4AF37"/>
      <Setter Property="BorderBrush" Value="#D4AF37"/>
      <Setter Property="Foreground" Value="#14161A"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Padding" Value="30,12"/>
    </Style>
    <Style x:Key="Toggle" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#C9CCD3"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Track" Width="38" Height="20" CornerRadius="10" Background="#343944" VerticalAlignment="Center">
                <Ellipse x:Name="Thumb" Width="14" Height="14" Fill="#8B909A" HorizontalAlignment="Left" Margin="3,0"/>
              </Border>
              <ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#D4AF37"/>
                <Setter TargetName="Thumb" Property="Fill" Value="#14161A"/>
                <Setter TargetName="Thumb" Property="HorizontalAlignment" Value="Right"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="CardItem" TargetType="ListBoxItem">
      <Setter Property="Margin" Value="0,0,0,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Padding" Value="16,12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Bd" Background="#1E2127" BorderBrush="#2B2F37" BorderThickness="1.5" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#4A4F5A"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#D4AF37"/>
                <Setter TargetName="Bd" Property="Background" Value="#27241A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="GameItem" TargetType="ListBoxItem" BasedOn="{StaticResource CardItem}">
      <Setter Property="Padding" Value="10"/>
    </Style>
    <Style x:Key="CardList" TargetType="ListBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="ItemContainerStyle" Value="{StaticResource CardItem}"/>
      <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
    </Style>
    <DataTemplate x:Key="AccountTemplate">
      <StackPanel>
        <TextBlock Text="{Binding Name}" FontSize="16" FontWeight="SemiBold" Foreground="#F2F0EB" TextTrimming="CharacterEllipsis"/>
        <TextBlock Text="{Binding IdText}" Foreground="#8B909A" FontSize="11.5" Margin="0,1,0,8"/>
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <StackPanel>
            <TextBlock Text="ÚLTIMO SAVE" Foreground="#8B909A" FontSize="10"/>
            <TextBlock Text="{Binding LastText}" Foreground="#D6D8DD"/>
          </StackPanel>
          <StackPanel Grid.Column="1">
            <TextBlock Text="TAMANHO" Foreground="#8B909A" FontSize="10" HorizontalAlignment="Right"/>
            <TextBlock Text="{Binding SizeText}" Foreground="#D6D8DD" HorizontalAlignment="Right"/>
          </StackPanel>
        </Grid>
      </StackPanel>
    </DataTemplate>
    <DataTemplate x:Key="GameTemplate">
      <StackPanel>
        <Image x:Name="Img" Source="{Binding Image}" Stretch="UniformToFill" Height="96" Margin="0,0,0,8"
               HorizontalAlignment="Stretch" RenderOptions.BitmapScalingMode="HighQuality">
          <Image.Clip><RectangleGeometry Rect="0,0,211,96" RadiusX="6" RadiusY="6"/></Image.Clip>
        </Image>
        <TextBlock Text="{Binding Name}" FontWeight="SemiBold" Foreground="#F2F0EB" TextTrimming="CharacterEllipsis"/>
        <DockPanel Margin="0,2,0,0">
          <TextBlock DockPanel.Dock="Right" Text="{Binding AccountsText}" Foreground="#8B909A" FontSize="11.5"/>
          <TextBlock x:Name="Badge" Text="{Binding MethodText}" Foreground="#8B909A" FontSize="11.5"/>
        </DockPanel>
      </StackPanel>
      <DataTemplate.Triggers>
        <DataTrigger Binding="{Binding HasImage}" Value="False"><Setter TargetName="Img" Property="Visibility" Value="Collapsed"/></DataTrigger>
        <DataTrigger Binding="{Binding Supported}" Value="True"><Setter TargetName="Badge" Property="Foreground" Value="#D4AF37"/></DataTrigger>
      </DataTemplate.Triggers>
    </DataTemplate>
  </Window.Resources>

  <Grid Background="#14161A">
    <Grid.ColumnDefinitions><ColumnDefinition Width="270"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

    <!-- Barra lateral: jogos -->
    <Border Grid.Column="0" Background="#0F1114" BorderBrush="#22252B" BorderThickness="0,0,1,0">
      <DockPanel Margin="18,22,18,16">
        <StackPanel DockPanel.Dock="Top" Margin="2,0,0,16">
          <TextBlock Text="STEAM SAVE SYNC" Foreground="#D4AF37" FontSize="11" FontWeight="Bold"/>
          <TextBlock Text="Jogos" FontSize="22" FontWeight="SemiBold" Foreground="#F2F0EB" Margin="0,2,0,0"/>
          <TextBlock Text="Instalados e com save neste PC" Foreground="#8B909A" FontSize="12"/>
        </StackPanel>
        <ListBox x:Name="LstGames" Style="{StaticResource CardList}" ItemContainerStyle="{StaticResource GameItem}"
                 ItemTemplate="{StaticResource GameTemplate}"/>
      </DockPanel>
    </Border>

    <!-- Painel principal -->
    <Grid Grid.Column="1" Margin="28,22,28,24">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="118"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0" Margin="0,0,0,20">
        <StackPanel Margin="0,0,110,0">
          <TextBlock x:Name="TxtGame" Text="Nenhum jogo encontrado" FontSize="26" FontWeight="SemiBold" Foreground="#F2F0EB" TextTrimming="CharacterEllipsis"/>
          <TextBlock x:Name="TxtMethod" Foreground="#8B909A" TextWrapping="Wrap" Margin="0,2,0,0"/>
        </StackPanel>
        <Button x:Name="BtnRefresh" Style="{StaticResource Btn}" Content="Atualizar" HorizontalAlignment="Right" VerticalAlignment="Top"/>
      </Grid>

      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/><ColumnDefinition Width="76"/><ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <DockPanel Grid.Column="0">
          <StackPanel DockPanel.Dock="Top" Margin="2,0,0,10">
            <TextBlock Text="ORIGEM" Foreground="#D4AF37" FontWeight="Bold" FontSize="12"/>
            <TextBlock Text="De onde o save é copiado" Foreground="#8B909A" FontSize="12"/>
          </StackPanel>
          <ListBox x:Name="LstSrc" Style="{StaticResource CardList}" ItemTemplate="{StaticResource AccountTemplate}"/>
        </DockPanel>
        <Button x:Name="BtnSwap" Grid.Column="1" Style="{StaticResource Btn}" Width="44" Height="44" Padding="0"
                VerticalAlignment="Top" Margin="0,74,0,0" ToolTip="Inverter origem e destino">
          <TextBlock Text="&#xE8AB;" FontFamily="Segoe MDL2 Assets" FontSize="18" Foreground="#D4AF37"/>
        </Button>
        <DockPanel Grid.Column="2">
          <StackPanel DockPanel.Dock="Top" Margin="2,0,0,10">
            <TextBlock Text="DESTINOS" Foreground="#D4AF37" FontWeight="Bold" FontSize="12"/>
            <TextBlock Text="Marque uma ou mais contas (backup antes de sobrescrever)" Foreground="#8B909A" FontSize="12" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
          <Grid>
            <ListBox x:Name="LstDst" Style="{StaticResource CardList}" ItemTemplate="{StaticResource AccountTemplate}" SelectionMode="Multiple"/>
            <TextBlock x:Name="EmptyHint" Visibility="Collapsed" Foreground="#8B909A" TextWrapping="Wrap" Margin="2,6,0,0"
                       Text="Nenhuma outra conta deste PC tem save deste jogo. Abra o jogo uma vez na conta destino para a pasta ser criada."/>
          </Grid>
        </DockPanel>
      </Grid>

      <StackPanel x:Name="OptionsPanel" Grid.Row="2" Margin="2,6,0,18"/>

      <Grid Grid.Row="3" Margin="0,0,0,16">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Background="#1E2127" BorderBrush="#2B2F37" BorderThickness="1" CornerRadius="18" Padding="14,8">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="SteamDot" Width="9" Height="9" Fill="#46A758" VerticalAlignment="Center"/>
              <TextBlock x:Name="SteamText" Text="Steam fechado" Margin="9,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>
          <Button x:Name="BtnCloseSteam" Style="{StaticResource Btn}" Content="Fechar Steam" Margin="10,0,0,0"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="BtnBackups" Style="{StaticResource Btn}" Content="Backups" Margin="0,0,10,0"/>
          <Button x:Name="BtnSync" Style="{StaticResource BtnPrimary}" Content="Sincronizar"/>
        </StackPanel>
      </Grid>

      <Border Grid.Row="4" Background="#0F1114" BorderBrush="#2B2F37" BorderThickness="1" CornerRadius="10" Padding="4">
        <TextBox x:Name="TxtLog" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                 Background="Transparent" BorderThickness="0" Foreground="#9AA0AB"
                 FontFamily="Consolas" FontSize="12" Padding="8,6"/>
      </Border>
    </Grid>

    <!-- Dialogo -->
    <Grid x:Name="Overlay" Grid.ColumnSpan="2" Background="#D90B0C0E" Visibility="Collapsed">
      <Border Background="#1E2127" BorderBrush="#343944" BorderThickness="1" CornerRadius="14" Padding="28,24"
              Width="540" VerticalAlignment="Center" HorizontalAlignment="Center">
        <StackPanel>
          <TextBlock x:Name="DlgTitle" FontSize="19" FontWeight="SemiBold" Foreground="#F2F0EB" TextWrapping="Wrap"/>
          <Border x:Name="DlgWarnBox" Background="#3A2A12" BorderBrush="#B7791F" BorderThickness="1" CornerRadius="8"
                  Padding="12,9" Margin="0,14,0,0" Visibility="Collapsed">
            <TextBlock x:Name="DlgWarn" Foreground="#F6C177" TextWrapping="Wrap"/>
          </Border>
          <TextBlock x:Name="DlgBody" Foreground="#C9CCD3" TextWrapping="Wrap" Margin="0,14,0,22" LineHeight="20"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="DlgCancel" Style="{StaticResource Btn}" Content="Cancelar" Margin="0,0,10,0"/>
            <Button x:Name="DlgOk" Style="{StaticResource BtnPrimary}" FontSize="13" Padding="22,8" Content="OK"/>
          </StackPanel>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Parse($xaml)
foreach ($n in 'LstGames','TxtGame','TxtMethod','BtnRefresh','LstSrc','LstDst','EmptyHint','BtnSwap','OptionsPanel',
               'SteamDot','SteamText','BtnCloseSteam','BtnBackups','BtnSync','TxtLog',
               'Overlay','DlgTitle','DlgWarnBox','DlgWarn','DlgBody','DlgCancel','DlgOk') {
    Set-Variable -Name $n -Value $win.FindName($n) -Scope Script
}

$iconPath = Join-Path $PSScriptRoot 'SaveSync.ico'
if (Test-Path $iconPath) {
    try { $win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$iconPath) } catch {}
}

$script:Steam     = Get-SteamPath
$script:Games     = @()
$script:Game      = $null
$script:Accounts  = @()
$script:SrcId     = $null
$script:DstIds    = @()
$script:Busy      = $false   # evita reentrada nos eventos de selecao
$script:OnConfirm = $null
$brush = New-Object Windows.Media.BrushConverter

function Write-Log([string]$msg) {
    $TxtLog.AppendText(('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg) + [Environment]::NewLine)
    $TxtLog.ScrollToEnd()
}

function Update-State {
    $running = Test-SteamRunning
    if ($running) {
        $SteamDot.Fill = $brush.ConvertFromString('#E5484D'); $SteamText.Text = 'Steam aberto - feche para sincronizar'
    } else {
        $SteamDot.Fill = $brush.ConvertFromString('#46A758'); $SteamText.Text = 'Steam fechado - pronto'
    }
    $BtnCloseSteam.Visibility = if ($running) { 'Visible' } else { 'Collapsed' }
    $BtnSwap.IsEnabled = [bool]$script:SrcId -and ($script:DstIds.Count -eq 1)
    $BtnSync.IsEnabled = (-not $running) -and [bool]$script:SrcId -and ($script:DstIds.Count -ge 1)
}

# A lista de destinos mostra todas as contas menos a origem.
function Set-Selection([string]$srcId, [string[]]$dstIds) {
    $script:Busy = $true
    try {
        $LstSrc.SelectedItem = $script:Accounts | Where-Object Id -eq $srcId | Select-Object -First 1
        $candidates = @($script:Accounts | Where-Object Id -ne $srcId)
        $LstDst.ItemsSource = $candidates
        $LstDst.SelectedItems.Clear()
        $chosen = @()
        foreach ($c in $candidates) {
            if ($dstIds -contains $c.Id) { [void]$LstDst.SelectedItems.Add($c); $chosen += $c.Id }
        }
        $EmptyHint.Visibility = if ($candidates.Count) { 'Collapsed' } else { 'Visible' }
    } finally { $script:Busy = $false }
    $script:SrcId = $srcId; $script:DstIds = @($chosen)
}

function Import-Accounts {
    if (-not $script:Game) { return }
    $srcId = $script:SrcId; $dstIds = @($script:DstIds)
    if (-not $srcId) {
        $saved = (Read-Config)[$script:Game.AppId]
        if ($saved) { $srcId = [string]$saved.origem; $dstIds = @($saved.destinos | ForEach-Object { [string]$_ }) }
    }
    $script:Accounts = @(Get-Accounts $script:Steam $script:Game.AppId)
    $script:Busy = $true
    try { $LstSrc.ItemsSource = $script:Accounts } finally { $script:Busy = $false }
    $ids = @($script:Accounts | ForEach-Object Id)
    if (-not $ids.Count) { Set-Selection '' @(); return }
    $dstIds = @($dstIds | Where-Object { $ids -contains $_ -and $_ -ne $srcId })
    if ($ids -notcontains $srcId) {
        # Sem escolha anterior: origem = maior save (mais progresso), destino = o segundo
        $sorted = @($script:Accounts | Sort-Object Size -Descending)
        $srcId = $sorted[0].Id
        $dstIds = if ($sorted.Count -ge 2) { @($sorted[1].Id) } else { @() }
    }
    Set-Selection $srcId $dstIds
}

function Set-Game($game) {
    $script:Game = $game; $script:SrcId = $null; $script:DstIds = @()
    $OptionsPanel.Children.Clear()
    if (-not $game) { return }
    $TxtGame.Text = $game.Name
    $TxtMethod.Text = if ($game.Supported) { 'Suporte completo: o save é reassinado para a conta destino.' }
                      else { 'Cópia simples: funciona em jogos que não vinculam o save à conta. Não testado para este jogo.' }
    foreach ($opt in $game.Options) {
        $chk = New-Object Windows.Controls.CheckBox
        $chk.Style = $win.FindResource('Toggle'); $chk.Content = $opt.Label; $chk.Tag = $opt.Container; $chk.IsChecked = $true
        [void]$OptionsPanel.Children.Add($chk)
    }
    Import-Accounts
    Update-State
}

function Import-Games {
    $current = if ($script:Game) { $script:Game.AppId } else { [string](Read-Config)['ultimoJogo'] }
    $script:Games = @(Get-Games $script:Steam)
    $script:Busy = $true
    try { $LstGames.ItemsSource = $script:Games } finally { $script:Busy = $false }
    if (-not $script:Games.Count) {
        Write-Log 'Nenhum jogo instalado com save em userdata foi encontrado.'
        Update-State; return
    }
    $pick = $script:Games | Where-Object AppId -eq $current | Select-Object -First 1
    if (-not $pick) { $pick = $script:Games[0] }
    $keepSrc = $script:SrcId; $keepDst = $script:DstIds
    $script:Busy = $true
    try { $LstGames.SelectedItem = $pick } finally { $script:Busy = $false }
    Set-Game $pick
    if ($keepSrc) { Set-Selection $keepSrc $keepDst; Import-Accounts; Update-State }
}

function Show-Dialog([string]$title, [string]$body, [string]$warn, [string]$okText = 'OK', [scriptblock]$onConfirm) {
    $DlgTitle.Text = $title; $DlgBody.Text = $body; $DlgOk.Content = $okText
    $DlgWarn.Text = $warn
    $DlgWarnBox.Visibility = if ($warn) { 'Visible' } else { 'Collapsed' }
    $DlgCancel.Visibility = if ($onConfirm) { 'Visible' } else { 'Collapsed' }
    $script:OnConfirm = $onConfirm
    $Overlay.Visibility = 'Visible'
}

function Request-Sync {
    if (-not $script:SrcId -or -not $script:DstIds.Count) { return }
    Import-Accounts   # relê do disco para comparar as datas atuais
    $src = $LstSrc.SelectedItem
    $dsts = @($LstDst.SelectedItems)
    if (-not $src -or -not $dsts.Count) { Write-Log 'Conta não encontrada.'; Update-State; return }

    $warns = @()
    $newer = @($dsts | Where-Object { $_.LastSave -gt $src.LastSave })
    if ($newer.Count) {
        $warns += "Destino com save mais recente que a origem: $(($newer | ForEach-Object Name) -join ', '). Confira a direção."
    }
    if (-not $script:Game.Supported) {
        $warns += 'Este jogo usa cópia simples. Se ele vincular o save à conta, o save pode não carregar no destino.'
    }
    $body = "De:  $($src.Name)  ($($src.SizeText), $($src.LastText))`nPara:`n" +
            (($dsts | ForEach-Object { "   -  $($_.Name)  ($($_.SizeText), $($_.LastText))" }) -join "`n") +
            "`n`nO save de cada destino será sobrescrito. Um backup é feito antes."
    $script:PendingSrc = $src; $script:PendingDsts = $dsts
    Show-Dialog "Sincronizar $($script:Game.Name)?" $body ($warns -join "`n`n") 'Sincronizar' { Invoke-Sync }
}

function Invoke-Sync {
    $game = $script:Game; $src = $script:PendingSrc; $dsts = $script:PendingDsts
    $skip = @($OptionsPanel.Children | Where-Object { -not $_.IsChecked } | ForEach-Object { [string]$_.Tag })
    $win.Cursor = [Windows.Input.Cursors]::Wait
    $done = @(); $failed = @()
    try {
        foreach ($dst in $dsts) {
            try { Sync-Save $game $src $dst $skip ${function:Write-Log}; $done += $dst.Name }
            catch { Write-Log "ERRO ($($dst.Name)): $($_.Exception.Message)"; $failed += "$($dst.Name): $($_.Exception.Message)" }
        }
        if ($done.Count) {
            Save-Config $game.AppId @{ origem = $src.Id; destinos = @($dsts | ForEach-Object Id) }
            Save-Config 'ultimoJogo' $game.AppId
        }
        Import-Accounts
        if ($failed.Count) {
            Show-Dialog 'Sincronização com erros' ("Concluídos: $(if ($done.Count) { $done -join ', ' } else { 'nenhum' })") ($failed -join "`n")
        } else {
            Show-Dialog 'Save sincronizado' ("O save de $($src.Name) foi copiado para: $($done -join ', ').`n`n" +
                'Abra o Steam na conta destino. Se aparecer conflito do Steam Cloud, escolha os arquivos locais.')
        }
    } finally {
        $win.Cursor = $null
        Update-State
    }
}

$LstGames.Add_SelectionChanged({
    if ($script:Busy -or -not $LstGames.SelectedItem) { return }
    Set-Game $LstGames.SelectedItem
})
$LstSrc.Add_SelectionChanged({
    if ($script:Busy -or -not $LstSrc.SelectedItem) { return }
    $new = $LstSrc.SelectedItem.Id; $old = $script:SrcId
    $dst = @($script:DstIds | Where-Object { $_ -ne $new })
    # Escolher como origem o unico destino inverte as duas contas
    if (($script:DstIds -contains $new) -and -not $dst.Count -and $old) { $dst = @($old) }
    Set-Selection $new $dst
    Update-State
})
$LstDst.Add_SelectionChanged({
    if ($script:Busy) { return }
    $script:DstIds = @($LstDst.SelectedItems | ForEach-Object Id)
    Update-State
})
$BtnSwap.Add_Click({
    if ($script:SrcId -and $script:DstIds.Count -eq 1) { Set-Selection $script:DstIds[0] @($script:SrcId); Update-State }
})
$BtnRefresh.Add_Click({ Import-Games; Write-Log 'Jogos e contas atualizados.' })
$BtnCloseSteam.Add_Click({
    try {
        Start-Process (Join-Path $script:Steam 'steam.exe') -ArgumentList '-shutdown'
        Write-Log 'Pedido de encerramento enviado ao Steam. Aguarde alguns segundos.'
    } catch { Write-Log "Não foi possível fechar o Steam: $($_.Exception.Message)" }
})
$BtnBackups.Add_Click({
    New-Item -ItemType Directory -Force $script:BackupRoot | Out-Null
    Start-Process explorer.exe $script:BackupRoot
})
$BtnSync.Add_Click({ Request-Sync })
$DlgCancel.Add_Click({ $script:OnConfirm = $null; $Overlay.Visibility = 'Collapsed' })
$DlgOk.Add_Click({
    $cb = $script:OnConfirm; $script:OnConfirm = $null
    $Overlay.Visibility = 'Collapsed'
    if ($cb) { & $cb }
})

# Barra de titulo escura (Windows 10/11)
$win.Add_SourceInitialized({
    try {
        Add-Type -Namespace SaveSyncNative -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);'
        $h = (New-Object Windows.Interop.WindowInteropHelper $win).Handle
        $v = 1
        [void][SaveSyncNative.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$v, 4)
    } catch {}
})

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({ Update-State })
$win.Add_Closed({ $timer.Stop() })

Write-Log "Steam em: $script:Steam"
Import-Games
Update-State

# ---------------------------------------------------------------- Entrada

if ($SelfTest) {
    function Save-Shot([string]$name) {
        if (-not $ShotDir) { return }
        # As capas sao decodificadas de forma assincrona; espera antes de capturar
        foreach ($i in 1..3) {
            $win.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
            Start-Sleep -Milliseconds 300
        }
        $root = $win.Content
        $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$root.ActualWidth, [int]$root.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($root)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $fs = [IO.File]::Create((Join-Path $ShotDir $name)); $enc.Save($fs); $fs.Close()
    }
    function Click($b) { $b.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))) }
    $win.Show()
    "Jogos: $($script:Games.Count)"
    foreach ($g in $script:Games) {
        $LstGames.SelectedItem = $g
        "  $($g.Name) [$($g.AppId)] $($g.MethodText), imagem=$($g.HasImage), contas=$($script:Accounts.Count), opções=$($OptionsPanel.Children.Count), origem=$($LstSrc.SelectedItem.Name), destinos=$($script:DstIds.Count), sync=$($BtnSync.IsEnabled)"
        if ($script:Accounts.Count -ge 2) {
            $src = $LstSrc.SelectedItem; $dst = @($LstDst.SelectedItems)[0]
            $items = Get-SyncItems $g $src $dst @()
            if ($g.Method -eq 'xor-steamid64') {
                # Ida e volta: o resultado precisa decifrar com a chave do destino
                $bad = @($items | Where-Object { $_.Rel -like '*data.save' -and -not (Test-ZlibPayload (Invoke-Xor $_.Bytes (Get-KeyBytes $dst.Id))) })
                "    conversão: $($items.Count) arquivos, inválidos com a chave do destino: $($bad.Count)"
            } else { "    cópia simples: $($items.Count) arquivos" }
        }
    }
    $LstGames.SelectedItem = $script:Games | Where-Object Supported | Select-Object -First 1
    Save-Shot 'main.png'
    if ($script:DstIds.Count -eq 1) {
        $a = $script:SrcId; Click $BtnSwap
        "Inverter: origem mudou = $($script:SrcId -ne $a), destinos = $($script:DstIds.Count)"
        $LstSrc.SelectedItem = $script:Accounts | Where-Object Id -eq $a
        "Escolher o destino como origem: voltou = $($script:SrcId -eq $a), destinos = $($script:DstIds.Count)"
        $LstDst.SelectedItems.Clear()
        "Sem destino -> sync habilitado: $($BtnSync.IsEnabled)"
        $LstDst.SelectAll()
        "Com destino -> sync habilitado: $($BtnSync.IsEnabled) (Steam aberto: $(Test-SteamRunning))"
        Request-Sync
        "Diálogo: $($DlgTitle.Text) | visível: $($Overlay.Visibility)"
        Save-Shot 'dialog.png'
        Click $DlgCancel
        "Overlay após cancelar: $($Overlay.Visibility)"
    }
    $win.Close()
    return
}

$timer.Start()
try { [void]$win.ShowDialog() }
catch { [Windows.MessageBox]::Show($_.Exception.Message, 'Erro') | Out-Null }
