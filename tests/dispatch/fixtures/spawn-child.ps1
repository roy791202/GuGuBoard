# 假的 AI CLI：啟動一個子程序（模擬 node／git），把子程序 PID 寫到檔案，然後一直等
param([string]$PidFile)
$c = Start-Process -FilePath 'powershell' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 600' -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText($PidFile, [string]$c.Id)
Start-Sleep -Seconds 600
