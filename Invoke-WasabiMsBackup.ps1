# ==============================================================================
# Script: Invoke-WasabiBackup.ps1
# Leitura de Configuração e Motor de Compressão (WinRAR)
# ==============================================================================
$ErrorActionPreference = "Stop"

Write-Host "=== Iniciando Rotina de Backup Wasabi MS ===" -ForegroundColor Cyan
Write-Host "[OK] Preparando variaveis, descriptografando dados..." -ForegroundColor Cyan

# 1. Carregar Configurações
$ConfigFile = ".\config.json"
if (-not (Test-Path $ConfigFile)) {
    throw "Arquivo de configuração não encontrado: $ConfigFile"
}
$Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

# Validar/Criar diretório temporário
if (-not (Test-Path $Config.CaminhoDestinoTemp)) {
    New-Item -ItemType Directory -Path $Config.CaminhoDestinoTemp -Force | Out-Null
}

# 2. Descriptografar a senha do WinRAR (DPAPI)
try {
    $SecureSenha = ConvertTo-SecureString $Config.SenhaRarEncrypted
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureSenha)
    $SenhaRarTexto = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
} catch {
    throw "Falha ao descriptografar a senha do WinRAR. O script foi rodado com o usuário correto?"
} finally {
    if ($BSTR) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR) }
}

# 3. Preparar Variáveis do Arquivo
$DataHora = Get-Date -Format "yyyyMMdd_HHmmss"
$NomeArquivoRar = "Backup_$($Config.Cliente)_$DataHora.rar"
$CaminhoCompletoRar = Join-Path $Config.CaminhoDestinoTemp $NomeArquivoRar

# 4. Criar arquivo de lista (ListFile) para o WinRAR
# Isso é mais seguro do que passar dezenas de caminhos na linha de comando
$ListFilePath = Join-Path $Config.CaminhoDestinoTemp "bkp_lista_$DataHora.txt"
$Config.CaminhosOrigem | Out-File -FilePath $ListFilePath -Encoding UTF8

# 5. Montar os Parâmetros do WinRAR
<# Explicação dos parâmetros:
   a       : Adicionar ao arquivo
   -m5     : Compressão máxima
   -md128m : Dicionário de 128MB (Conforme solicitado)
   -rr5p   : Adicionar 5% de Registro de Recuperação (Recovery Record)
   -hp     : Criptografar dados E o cabeçalho (nomes dos arquivos ficam ocultos)
   -ep3    : Salvar caminhos completos (incluindo letra da unidade, ex: C:\...)
   -y      : Responder "Sim" para todas as perguntas automaticamente
#>
$RarArgs = @(
    "a", 
    "-m5", 
    "-md128m", 
    "-rr5p", 
    "-hp$SenhaRarTexto", 
    "-ep3", 
    "-y", 
    "`"$CaminhoCompletoRar`"", 
    "@`"$ListFilePath`""
)

# 6. Executar o WinRAR
Write-Host "[*] Iniciando compressao com WinRAR (Dicionario: 128MB, Recovery: 5%)..." -ForegroundColor Yellow
$TempoInicio = Get-Date

$Process = Start-Process -FilePath $Config.WinRarPath -ArgumentList $RarArgs -Wait -NoNewWindow -PassThru

$TempoFim = Get-Date
$Duracao = $TempoFim - $TempoInicio

# Limpar o arquivo de lista temporário
Remove-Item -Path $ListFilePath -Force -ErrorAction SilentlyContinue

# 7. Avaliar o resultado do WinRAR
# Códigos de Saída do WinRAR: 0 = Sucesso, 1 = Aviso (ex: arquivo em uso ignorado), 2+ = Erro Fatal
if ($Process.ExitCode -eq 0) {
    Write-Host "[OK] Compressao concluida com SUCESSO!" -ForegroundColor Green
    Write-Host "[OK] Arquivo gerado: $CaminhoCompletoRar" -ForegroundColor Green
    Write-Host "[OK] Tempo de compressão: $($Duracao.Hours)h $($Duracao.Minutes)m $($Duracao.Seconds)s`n" -ForegroundColor Green
} elseif ($Process.ExitCode -eq 1) {
    Write-Host "Compressão concluída com AVISOS (Alguns arquivos podem estar em uso e foram pulados)." -ForegroundColor DarkYellow
    Write-Host "Arquivo gerado: $CaminhoCompletoRar`n" -ForegroundColor DarkYellow
} else {
    throw "ERRO FATAL na compressão. Código de saída do WinRAR: $($Process.ExitCode)"
}

# Limpar a senha da memória por segurança
$SenhaRarTexto = $null




# ==============================================================================
# Passo 3: Validação de Integridade (Checksum)
# ==============================================================================

Write-Host "Calculando Checksum (SHA256) do arquivo gerado..." -ForegroundColor Yellow

try {
    $Stream = [System.IO.File]::OpenRead($CaminhoCompletoRar)
    $SHA256 = [System.Security.Cryptography.SHA256]::Create()
    $HashBytes = $SHA256.ComputeHash($Stream)
    
    # Geramos o Hexadecimal para o nosso log local ser legível
    $ChecksumHex = [System.BitConverter]::ToString($HashBytes).Replace("-", "").ToLower()
    
    # Geramos o Base64 pois é a exigência nativa da API S3/Wasabi para o painel
    $ChecksumBase64 = [System.Convert]::ToBase64String($HashBytes)
    
    Write-Host "Checksum (Hex): $ChecksumHex" -ForegroundColor Green
    
} catch {
    throw "Falha ao calcular o Checksum do arquivo. Erro: $_"
} finally {
    if ($Stream) { $Stream.Dispose() }
    if ($SHA256) { $SHA256.Dispose() }
}



# ==============================================================================
# Passo 4: Upload Seguro para a Wasabi (S3)
# ==============================================================================

Write-Host "Preparando upload para Wasabi S3..." -ForegroundColor Cyan

if (-not (Get-Module -ListAvailable -Name AWS.Tools.S3)) {
    throw "Módulo AWS.Tools.S3 não encontrado. Instale com: Install-Module -Name AWS.Tools.S3 -Force"
}

try {
    $SecureWasabiKey = ConvertTo-SecureString $Config.Credenciais.SecretKeyEncrypted
    $BSTRWasabi = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureWasabiKey)
    $SecretKeyWasabiTexto = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTRWasabi)
} catch {
    throw "Falha ao descriptografar a Secret Key da Wasabi."
} finally {
    if ($BSTRWasabi) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTRWasabi) }
}

$WasabiEndpoint = "https://s3.$($Config.WasabiRegion).wasabisys.com"

# 1. Gerando o GUID da versão como você solicitou: {GUID_MAIUSCULO}
$GuidVersao = "{" + [guid]::NewGuid().ToString().ToUpper() + "}"
Write-Host "Version ID Gerado: $GuidVersao" -ForegroundColor Magenta

# 2. Embutindo nossos dados personalizados nos metadados
$MetadadosS3 = @{
    "cliente" = $Config.Cliente
    "guid-versao" = $GuidVersao
}

Write-Host "[*] Iniciando transferencia..." -ForegroundColor Yellow
$TempoInicioUpload = Get-Date

try {
    # 3. Executando o upload forçando o ChecksumAlgorithm nativo
    Write-S3Object -BucketName $Config.WasabiBucket `
                   -Key $NomeArquivoRar `
                   -File $CaminhoCompletoRar `
                   -AccessKey $Config.Credenciais.AccessKey `
                   -SecretKey $SecretKeyWasabiTexto `
                   -EndpointUrl $WasabiEndpoint `
                   -Region $Config.WasabiRegion `
                   -Metadata $MetadadosS3 `
                   -ChecksumAlgorithm SHA256 `
                   -ErrorAction Stop

    $TempoFimUpload = Get-Date
    $DuracaoUpload = $TempoFimUpload - $TempoInicioUpload

    Write-Host "[OK] Upload concluido com SUCESSO!" -ForegroundColor Green
    Write-Host "[OK] Tempo de upload: $($DuracaoUpload.Hours)h $($DuracaoUpload.Minutes)m $($DuracaoUpload.Seconds)s`n" -ForegroundColor Green

} catch {
    throw "Erro crítico durante o upload para a Wasabi: $_"
} finally {
    $SecretKeyWasabiTexto = $null
}





# ==============================================================================
# Passo 5: Banco de Dados de Auditoria e Investigação (SQLite 3)
# ==============================================================================

Write-Host "[*] Registrando metadados e log de auditoria no Banco de Dados..." -ForegroundColor Cyan

# 1. Caminho do Banco de Dados
$DbPath = Join-Path (Get-Location).Path "dataBackup.db"

# 2. Configurações de Alta Performance (Pragmas)
<#
   journal_mode = WAL: (Write-Ahead Logging) Muito mais rápido e seguro para concorrência.
   synchronous = NORMAL: Velocidade máxima sem corromper o WAL.
   temp_store = MEMORY: Joga índices e tabelas temporárias na RAM, poupando o disco.
   automatic_index = ON: Cria índices dinâmicos para queries não otimizadas.
