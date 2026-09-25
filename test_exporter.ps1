# Тест логики разбора из lhm_exporter.ps1.
# Функции берутся из настоящего файла через AST, а не копируются, — иначе
# тест проверял бы копию, а не то, что поедет на хосты.
$file = '/home/green/apps/monitoring/lhm_exporter.ps1'
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errs)
if ($errs) { throw "Файл не парсится: $($errs.Count) ошибок" }

foreach ($f in $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    Invoke-Expression $f.Extent.Text
}
# карта типов сенсоров нужна Get-SensorRows
$assign = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$SensorTypes' }, $true) | Select-Object -First 1
Invoke-Expression $assign.Extent.Text

$fail = 0
function Check {
    param($Name, $Got, $Want)
    $ok = if ($null -eq $Want) { $null -eq $Got } else { $Got -eq $Want }
    if (-not $ok) { $script:fail++ }
    $mark = if ($ok) { 'OK  ' } else { 'FAIL' }
    $g = if ($null -eq $Got) { '<null>' } else { $Got }
    Write-Host ("   {0} {1,-38} -> {2}" -f $mark, $Name, $g)
}

Write-Host 'ConvertTo-Number:'
Check 'обычная температура "45,5 °C"'      (ConvertTo-Number '45,5 °C')   45.5
Check 'точка вместо запятой "93.9 %"'      (ConvertTo-Number '93.9 %')    93.9
Check 'отрицательное "-12,0 °C"'           (ConvertTo-Number '-12,0 °C') -12.0
Check 'БАГ .160: одинокий дефис "-"'       (ConvertTo-Number '-')         $null
Check 'пустая строка'                      (ConvertTo-Number '')          $null
Check 'мусор без цифр "n/a"'               (ConvertTo-Number 'n/a')       $null
Check 'null'                               (ConvertTo-Number $null)       $null

Write-Host ''
Write-Host 'ConvertTo-SafeName:'
Check 'пробелы -> подчёркивания'           (ConvertTo-SafeName 'Core Max')    'Core_Max'
# пробел -> "_", затем "#" удаляется, остаётся CPU_Core_1
Check 'решётка выкидывается'               (ConvertTo-SafeName 'CPU Core #1') 'CPU_Core_1'
Check 'только спецсимволы'                 (ConvertTo-SafeName '###')         $null

Write-Host ''
Write-Host 'Get-SensorRows на дереве, похожем на ответ LHM:'
$tree = [pscustomobject]@{
    Text = 'root'; Type = ''; Value = ''
    Children = @(
        [pscustomobject]@{ Text='CPU'; Type=''; Value=''; Children=@(
            [pscustomobject]@{ Text='Core Max';  Type='Temperature'; Value='71,0 °C'; Children=@() }
            [pscustomobject]@{ Text='CPU Total'; Type='Load';        Value='23,5 %';  Children=@() }
            [pscustomobject]@{ Text='Broken';    Type='Temperature'; Value='-';       Children=@() }
            [pscustomobject]@{ Text='VCore';     Type='Voltage';     Value='1,21 V';  Children=@() }
            [pscustomobject]@{ Text='Clock';     Type='Clock';       Value='3600 MHz';Children=@() }
        )}
    )
}
$rows = New-Object System.Collections.ArrayList
Get-SensorRows -Node $tree -Acc $rows
# Core_Max + CPU_Total + VCore = 3; Broken отсеян по значению, Clock по типу
Check 'годных сенсоров (Broken и Clock мимо)' $rows.Count 3
Check 'температура распознана' (($rows | Where-Object { $_.Metric -eq 'custom_temperature' }).Device) 'Core_Max'
Check 'нагрузка распознана'    (($rows | Where-Object { $_.Metric -eq 'custom_load' }).Device)        'CPU_Total'
Check 'напряжение распознано'  (($rows | Where-Object { $_.Metric -eq 'custom_voltage' }).Device)     'VCore'
Check 'Clock не экспортируется' (($rows | Where-Object { $_.Device -eq 'Clock' }).Count)              0

Write-Host ''
if ($fail -gt 0) { Write-Host "ПРОВАЛЕНО ПРОВЕРОК: $fail"; exit 1 }
Write-Host 'Все проверки пройдены'
