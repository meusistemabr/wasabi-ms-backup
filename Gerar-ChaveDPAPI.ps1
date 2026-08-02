Write-Host "=== EMBRULHAR CHAVES (DPAPI) ===" -ForegroundColor Cyan
Write-Host "A chave gerada será associada ao Hardware deste servidor.`n" -ForegroundColor Yellow
$SecretKey = Read-Host "COLE A KEY AQUI (TEXTO PLANO, SEM ESPAÇOS)" -AsSecureString
$EncryptedString = ConvertFrom-SecureString -SecureString $SecretKey

Write-Host "`n[OK] Sucesso! Copie a string abaixo e salve no config correspondente. Atente-se ao copiar corretamente:`n" -ForegroundColor Green
Write-Host $EncryptedString -ForegroundColor Magenta
Write-Host "`n======================================================================" -ForegroundColor Cyan