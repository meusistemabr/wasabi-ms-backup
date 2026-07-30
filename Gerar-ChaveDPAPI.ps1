# ==============================================================================
# Script: Gerar-ChaveDPAPI.ps1
# Objetivo: Transformar a Secret Key da Wasabi em uma string criptografada
# ==============================================================================

Write-Host "=== Gerador de Chave Segura (DPAPI) ===" -ForegroundColor Cyan
Write-Host "A chave gerada só poderá ser lida por este usuário, neste computador.`n" -ForegroundColor Yellow

# Pede a chave de forma segura (os caracteres não aparecem na tela)
$SecretKey = Read-Host "Cole sua Secret Key da Wasabi" -AsSecureString

# Converte para a string criptografada vinculada ao sistema
$EncryptedString = ConvertFrom-SecureString -SecureString $SecretKey

Write-Host "`nSucesso! Copie a string abaixo e cole no seu config.json no campo 'SecretKeyEncrypted':`n" -ForegroundColor Green
Write-Host $EncryptedString -ForegroundColor Magenta
Write-Host "`n======================================================================" -ForegroundColor Cyan