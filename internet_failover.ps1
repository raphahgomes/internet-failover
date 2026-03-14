<#
.SYNOPSIS
    Failover automatico de internet: Cabo -> 4G USB (celular/modem RNDIS)

.DESCRIPTION
    Detecta automaticamente a interface do modem/celular USB (Remote NDIS).
    Quando o cabo falha, aumenta a metrica do cabo para o 4G virar rota primaria.
    Quando o cabo volta, restaura as metricas originais.

    REQUER ADMINISTRADOR para alterar metricas de rede.

.EXAMPLE
    # Rodar como Administrador:
    .\internet_failover.ps1 -Status     # ver status atual
    .\internet_failover.ps1 -Force4G    # forcar 4G agora
    .\internet_failover.ps1 -ForceCable # voltar pro cabo
    .\internet_failover.ps1 -Install    # instalar tarefa agendada (inicia com Windows)
    .\internet_failover.ps1 -Uninstall  # remover tarefa agendada
    .\internet_failover.ps1             # rodar loop de monitoramento
#>

param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$Force4G,
    [switch]$ForceCable,
    [int]$IntervalSeconds  = 20,
    [int]$FailThreshold    = 3,
    [int]$RecoverThreshold = 5,
    [string]$LogFile       = "$PSScriptRoot\internet_failover.log",
    [string]$StateFile     = "$PSScriptRoot\internet_failover_state.json"
)

# -------- CONFIGURACOES --------
$CABLE_ALIAS          = "Ethernet 2"     # interface do cabo (LAN Realtek)
$CABLE_GW             = "192.168.0.1"
$CABLE_METRIC_NORMAL  = 1                # metrica normal do cabo (prioritario)
$CABLE_METRIC_FAIL    = 200              # metrica quando cabo cai (4G vira primario)

# O modem/celular USB e detectado dinamicamente pela descricao do driver
# "Remote NDIS Compatible Device" = Xiaomi USB tethering / maioria dos modems 4G USB
$MODEM_DESC_PATTERN   = "Remote NDIS Compatible"
$MODEM_GW             = "10.126.16.134"
$MODEM_METRIC_NORMAL  = 25               # metrica normal do 4G (secundario)
$MODEM_METRIC_PRIMARY = 5                # metrica quando esta como primario

$TEST_HOSTS = @("8.8.8.8", "1.1.1.1")
$TASK_NAME  = "TSC-InternetFailover"

# WhatsApp via oea_whatsapp container
$WHATSAPP_URL = "http://localhost:3030"
$WHATSAPP_ALERT_PHONE = "5516982108990"

# Containers essenciais que ficam rodando no 4G (TSC Checklist + TSC Processos + dependencias)
$ESSENTIAL_CONTAINERS = @(
    "tsc_checklist_frontend",
    "tsc_checklist_backend",
    "tsc_checklist_postgres",
    "tsc-api",
    "tsc-celery",
    "tsc-celery-beat",
    "tsc-websocket",
    "tsc-redis",
    "tsc-postgres-central",
    "027b44a9e45f_tsc-keycloak",
    "oea_whatsapp"
)
# Containers pesados que serao parados no 4G para economizar dados
$HEAVY_CONTAINERS = @(
    "8a7d3bea5f04_wazuh-indexer",
    "wazuh-dashboard",
    "wazuh-manager",
    "wazuh-scheduler",
    "postfix-relay",
    "oea_web_server",
    "oea_python_worker",
    "oea_traccar",
    "oea_n8n",
    "oea_watchtower",
    "oea_router",
    "oea_redis",
    "tsc_checklist_pgadmin",
    "tsc-pgadmin"
)

# --------------------------------
function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Msg"
    $color = switch ($Level) {
        "ERROR" { "Red" } "WARN" { "Yellow" } "OK" { "Green" } default { "White" }
    }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    $item = Get-Item $LogFile -ErrorAction SilentlyContinue
    if ($item -and $item.Length -gt 2MB) {
        Rename-Item $LogFile "$LogFile.old" -Force -ErrorAction SilentlyContinue
    }
}

function Send-WindowsToast {
    param([string]$Title, [string]$Body)
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null
        $template = @"
<toast>
  <visual><binding template="ToastGeneric">
    <text>$Title</text>
    <text>$Body</text>
  </binding></visual>
  <audio src="ms-winsoundevent:Notification.Default"/>
</toast>
"@
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("TSC-InternetFailover").Show($toast)
    } catch {
        Write-Log "  Toast notification falhou: $_" "WARN"
    }
}

function Send-WhatsAppAlert {
    param([string]$Message)
    try {
        $body = @{ phone = $WHATSAPP_ALERT_PHONE; message = $Message } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$WHATSAPP_URL/send" -Method Post -Body $body `
            -ContentType "application/json" -TimeoutSec 10 -ErrorAction Stop | Out-Null
        Write-Log "  Alerta WhatsApp enviado" "OK"
    } catch {
        Write-Log "  Alerta WhatsApp falhou: $_" "WARN"
    }
}

function Send-FailoverAlert {
    param([string]$Type, [string]$Detail = "")
    $ts = Get-Date -Format "HH:mm:ss dd/MM"
    $nl = [char]10
    switch ($Type) {
        "cabo_caiu" {
            $title = "Internet: Cabo CAIU"
            $body  = "Trafego mudou para 4G. Containers pesados parados para economizar dados."
            $wa    = "[ALERTA] *INTERNET - CABO CAIU* ($ts)${nl}${nl}Trafego no 4G. Containers pesados parados.${nl}$Detail"
        }
        "cabo_voltou" {
            $title = "Internet: Cabo VOLTOU"
            $body  = "Trafego restaurado para cabo. Containers pesados reiniciados."
            $wa    = "[OK] *INTERNET - CABO VOLTOU* ($ts)${nl}${nl}Trafego no cabo. Containers restaurados.${nl}$Detail"
        }
        "sem_internet" {
            $title = "SEM INTERNET"
            $body  = "Sem internet mesmo no 4G. Verifique modem."
            $wa    = "[CRITICO] *SEM INTERNET* ($ts)${nl}${nl}Sem internet no cabo e no 4G.${nl}$Detail"
        }
        "modem_offline" {
            $title = "Modem 4G Offline"
            $body  = "Modem 4G nao encontrado. Backup indisponivel."
            $wa    = "[ALERTA] *MODEM 4G OFFLINE* ($ts)${nl}${nl}Modem USB nao detectado.${nl}$Detail"
        }
        default { return }
    }
    Write-Log "Enviando alertas: $Type" "INFO"
    Send-WindowsToast -Title $title -Body $body
    Send-WhatsAppAlert -Message $wa
}

function Require-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "ERRO: Execute como Administrador (clique direito -> Executar como administrador)." -ForegroundColor Red
        exit 1
    }
}

function Get-ModemAlias {
    # Detecta o alias atual do modem buscando por descricao do driver
    # Funciona mesmo que o Windows renomeie a interface (Ethernet 4 -> Ethernet 5, etc.)
    $adapter = Get-NetAdapter | Where-Object {
        $_.InterfaceDescription -like "*$MODEM_DESC_PATTERN*" -and $_.Status -eq "Up"
    } | Select-Object -First 1
    if ($adapter) { return $adapter.Name }
    return $null
}

function Test-InternetOk {
    foreach ($h in $TEST_HOSTS) {
        $r = & ping.exe -n 2 -w 2000 $h 2>&1
        if ($r -match "bytes=") { return $true }
    }
    return $false
}

function Test-CableGateway {
    $r = & ping.exe -n 2 -w 1000 $CABLE_GW 2>&1
    return ($r -match "bytes=")
}

function Get-CurrentMode {
    # Modo 4G = metrica do cabo esta alta (>= 100)
    $iface = Get-NetIPInterface -InterfaceAlias $CABLE_ALIAS -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if (-not $iface) { return "unknown" }
    if ($iface.InterfaceMetric -ge 100) { return "4g" } else { return "cable" }
}

function Set-IfMetric {
    param([string]$Alias, [int]$Metric)
    try {
        Set-NetIPInterface -InterfaceAlias $Alias -AutomaticMetric Disabled -InterfaceMetric $Metric -ErrorAction Stop
        Write-Log "  Metrica de '$Alias' -> $Metric" "OK"
        return $true
    } catch {
        Write-Log "  Erro metrica '$Alias': $_" "ERROR"
        return $false
    }
}

function Stop-HeavyContainers {
    Write-Log "Parando containers pesados para economizar dados 4G..." "WARN"
    foreach ($c in $HEAVY_CONTAINERS) {
        $running = docker inspect -f '{{.State.Running}}' $c 2>&1
        if ($running -eq "true") {
            docker stop $c 2>&1 | Out-Null
            Write-Log "  Parado: $c" "WARN"
        }
    }
    Write-Log "Apenas containers essenciais ativos (Checklist + Processos)" "OK"
}

function Start-HeavyContainers {
    Write-Log "Restaurando containers pesados (cabo voltou)..." "OK"
    foreach ($c in $HEAVY_CONTAINERS) {
        $exists = docker inspect -f '{{.State.Status}}' $c 2>&1
        if ($exists -match "exited|created") {
            docker start $c 2>&1 | Out-Null
            Write-Log "  Iniciado: $c" "OK"
        }
    }
    Write-Log "Todos os containers restaurados" "OK"
}

function Enable-4G-Primary {
    Write-Log "======================================" "WARN"
    Write-Log "CABO CAIU -- Ativando 4G como primario" "WARN"
    Write-Log "======================================" "WARN"

    $modemAlias = Get-ModemAlias
    if (-not $modemAlias) {
        Write-Log "Interface 4G nao encontrada (celular desconectado?)." "ERROR"
        Write-Log "Reconecte o celular/modem USB e verifique o tethering." "ERROR"
        Send-FailoverAlert -Type "modem_offline"
        return
    }
    Write-Log "Modem detectado: '$modemAlias'" "INFO"
    Set-IfMetric -Alias $CABLE_ALIAS  -Metric $CABLE_METRIC_FAIL    | Out-Null
    Set-IfMetric -Alias $modemAlias   -Metric $MODEM_METRIC_PRIMARY | Out-Null
    Write-Log "Trafego agora vai pelo 4G ($modemAlias)" "OK"

    # Economizar dados: parar containers pesados
    Stop-HeavyContainers

    Send-FailoverAlert -Type "cabo_caiu" -Detail "Modem: $modemAlias"
}

function Restore-Cable-Primary {
    Write-Log "======================================" "OK"
    Write-Log "CABO VOLTOU -- Restaurando cabo como primario" "OK"
    Write-Log "======================================" "OK"

    Set-IfMetric -Alias $CABLE_ALIAS -Metric $CABLE_METRIC_NORMAL | Out-Null
    $modemAlias = Get-ModemAlias
    if ($modemAlias) {
        Set-IfMetric -Alias $modemAlias -Metric $MODEM_METRIC_NORMAL | Out-Null
    } else {
        Write-Log "  Interface 4G desconectada -- so restaurou o cabo" "WARN"
    }
    Write-Log "Trafego voltou para o cabo" "OK"

    # Restaurar containers pesados
    Start-HeavyContainers

    Send-FailoverAlert -Type "cabo_voltou"
}

function Show-Status {
    Write-Host ""
    Write-Host "=== STATUS DO FAILOVER DE INTERNET ===" -ForegroundColor Cyan
    Write-Host ""

    # Cabo
    $cable = Get-NetAdapter -Name $CABLE_ALIAS -ErrorAction SilentlyContinue
    $cc = if ($cable.Status -eq "Up") { "Green" } else { "Red" }
    Write-Host ("Cabo  ({0}): {1}" -f $CABLE_ALIAS, $(if ($cable) { $cable.Status } else { "NAO ENCONTRADO" })) -ForegroundColor $cc

    # 4G (detectado dinamicamente)
    $modemAlias = Get-ModemAlias
    $modem = if ($modemAlias) { Get-NetAdapter -Name $modemAlias -ErrorAction SilentlyContinue } else { $null }
    $mc = if ($modem) { "Green" } else { "Red" }
    $mDesc = if ($modem) { $modem.InterfaceDescription } else { "desconectado" }
    Write-Host ("4G    ({0}): {1}  [{2}]" -f $(if ($modemAlias) { $modemAlias } else { "N/A" }), $(if ($modem) { $modem.Status } else { "NAO ENCONTRADO" }), $mDesc) -ForegroundColor $mc

    # IPs
    $cableIP = (Get-NetIPAddress -InterfaceAlias $CABLE_ALIAS -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    $modemIP = if ($modemAlias) { (Get-NetIPAddress -InterfaceAlias $modemAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress } else { "N/A" }
    Write-Host "IP Cabo : $cableIP"
    Write-Host "IP 4G   : $modemIP"

    # Rotas
    Write-Host ""
    Write-Host "Rotas padrao (0.0.0.0/0):" -ForegroundColor Yellow
    Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Select-Object InterfaceAlias, NextHop, RouteMetric, InterfaceMetric,
            @{N="Total";E={$_.RouteMetric + $_.InterfaceMetric}} |
        Sort-Object Total |
        Format-Table -AutoSize

    # Modo
    $mode = Get-CurrentMode
    Write-Host "Modo atual: " -NoNewline
    switch ($mode) {
        "4g"      { Write-Host "4G ATIVO (cabo com falha ou forcado)" -ForegroundColor Yellow }
        "cable"   { Write-Host "CABO (normal)" -ForegroundColor Green }
        default   { Write-Host "DESCONHECIDO" -ForegroundColor Red }
    }

    # Internet
    Write-Host ""
    Write-Host "Testando internet... " -NoNewline
    if (Test-InternetOk) { Write-Host "OK" -ForegroundColor Green } else { Write-Host "SEM INTERNET" -ForegroundColor Red }

    # Tarefa
    $task = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "Tarefa '$TASK_NAME': " -NoNewline
    if ($task) {
        $sc = if ($task.State -eq "Running") { "Green" } else { "Yellow" }
        Write-Host "$($task.State)" -ForegroundColor $sc
    } else {
        Write-Host "NAO INSTALADA (rode -Install como admin)" -ForegroundColor Yellow
    }

    # Docker containers
    Write-Host ""
    Write-Host "Containers Docker:" -ForegroundColor Cyan
    $running = docker ps --format "{{.Names}}" 2>&1
    if ($running) {
        $essUp   = ($ESSENTIAL_CONTAINERS | Where-Object { $running -contains $_ }).Count
        $heavyUp = ($HEAVY_CONTAINERS     | Where-Object { $running -contains $_ }).Count
        $essTot  = $ESSENTIAL_CONTAINERS.Count
        $heavyTot = $HEAVY_CONTAINERS.Count
        Write-Host "  Essenciais: $essUp/$essTot ativos" -ForegroundColor Green
        $hc = if ($heavyUp -eq 0 -and $mode -eq "4g") { "Yellow" } elseif ($heavyUp -gt 0) { "Green" } else { "Red" }
        Write-Host "  Pesados:    $heavyUp/$heavyTot ativos" -ForegroundColor $hc
        if ($mode -eq "4g" -and $heavyUp -eq 0) {
            Write-Host "  (Containers pesados parados para economizar dados 4G)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Docker indisponivel" -ForegroundColor Red
    }
    Write-Host ""
}

function Install-Task {
    Require-Admin
    $scriptPath = $PSCommandPath
    $action    = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::Zero) `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable $true
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    Register-ScheduledTask -TaskName $TASK_NAME -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Description "Failover automatico cabo->4G" `
        -Force | Out-Null
    Start-ScheduledTask -TaskName $TASK_NAME
    Write-Host "Tarefa '$TASK_NAME' instalada e iniciada." -ForegroundColor Green
}

function Uninstall-Task {
    Require-Admin
    Stop-ScheduledTask       -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Tarefa '$TASK_NAME' removida." -ForegroundColor Yellow
}

# ---- ENTRYPOINTS ----
if ($Status)    { Show-Status; exit 0 }
if ($Uninstall) { Uninstall-Task; exit 0 }
if ($Install)   { Install-Task; Show-Status; exit 0 }

if ($Force4G) {
    Require-Admin
    Write-Log "Forcando 4G (manual)" "WARN"
    Enable-4G-Primary
    Show-Status
    exit 0
}
if ($ForceCable) {
    Require-Admin
    Write-Log "Restaurando cabo (manual)" "WARN"
    Restore-Cable-Primary
    Show-Status
    exit 0
}

# ---- LOOP PRINCIPAL ----
Require-Admin
Write-Log "Iniciando monitor (intervalo=$($IntervalSeconds)s, falhas=$($FailThreshold), recuperacao=$($RecoverThreshold))"
Write-Log "Cabo: $CABLE_ALIAS ($CABLE_GW) | 4G: detectado por '$MODEM_DESC_PATTERN'"

$failCount    = 0
$recoverCount = 0
$lastNoInetAlert = [datetime]::MinValue
$modeChangedAt   = Get-Date
$mode         = Get-CurrentMode
Write-Log "Modo inicial: $mode"

while ($true) {
    $inetOk = Test-InternetOk
    $gwOk   = Test-CableGateway

    if ($mode -eq "4g") {
        # No modo 4G, verificar se o CABO voltou pelo gateway local (nao pelo teste de internet,
        # que passa pelo 4G e sempre retorna OK enquanto 4G estiver ativo)
        if ($gwOk) {
            $recoverCount++
            Write-Log "Gateway cabo respondendo ($recoverCount de $RecoverThreshold confirmacoes)" "WARN"
            if ($recoverCount -ge $RecoverThreshold) {
                Restore-Cable-Primary
                $mode = "cable"
                $modeChangedAt = Get-Date
                $recoverCount = 0
                # Confirmar que internet funciona pelo cabo
                Start-Sleep -Seconds 2
                if (-not (Test-InternetOk)) {
                    Write-Log "Cabo voltou mas sem internet -- retornando ao 4G" "ERROR"
                    Enable-4G-Primary
                    $mode = "4g"
                }
            }
        } else {
            $recoverCount = 0
            if (-not $inetOk) {
                Write-Log "SEM INTERNET mesmo no 4G -- verifique celular/sinal" "ERROR"
                if (((Get-Date) - $lastNoInetAlert).TotalMinutes -ge 10) {
                    Send-FailoverAlert -Type "sem_internet"
                    $lastNoInetAlert = Get-Date
                }
            }
        }
    } elseif ($inetOk) {
        $failCount    = 0
        $recoverCount = 0
        $m = [int](Get-Date -Format "mm")
        if ($m % 5 -eq 0) { Write-Log "OK -- internet via cabo" "OK" }
    } else {
        $recoverCount = 0
        if ($mode -eq "cable") {
            $failCount++
            $gwInfo = if ($gwOk) { "gateway local OK" } else { "gateway sem resposta" }
            Write-Log "Sem internet ($failCount de $FailThreshold) -- $gwInfo" "WARN"
            if ($failCount -ge $FailThreshold) {
                Enable-4G-Primary
                $mode = "4g"
                $modeChangedAt = Get-Date
                $failCount = 0
            }
        }
    }

    # Enrich state for dashboard
    $cableStatus = (Get-NetAdapter -Name $CABLE_ALIAS -ErrorAction SilentlyContinue).Status
    $modemAlias  = Get-ModemAlias
    $modemAdapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "*$MODEM_DESC_PATTERN*" } | Select-Object -First 1
    $modemStatus = if ($modemAdapter) { $modemAdapter.Status } else { "Down" }
    $modemName   = if ($modemAlias) { $modemAlias } elseif ($modemAdapter) { $modemAdapter.Name } else { "N/A" }
    $essRunning  = @(docker ps --format '{{.Names}}' 2>&1 | Where-Object { $ESSENTIAL_CONTAINERS -contains $_ }).Count
    $heavyRunning = @(docker ps --format '{{.Names}}' 2>&1 | Where-Object { $HEAVY_CONTAINERS -contains $_ }).Count

    @{
        mode=$mode; failCount=$failCount; recoverCount=$recoverCount
        lastUpdate=(Get-Date -Format "o"); modeChangedAt=$modeChangedAt.ToString("o")
        internet=$inetOk; cableGateway=$gwOk
        cableStatus=$cableStatus; cableAlias=$CABLE_ALIAS
        modemStatus=$modemStatus; modemAlias=$modemName
        essentialUp=$essRunning; essentialTotal=$ESSENTIAL_CONTAINERS.Count
        heavyUp=$heavyRunning; heavyTotal=$HEAVY_CONTAINERS.Count
    } | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8 -ErrorAction SilentlyContinue

    Start-Sleep -Seconds $IntervalSeconds
}
