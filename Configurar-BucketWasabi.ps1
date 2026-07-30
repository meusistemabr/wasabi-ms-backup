# ==============================================================================
# Script: Configurar-BucketWasabi.ps1
# Objetivo: Habilitar Versionamento e Criar Regra de Exclusão (7 dias)
# Executar: APENAS UMA VEZ POR BUCKET!
# ==============================================================================
$ErrorActionPreference = "Stop"

Write-Host "=== Configurando Bucket Wasabi (Versionamento e Lifecycle) ===" -ForegroundColor Cyan

# 1. Carregar Configuração e Descriptografar Chave (Mesma lógica do backup)
$Config = Get-Content ".\config.json" -Raw | ConvertFrom-Json
$SecureWasabiKey = ConvertTo-SecureString $Config.Credenciais.SecretKeyEncrypted
$BSTRWasabi = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureWasabiKey)
$SecretKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTRWasabi)

$WasabiEndpoint = "https://s3.$($Config.WasabiRegion).wasabisys.com"

# 2. Habilitar Versionamento
Write-Host "Ativando Versionamento no bucket '$($Config.WasabiBucket)'..." -ForegroundColor Yellow
Write-S3BucketVersioning -BucketName $Config.WasabiBucket `
                         -VersioningConfig_Status Enabled `
                         -AccessKey $Config.Credenciais.AccessKey `
                         -SecretKey $SecretKey `
                         -EndpointUrl $WasabiEndpoint `
                         -Region $Config.WasabiRegion
Write-Host "Versionamento Ativado!" -ForegroundColor Green

# 3. Configurar Lifecycle (Ciclo de Vida de 7 dias)
Write-Host "Criando política de exclusão automática (7 dias)..." -ForegroundColor Yellow

# Cria a regra no padrão da API AWS .NET
$LifecycleRule = New-Object Amazon.S3.Model.LifecycleRule
$LifecycleRule.Id = "ExclusaoAutomatica7Dias"
$LifecycleRule.Status = [Amazon.S3.BucketLifecycleStatus]::Enabled

# Filtro vazio = Aplica para TODOS os arquivos do bucket
$LifecycleRule.Filter = New-Object Amazon.S3.Model.LifecycleFilter
$LifecycleRule.Filter.LifecycleFilterPredicate = New-Object Amazon.S3.Model.LifecyclePrefixPredicate
$LifecycleRule.Filter.LifecycleFilterPredicate.Prefix = ""

# Expira a versão atual após 7 dias
$LifecycleRule.Expiration = New-Object Amazon.S3.Model.LifecycleRuleExpiration
$LifecycleRule.Expiration.Days = 7

# Expira também as versões antigas (histórico do versionamento) após 7 dias
$LifecycleRule.NoncurrentVersionExpiration = New-Object Amazon.S3.Model.LifecycleRuleNoncurrentVersionExpiration
$LifecycleRule.NoncurrentVersionExpiration.NoncurrentDays = 7

$LifecycleConfig = New-Object Amazon.S3.Model.LifecycleConfiguration
$LifecycleConfig.Rules.Add($LifecycleRule)

Write-S3LifecycleConfiguration -BucketName $Config.WasabiBucket `
                               -Configuration $LifecycleConfig `
                               -AccessKey $Config.Credenciais.AccessKey `
                               -SecretKey $SecretKey `
                               -EndpointUrl $WasabiEndpoint `
                               -Region $Config.WasabiRegion

Write-Host "Lifecycle Configurado com Sucesso! Arquivos sumirão após 7 dias." -ForegroundColor Green

# Limpar memória
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTRWasabi)