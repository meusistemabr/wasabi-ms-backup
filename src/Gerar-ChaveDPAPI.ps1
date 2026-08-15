[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host "=== EMBRULHAR CHAVES (DPAPI) ===" -ForegroundColor Cyan
Write-Host "A chave gerada será associada ao Hardware/Usuário deste servidor.`n" -ForegroundColor Yellow

$SecretKey = Read-Host "COLE A KEY AQUI (TEXTO PLANO, SEM ESPAÇOS)" -AsSecureString
$EncryptedString = ConvertFrom-SecureString -SecureString $SecretKey

Write-Host "`n[OK] Sucesso! A string foi gerada. Atente-se ao copiar corretamente:`n" -ForegroundColor Green
Write-Host $EncryptedString -ForegroundColor Magenta
Write-Host "`n======================================================================" -ForegroundColor Cyan

$resposta = Read-Host "`nDeseja copiar o código para a área de transferência? (S/N)"

if ($resposta -match '^[sS]') {
    Set-Clipboard -Value $EncryptedString
    Write-Host "`n[+] Código copiado para a área de transferência com sucesso!" -ForegroundColor Green
} else {
    Write-Host "`n[-] O código não foi copiado." -ForegroundColor DarkGray
}

Write-Host "`n======================================================================" -ForegroundColor Cyan


Read-Host "Pressione ENTER para fechar a janela..."