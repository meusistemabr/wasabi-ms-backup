[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "=== EMBRULHAR CHAVES (DPAPI) ===" -ForegroundColor Cyan
Write-Host "A chave gerada sera associada ao Hardware/Usuario deste dispositivo.`nA abertura do embrulho de keys so sera aberta neste mesmo dispositivo.`n`nPara mais informacoes, entre em contato conosco: contato[arroba]meusistema.com.br`n`n`n" -ForegroundColor Yellow

$SecretKey = Read-Host "COLE A KEY AQUI QUE DESEJA ENCRIPTAR (TEXTO PLANO, SEM ESPACOS)" -AsSecureString
$EncryptedString = ConvertFrom-SecureString -SecureString $SecretKey

Write-Host "`n[OK] Sucesso! A string criptografada foi gerada. Atente-se ao copiar corretamente:`n" -ForegroundColor Green
Write-Host $EncryptedString -ForegroundColor Magenta
Write-Host "`n======================================================================" -ForegroundColor Cyan

$resposta = Read-Host "`nDeseja copiar a string criptografada para a Area de transferencia? (S/N + enter)"

if ($resposta -match '^[sS]') {
    Set-Clipboard -Value $EncryptedString
    Write-Host "`n[+] String copiada para a área de transferencia com sucesso! Cole no local correspondente no arquivo config.json" -ForegroundColor Green
} else {
    Write-Host "`n[-] A string nao foi copiada. O programa esta encerrado." -ForegroundColor DarkGray
}

Write-Host "`n======================================================================" -ForegroundColor Cyan


Read-Host "Pressione ENTER para fechar a janela..."