#>
$Pragmas = @"
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;
PRAGMA automatic_index = ON;
PRAGMA user_version = 1;
"@
Invoke-SqliteQuery -DataSource $DbPath -Query $Pragmas | Out-Null

# 3. Construção do Schema das Tabelas
$Schema = @"
CREATE TABLE IF NOT EXISTS METADATA_APP (
    uuid TEXT PRIMARY KEY,
    version TEXT,
    user_version TEXT,
    provider TEXT
);

CREATE TABLE IF NOT EXISTS BACKUP_AUDIT (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid_app TEXT,
    cliente TEXT,
    arquivo_nome TEXT,
    versao_guid TEXT,
    checksum_sha256 TEXT,
    tamanho_bytes REAL,
    data_hora_execucao TEXT,
    ip_local TEXT,
    usuario_so TEXT,
    blob_maquina BLOB,
    FOREIGN KEY(uuid_app) REFERENCES METADATA_APP(uuid)
);
"@
Invoke-SqliteQuery -DataSource $DbPath -Query $Schema | Out-Null

$AppUuid = "{AB36F605-6A60-4BBE-84A6-F66F2E0F4FFD}"
$AppVersion = "v1.0.0"
$AppUserVersion = "v1.0.0"
$AppProvider = "MS_APPS"

$QueryInsertMeta = @"
INSERT OR REPLACE INTO METADATA_APP (uuid, version, user_version, provider)
VALUES ('$AppUuid', '$AppVersion', '$AppUserVersion', '$AppProvider');
"@
Invoke-SqliteQuery -DataSource $DbPath -Query $QueryInsertMeta | Out-Null

$IpLocal = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias 'Ethernet', 'Wi-Fi' -ErrorAction SilentlyContinue).IPAddress | Select-Object -First 1
if (-not $IpLocal) { $IpLocal = "Desconhecido" }

$DadosSessao = @{
    Hostname = $env:COMPUTERNAME
    Dominio = $env:USERDOMAIN
    OS_Version = [Environment]::OSVersion.VersionString
    Porta_Conexao = 443
    Tempo_Upload_Segundos = $DuracaoUpload.TotalSeconds
}
$BlobJSON = $DadosSessao | ConvertTo-Json -Compress

$BlobBytes = [System.Text.Encoding]::UTF8.GetBytes($BlobJSON)

$TamanhoArquivo = (Get-Item $CaminhoCompletoRar).Length
$TimestampAgora = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

$QueryInsertAudit = @"
INSERT INTO BACKUP_AUDIT (
    uuid_app, cliente, arquivo_nome, versao_guid, 
    checksum_sha256, tamanho_bytes, data_hora_execucao, 
    ip_local, usuario_so, blob_maquina
) VALUES (
    @uuid_app, @cliente, @arquivo_nome, @versao_guid, 
    @checksum_sha256, @tamanho_bytes, @data_hora_execucao, 
    @ip_local, @usuario_so, @blob_maquina
);
"@

$SqlParams = @{
    "uuid_app"           = $AppUuid
    "cliente"            = $Config.Cliente
    "arquivo_nome"       = $NomeArquivoRar
    "versao_guid"        = $GuidVersao
    "checksum_sha256"    = $ChecksumBase64
    "tamanho_bytes"      = $TamanhoArquivo
    "data_hora_execucao" = $TimestampAgora
    "ip_local"           = $IpLocal
    "usuario_so"         = $env:USERNAME
    "blob_maquina"       = $BlobBytes
}


Invoke-SqliteQuery -DataSource $DbPath -Query $QueryInsertAudit -SqlParameters $SqlParams | Out-Null

Write-Host "[OK] Log de auditoria gravado no banco de dados local com SUCESSO!`n" -ForegroundColor Green



# ==============================================================================
# Passo 6: Limpeza Local e Encerramento
# ==============================================================================

if (Test-Path $CaminhoCompletoRar) {
    Remove-Item -Path $CaminhoCompletoRar -Force
    Write-Host "Limpeza: Arquivo local '$NomeArquivoRar' removido com sucesso.`n" -ForegroundColor DarkGray
    Write-Host "Limpeza: Artefatos na memoria e chaves removidos com sucesso.`n" -ForegroundColor DarkGray
}

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "[OK] Rotina de Backup FINALIZADA COM SUCESSO!" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan