<#
    Экспортёр метрик LibreHardwareMonitor в формате Prometheus.

    Заменяет temperature_exporter.ps1. Отличия, каждое из которых закрывает
    реальную проблему, наблюдавшуюся в проде:

    1. Нет захардкоженного IP. Старый скрипт слушал на конкретном адресе
       и его приходилось править на каждой машине.
    2. При недоступности LibreHardwareMonitor отдаёт HTTP 503, а не 200 с
       текстом "# Error: ...". Старое поведение было валидным ответом с нулём
       метрик: Prometheus считал таргет живым (up=1), правила уходили в NoData,
       и падение экспортёра выглядело как исправная работа.
    3. Пропускает нечисловые значения. Раньше из значения без цифр
       оставался один дефис, и Prometheus падал на strconv.ParseFloat "-".
    4. Читает ещё и Voltage — не только Temperature и Load.
    5. Дедуплицирует device: два сенсора с одинаковым именем давали дубль
       серии, а это ошибка парсинга всего ответа целиком.
#>
[CmdletBinding()]
param(
    [string]$LhmUrl = 'http://localhost:8085/data.json',
    [int]$Port = 8000,
    [int]$TimeoutSec = 5
)

$ErrorActionPreference = 'Stop'

# Тип сенсора в LHM -> имя метрики. Имена сохранены как в старом экспортёре,
# иначе поедут все существующие правила и дашборды.
$SensorTypes = @{
    'Temperature' = 'custom_temperature'
    'Load'        = 'custom_load'
    'Voltage'     = 'custom_voltage'
}

function ConvertTo-SafeName {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $name = $Text -replace '\s+', '_'
    $name = $name -replace '[^A-Za-z0-9_]', ''
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    return $name
}

function ConvertTo-Number {
    <#
        Возвращает $null, если из значения не получается число.
        Именно здесь отсекается случай, когда раньше в вывод попадал
        одинокий "-" и ломал разбор всего ответа.
    #>
    param([string]$Raw)
    if ($null -eq $Raw) { return $null }
    $cleaned = ($Raw -replace '[^0-9,\.\-]', '') -replace ',', '.'
    if ($cleaned -notmatch '\d') { return $null }
    $parsed = 0.0
    $styles = [Globalization.NumberStyles]::Float
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if ([double]::TryParse($cleaned, $styles, $culture, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Get-SensorRows {
    param([object]$Node, [System.Collections.ArrayList]$Acc)
    if ($null -eq $Node) { return }

    $metric = $SensorTypes[[string]$Node.Type]
    if ($metric) {
        $device = ConvertTo-SafeName -Text ([string]$Node.Text)
        $value = ConvertTo-Number -Raw ([string]$Node.Value)
        if ($device -and $null -ne $value) {
            [void]$Acc.Add([pscustomobject]@{
                Metric = $metric
                Device = $device
                Value  = $value
            })
        }
    }

    foreach ($child in $Node.Children) {
        Get-SensorRows -Node $child -Acc $Acc
    }
}

function Get-MetricsPayload {
    <#
        Возвращает объект с полями Ok и Body. Ok=$false означает, что отдавать
        надо 503: пусть Prometheus честно покажет up=0.
    #>
    try {
        $response = Invoke-WebRequest -Uri $LhmUrl -UseBasicParsing -TimeoutSec $TimeoutSec
        $data = $response.Content | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{
            Ok   = $false
            Body = "# LibreHardwareMonitor is unreachable at $LhmUrl`n# $($_.Exception.Message)`n"
        }
    }

    $rows = New-Object System.Collections.ArrayList
    Get-SensorRows -Node $data -Acc $rows

    if ($rows.Count -eq 0) {
        return [pscustomobject]@{
            Ok   = $false
            Body = "# LibreHardwareMonitor returned no usable sensors`n"
        }
    }

    $lines = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($metric in ($SensorTypes.Values | Sort-Object -Unique)) {
        $subset = $rows | Where-Object { $_.Metric -eq $metric }
        if (-not $subset) { continue }
        [void]$lines.Add("# HELP $metric Sensor readings from LibreHardwareMonitor")
        [void]$lines.Add("# TYPE $metric gauge")
        foreach ($row in $subset) {
            $key = "$($row.Metric)/$($row.Device)"
            if ($seen.ContainsKey($key)) { continue }  # дубль device сломал бы весь ответ
            $seen[$key] = $true
            $num = $row.Value.ToString([Globalization.CultureInfo]::InvariantCulture)
            [void]$lines.Add("$($row.Metric){device=`"$($row.Device)`"} $num")
        }
    }
    # Время загрузки системы. У LibreHardwareMonitor такого датчика нет, берём
    # из ОС: по изменениям этой метрики ловятся частые перезагрузки, иначе для
    # Windows-хостов на LHM их отследить нечем.
    try {
        $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        $epoch = [long]([DateTimeOffset]$boot).ToUnixTimeSeconds()
        [void]$lines.Add('# HELP custom_boot_time_seconds Unix time of last system boot')
        [void]$lines.Add('# TYPE custom_boot_time_seconds gauge')
        [void]$lines.Add("custom_boot_time_seconds $epoch")
    } catch {
        Write-Host "boot time недоступно: $($_.Exception.Message)"
    }

    [void]$lines.Add('# HELP custom_exporter_up Exporter reached LibreHardwareMonitor')
    [void]$lines.Add('# TYPE custom_exporter_up gauge')
    [void]$lines.Add('custom_exporter_up 1')

    return [pscustomobject]@{ Ok = $true; Body = ($lines -join "`n") + "`n" }
}

$listener = New-Object System.Net.HttpListener
# Слушаем на всех интерфейсах и на любом пути: Prometheus ходит на /metrics,
# но привязка к конкретному адресу требовала правки скрипта на каждой машине.
$listener.Prefixes.Add("http://+:$Port/")

try {
    $listener.Start()
} catch {
    Write-Error "Cannot listen on port $Port : $($_.Exception.Message)"
    exit 1
}
Write-Host "Exporter listening on http://+:$Port/metrics (source: $LhmUrl)"

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
        $payload = Get-MetricsPayload
        $buffer = [Text.Encoding]::UTF8.GetBytes($payload.Body)

        $context.Response.StatusCode = if ($payload.Ok) { 200 } else { 503 }
        $context.Response.ContentType = 'text/plain; version=0.0.4; charset=utf-8'
        $context.Response.ContentLength64 = $buffer.Length
        $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
        $context.Response.OutputStream.Close()
    } catch {
        # Один сбойный запрос не должен ронять службу целиком.
        Write-Host "Request failed: $($_.Exception.Message)"
    }
}

$listener.Stop()
