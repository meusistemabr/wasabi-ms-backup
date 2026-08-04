$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'

Write-Host "=== SCRIPT BACKUP AUTOMÁTICO WASABI MS (PROIBIDA REPRODUÇÃO) ===" -ForegroundColor Cyan
Start-Sleep -Seconds 2


$EhWindows = if ($null -ne $IsWindows) { $IsWindows } else { [Environment]::OSVersion.Platform -match "Win32" }

if (-not $EhWindows) {
    Write-Host "======================================================================" -ForegroundColor Red
    Write-Host "[ERRO CRÍTICO] Este script foi projetado EXCLUSIVAMENTE para WINDOWS." -ForegroundColor Red
    Write-Host "Execução abortada para prevenir falhas de diretório ou comandos." -ForegroundColor Red
    Write-Host "======================================================================" -ForegroundColor Red
    exit 1
}


Write-Host "[OK] Preparando variáveis, descriptografando dados..." -ForegroundColor Cyan
Start-Sleep -Seconds 1

$ConfigFile = ".\config.json"
if (-not (Test-Path $ConfigFile)) {
    Write-Host "[ERRO CRÍTICO] Arquivo de configuração não encontrado: config.json`n`nLembre-se: O arquivo de configuração deverá estar no mesmo diretório do script. O diretório também precisa de permissões de leitura e gravação." -ForegroundColor Red
    exit 1
}
$Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
Start-Sleep -Seconds 1

if (-not (Test-Path $Config.CaminhoDestinoTemp)) {
    New-Item -ItemType Directory -Path $Config.CaminhoDestinoTemp -Force | Out-Null
}


$SenhaRarTexto = ""
$SenhaFallbackAtivada = $false


try {
    if ($Config.SenhaRarEncrypted) {
        $SecureSenha = ConvertTo-SecureString $Config.SenhaRarEncrypted -ErrorAction Stop
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureSenha)
        $SenhaRarTexto = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    }
} catch {
    Write-Host "[AVISO] Falha ao descriptografar senha do WinRAR do JSON.`nImpossível o script continuar a execução, verifique o blob da senha e tente novamente..." -ForegroundColor DarkYellow
    exit 1
} finally {
    if ($BSTR) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR) }
}
if ([string]::IsNullOrWhiteSpace($SenhaRarTexto)) {
    $SenhaRarTexto = "{" + [guid]::NewGuid().ToString().ToUpper() + "}"
    $SenhaFallbackAtivada = $true
    Write-Host "[AVISO] Utilizando SENHA PADRÃO DE FALLBACK para o WinRAR." -ForegroundColor DarkYellow

    $CaminhoArquivo = Join-Path $PSScriptRoot "senha_winrar_gerada_automaticamente.txt"
    $SenhaRarTexto | Out-File -FilePath $CaminhoArquivo -Encoding utf8
}


if ($Config.IncluiBackupMariaDBMysql -eq $true) {
    Write-Host "`n=== INICIANDO BACKUP DO BANCO DE DADOS.... ===" -ForegroundColor Cyan
    
    $DbConfig = $Config.DataInfoBKPMariaDBMysql
    $MysqlExe = Join-Path $DbConfig.BinPath "mysql.exe"
    $MysqldumpExe = Join-Path $DbConfig.BinPath "mysqldump.exe"
    if (-not (Test-Path $MysqlExe) -or -not (Test-Path $MysqldumpExe)) {
        throw "[ERROR] Executaveis do MySQL/MariaDB nao encontrados no caminho: $($DbConfig.BinPath)"
    }

    try {
        $SecureDbPass = ConvertTo-SecureString $DbConfig.SecretPassEncrypted
        $BSTRDb = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureDbPass)
        $SenhaDbTexto = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTRDb)
    } catch {
        throw "Falha ao descriptografar a senha do Banco de Dados."
    }

    $env:MYSQL_PWD = $SenhaDbTexto
    
    $DbConfig = $Config.DataInfoBKPMariaDBMysql
    $MysqlExe = Join-Path $DbConfig.BinPath "mysql.exe"
    $MysqldumpExe = Join-Path $DbConfig.BinPath "mysqldump.exe"
    
    Write-Host "[OK] Verificando status do servidor BD e obtendo bancos...AGUARDE..." -ForegroundColor Yellow
    Start-Sleep -Seconds 1
    
    $InfoVersao = & $MysqlExe -V 2>&1
    Start-Sleep -Seconds 1
    
    $SuportaSslMode = ($InfoVersao -match "MySQL" -and $InfoVersao -notmatch "MariaDB" -and ($InfoVersao -match "Distrib 5\.7\.[1-9][0-9]" -or $InfoVersao -match "Distrib [8-9]\."))
    Start-Sleep -Seconds 1
    
    $ArgumentosBase = @("-h", $DbConfig.Host, "-P", $DbConfig.Port, "-u", $DbConfig.User, "-s", "-N", "-e", "SHOW DATABASES;")
    
    if ($SuportaSslMode) {
        Write-Host "[*] Cliente MySQL nativo detectado..." -ForegroundColor DarkCyan
        $ArgumentosFinais = $ArgumentosBase + "--ssl-mode=DISABLED"
        $ListaBancos = & $MysqlExe $ArgumentosFinais 2>&1
        
    } else {
        Write-Host "[*] Cliente MariaDB ou legado detectado..." -ForegroundColor DarkCyan
        $ArgumentosMariaDB = $ArgumentosBase + "--skip-ssl"
        $ListaBancos = $(& $MysqlExe $ArgumentosMariaDB 2>&1) | Where-Object { 
            $_ -notmatch "WARNING" -and 
            -not ([string]::IsNullOrWhiteSpace($_))
        }
    }

    Start-Sleep -Seconds 1

    if ($LASTEXITCODE -ne 0) {
        $env:MYSQL_PWD = $null
        throw "[ERROR] Erro Crítico: Falha ao conectar no BD. Verifique se está online e se as credenciais tem permissão. Detalhes: $ListaBancos"
    }

    $BancosSistema = @("information_schema", "mysql", "performance_schema", "sys")
    $BancosParaBackup = $ListaBancos -split "`n" | Where-Object { $_.Trim() -notin $BancosSistema -and $_.Trim() -ne "" }
    Start-Sleep -Seconds 1

    if ($BancosParaBackup.Count -eq 0) {
        Write-Host "Nenhum banco de dados de usuário encontrado para backup." -ForegroundColor Yellow
    } else {
        Write-Host "Encontrados $($BancosParaBackup.Count) bancos de dados para dump." -ForegroundColor Green
        $PastaBancosTemp = Join-Path $Config.CaminhoDestinoTemp "BancosDB_$DataHora"
        New-Item -ItemType Directory -Path $PastaBancosTemp -Force | Out-Null

        foreach ($Banco in $BancosParaBackup) {
            $Banco = $Banco.Trim()
            $DataHoraMili = Get-Date -Format "yyyyMMdd_HHmmss_fff"
            $NomeDumpSql = "$($Banco)_$DataHoraMili.sql"
            $CaminhoSql = Join-Path $PastaBancosTemp $NomeDumpSql
            $CaminhoRarInd = Join-Path $PastaBancosTemp "$($Banco)_$DataHoraMili.rar"

            Write-Host "[*] Realizando dump de: $Banco ..." -ForegroundColor Cyan
           
            #$ComandoDump = & "cmd.exe /c `"`"$MysqldumpExe`" -h $($DbConfig.Host) -P $($DbConfig.Port) -u $($DbConfig.User) --single-transaction --routines --triggers $Banco > `"$CaminhoSql`" 2>nul`""
            $ArgumentosDump = @(
                "-h", $DbConfig.Host, 
                "-P", $DbConfig.Port, 
                "-u", $DbConfig.User, 
                "--single-transaction", 
                "--routines", 
                "--triggers", 
                "--skip-ssl",
                $Banco, 
                "--result-file=$CaminhoSql"
            )
            & $MysqldumpExe $ArgumentosDump 2>$null
            Start-Sleep -Seconds 2

            if (Test-Path $CaminhoSql) {
                Write-Host "[**] Compactando $Banco individualmente..." -ForegroundColor DarkGray
               
                $ArgsRarInd = @("a", "-m5", "-ep", "-y", "-hp$SenhaRarTexto", "`"$CaminhoRarInd`"", "`"$CaminhoSql`"")
                $ProcessoRarInd = Start-Process -FilePath $Config.WinRarPath -ArgumentList $ArgsRarInd -Wait -NoNewWindow -PassThru
                Start-Sleep -Seconds 1
                
                if ($ProcessoRarInd.ExitCode -eq 0) {
                    $StreamInd = [System.IO.File]::OpenRead($CaminhoRarInd)
                    $SHA256Ind = [System.Security.Cryptography.SHA256]::Create()
                    $HashInd = [System.BitConverter]::ToString($SHA256Ind.ComputeHash($StreamInd)).Replace("-", "").ToLower()
                    $StreamInd.Dispose(); $SHA256Ind.Dispose()
                    
                    Write-Host "[OK] ARQUIVO RAR gerado. Checksum SHA256: $HashInd" -ForegroundColor Green
                    Remove-Item -Path $CaminhoSql -Force
                } else {
                    Write-Host "[ERRO] Falha ao compactar o banco $Banco" -ForegroundColor Red
                }
            }
        }
        Start-Sleep -Seconds 1
        $NomeMasterDB = "MasterBackupDB_$($Config.Cliente)_$DataHora.rar"
        $CaminhoMasterDB = Join-Path $Config.CaminhoDestinoTemp $NomeMasterDB
        Write-Host "`n[OK] Unindo todos os bancos de dados em um arquivo Master: $NomeMasterDB" -ForegroundColor Yellow

        $ArgsRarMaster = @("a", "-m0", "-ep", "-y", "-hp$SenhaRarTexto", "`"$CaminhoMasterDB`"", "$PastaBancosTemp\*.rar")
        $ProcessoMaster = Start-Process -FilePath $Config.WinRarPath -ArgumentList $ArgsRarMaster -Wait -NoNewWindow -PassThru

        if ($ProcessoMaster.ExitCode -eq 0) {
            Write-Host "[OK] Pacote Master de Bancos de Dados gerado com sucesso!" -ForegroundColor Green
            Write-Host "`nLim" -ForegroundColor Cyan
            Remove-Item -Path $PastaBancosTemp -Recurse -Force
            Start-Sleep -Seconds 2

            Write-Host "`n=== Iniciando Envio do Banco de Dados [MYSQL/MARIADB] para Wasabi ===" -ForegroundColor Cyan
            
            $StreamDB = [System.IO.File]::OpenRead($CaminhoMasterDB)
            $SHA256DB = [System.Security.Cryptography.SHA256]::Create()
            $HashBytesDB = $SHA256DB.ComputeHash($StreamDB)
            $ChecksumBase64DB = [System.Convert]::ToBase64String($HashBytesDB)
            $StreamDB.Dispose(); $SHA256DB.Dispose()

            $WasabiEndpoint = "https://s3.$($Config.WasabiRegion).wasabisys.com"
            $GuidVersaoDB = "{" + [guid]::NewGuid().ToString().ToUpper() + "}"
            
            $MetadadosS3DB = @{
                "cliente" = $Config.Cliente
                "guid-versao" = $GuidVersaoDB
                "tipo-arquivo" = "database_dump"
            }

            try {
                $SecureWasabi = ConvertTo-SecureString $Config.Credenciais.SecretKeyEncrypted
                $BSTRWasabi = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureWasabi)
                $SecretKeyWasabi = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTRWasabi)
                
                Write-Host "[*] Iniciando transferência..." -ForegroundColor Yellow
                $TempoIniUploadDB = Get-Date

                Start-Sleep -Seconds 2

                Write-Host "[*] Transferência em andamento... AGUARDE..." -ForegroundColor Yellow
                Start-Sleep -Seconds 1

                Write-S3Object -BucketName $Config.WasabiBucket `
                               -Key $NomeMasterDB `
                               -File $CaminhoMasterDB `
                               -AccessKey $Config.Credenciais.AccessKey `
                               -SecretKey $SecretKeyWasabi `
                               -EndpointUrl $WasabiEndpoint `
                               -Region $Config.WasabiRegion `
                               -Metadata $MetadadosS3DB `
                               -ChecksumAlgorithm SHA256 `
                               -StorageClass STANDARD `
                               -ContentType application/vnd.rar `
                               -ErrorAction Stop

                $TempoFimUploadDB = Get-Date
                Write-Host "[OK] Upload do BACKUP DO BANCO DE DADOS DO CLIENTE concluído em $(($TempoFimUploadDB - $TempoIniUploadDB).TotalSeconds) segundos!" -ForegroundColor Green
            } catch {
                throw "[ERROR] Erro ao fazer upload do Banco de Dados: $_"
            } finally {
                if ($BSTRWasabi) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTRWasabi); $SecretKeyWasabi = $null }
            }

            Start-Sleep -Seconds 1

            Write-Host "[OK] Registrando auditoria do Banco de Dados..." -ForegroundColor Yellow
            $DbPath = Join-Path (Get-Location).Path "dataBackup.db"
            $AppUuid = "{AB36F605-6A60-4BBE-84A6-F66F2E0F4FFD}"
            
            $IpLocal = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias 'Ethernet', 'Wi-Fi' -ErrorAction SilentlyContinue).IPAddress | Select-Object -First 1
            if (-not $IpLocal) { $IpLocal = "Desconhecido" }
            
            $DadosSessaoDB = @{
                Hostname = $env:COMPUTERNAME
                OS_Version = [Environment]::OSVersion.VersionString
                Tipo = "Database_MariaDB_MySQL"
                Porta_Conexao = 443
            }
            
            $BlobBytesDB = [System.Text.Encoding]::UTF8.GetBytes(($DadosSessaoDB | ConvertTo-Json -Compress))
            $BlobHexDB = [System.BitConverter]::ToString($BlobBytesDB).Replace("-", "")
            
            $TamanhoArquivoDB = (Get-Item $CaminhoMasterDB).Length
            $TimestampDB = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

            $QueryAuditDB = @"
            INSERT INTO BACKUP_AUDIT (
                uuid_app, cliente, arquivo_nome, versao_guid, 
                checksum_sha256, tamanho_bytes, data_hora_execucao, 
                ip_local, usuario_so, blob_maquina
            ) VALUES (
                @uuid_app, @cliente, @arquivo_nome, @versao_guid, 
                @checksum_sha256, @tamanho_bytes, @data_hora_execucao, 
                @ip_local, @usuario_so, X'$BlobHexDB'
            );
"@
            $SqlParamsDB = @{
                "uuid_app"           = $AppUuid
                "cliente"            = $Config.Cliente
                "arquivo_nome"       = $NomeMasterDB
                "versao_guid"        = $GuidVersaoDB
                "checksum_sha256"    = $ChecksumBase64DB
                "tamanho_bytes"      = $TamanhoArquivoDB
                "data_hora_execucao" = $TimestampDB
                "ip_local"           = $IpLocal
                "usuario_so"         = $env:USERNAME
            }

            Invoke-SqliteQuery -DataSource $DbPath -Query $QueryAuditDB -SqlParameters $SqlParamsDB | Out-Null
            Write-Host "[OK] Auditoria do sistema de Backup salva com sucesso!" -ForegroundColor Green
            Remove-Item -Path $CaminhoMasterDB -Force -ErrorAction SilentlyContinue
        }
    }
    $env:MYSQL_PWD = $null
    if ($BSTRDb) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTRDb) }
    Start-Sleep -Seconds 1
}

$DataHora = Get-Date -Format "yyyyMMdd_HHmmss"
$NomeArquivoRar = "Backup_$($Config.Cliente)_$DataHora.rar"
$CaminhoCompletoRar = Join-Path $Config.CaminhoDestinoTemp $NomeArquivoRar
$ListFilePath = Join-Path $Config.CaminhoDestinoTemp "bkp_lista_$DataHora.txt"
$Config.CaminhosOrigem | Out-File -FilePath $ListFilePath -Encoding UTF8
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

Write-Host "[*] Iniciando compressão com WinRAR de alta performance...`nAGUARDE A CONCLUSÃO COMPLETA...." -ForegroundColor Yellow
Start-Sleep -Seconds 1
$TempoInicio = Get-Date

$Process = Start-Process -FilePath $Config.WinRarPath -ArgumentList $RarArgs -Wait -NoNewWindow -PassThru

$TempoFim = Get-Date
$Duracao = $TempoFim - $TempoInicio

Remove-Item -Path $ListFilePath -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

if ($Process.ExitCode -eq 0) {
    Write-Host "[OK] Compressao concluída com SUCESSO!" -ForegroundColor Green
    Write-Host "[OK] Arquivo gerado: $CaminhoCompletoRar" -ForegroundColor Green
    Write-Host "[OK] Tempo de compressão: $($Duracao.Hours)h $($Duracao.Minutes)m $($Duracao.Seconds)s`n" -ForegroundColor Green
} elseif ($Process.ExitCode -eq 1) {
    Write-Host "[OK] Compressão concluída com AVISOS (Alguns arquivos podem estar em uso e foram pulados)." -ForegroundColor DarkYellow
    Write-Host "[OK] Arquivo gerado: $CaminhoCompletoRar`n" -ForegroundColor DarkYellow
} else {
    throw "[ERROR] ERRO FATAL na compressão. Código de saída do WinRAR: $($Process.ExitCode)"
}
Start-Sleep -Seconds 1
Write-Host "[OK] Processo de compactação finalizado com sucesso... Aguarde..." -ForegroundColor Green
Start-Sleep -Seconds 1
$SenhaRarTexto = $null

Write-Host "[OK] Calculando Checksum (SHA256) do arquivo gerado..." -ForegroundColor Yellow

try {
    $Stream = [System.IO.File]::OpenRead($CaminhoCompletoRar)
    $SHA256 = [System.Security.Cryptography.SHA256]::Create()
    $HashBytes = $SHA256.ComputeHash($Stream)
    $ChecksumHex = [System.BitConverter]::ToString($HashBytes).Replace("-", "").ToLower()
    $ChecksumBase64 = [System.Convert]::ToBase64String($HashBytes)
    Write-Host "Checksum (Hex): $ChecksumHex" -ForegroundColor Green
    Start-Sleep -Seconds 1
    
} catch {
    throw "Falha ao calcular o Checksum do arquivo. Erro: $_"
} finally {
    if ($Stream) { $Stream.Dispose() }
    if ($SHA256) { $SHA256.Dispose() }
}

Write-Host "[OK] Preparando upload para servidor remoto S3" -ForegroundColor Cyan

if (-not (Get-Module -ListAvailable -Name AWS.Tools.S3)) {
    throw "[ERROR] Módulo AWS.Tools.S3 não encontrado. Instale com: Install-Module -Name AWS.Tools.S3 -Force"
}

try {
    $SecureWasabiKey = ConvertTo-SecureString $Config.Credenciais.SecretKeyEncrypted
    $BSTRWasabi = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureWasabiKey)
    $SecretKeyWasabiTexto = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTRWasabi)
} catch {
    throw "[ERROR] Falha ao descriptografar a Secret Key."
} finally {
    if ($BSTRWasabi) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTRWasabi) }
}

$WasabiEndpoint = "https://s3.$($Config.WasabiRegion).wasabisys.com"
Start-Sleep -Seconds 1

$GuidVersao = "{" + [guid]::NewGuid().ToString().ToUpper() + "}"
Write-Host "[OK] Version ID Gerado: $GuidVersao" -ForegroundColor Magenta

$MetadadosS3 = @{
    "cliente" = $Config.Cliente
    "guid-versao" = $GuidVersao
}

Write-Host "[*] Iniciando transferência..." -ForegroundColor Yellow
$TempoInicioUpload = Get-Date
Start-Sleep -Seconds 1

try {
    Write-Host "[*] Transferência em andamento... AGUARDE..." -ForegroundColor Yellow
    Start-Sleep -Seconds 1
    Write-S3Object -BucketName $Config.WasabiBucket `
                   -Key $NomeArquivoRar `
                   -File $CaminhoCompletoRar `
                   -AccessKey $Config.Credenciais.AccessKey `
                   -SecretKey $SecretKeyWasabiTexto `
                   -EndpointUrl $WasabiEndpoint `
                   -Region $Config.WasabiRegion `
                   -Metadata $MetadadosS3 `
                   -ChecksumAlgorithm SHA256 `
                   -StorageClass STANDARD `
                   -ContentType application/vnd.rar `
                   -ErrorAction Stop

    $TempoFimUpload = Get-Date
    $DuracaoUpload = $TempoFimUpload - $TempoInicioUpload
    Start-Sleep -Seconds 1

    Write-Host "[OK] Upload concluído com SUCESSO!" -ForegroundColor Green
    Write-Host "[OK] Tempo de upload: $($DuracaoUpload.Hours)h $($DuracaoUpload.Minutes)m $($DuracaoUpload.Seconds)s`n" -ForegroundColor Green
    Start-Sleep -Seconds 1

} catch {
    throw "Erro crítico durante o upload para a Wasabi: $_"
} finally {
    $SecretKeyWasabiTexto = $null
}

Write-Host "[*] Registrando metadados e log de auditoria no Banco de Dados..." -ForegroundColor Cyan
$DbPath = Join-Path (Get-Location).Path "dataBackup.db"

$Pragmas = @"
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;
PRAGMA automatic_index = ON;
PRAGMA user_version = 1;
"@
Invoke-SqliteQuery -DataSource $DbPath -Query $Pragmas | Out-Null

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

$AppUuid = "{73C8CDF8-C8A6-45A3-8B8E-A62085661CF1}"
$AppVersion = "v1.0.2"
$AppUserVersion = "v1.0.2"
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

Start-Sleep -Seconds 1
Invoke-SqliteQuery -DataSource $DbPath -Query $QueryInsertAudit -SqlParameters $SqlParams | Out-Null
Write-Host "[OK] Log de auditoria gravado no banco de dados local com SUCESSO!`n" -ForegroundColor Green
Start-Sleep -Seconds 1

if (Test-Path $CaminhoCompletoRar) {
    Remove-Item -Path $CaminhoCompletoRar -Force
    Write-Host "Limpeza: Arquivo local '$NomeArquivoRar' removido com sucesso.`n" -ForegroundColor DarkGray
    Write-Host "Limpeza: Artefatos na memoria e chaves removidos com sucesso.`n" -ForegroundColor DarkGray
    Start-Sleep -Seconds 1
}
Start-Sleep -Seconds 1
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "[OK] Rotina de Backup FINALIZADA COM SUCESSO!" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan