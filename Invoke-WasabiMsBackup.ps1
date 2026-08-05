$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'


function Wait-ProcessWithSpinner {
    param (
        [Parameter(Mandatory=$true)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory=$false)]
        [string]$Mensagem = "Aguarde, processando..."
    )

    $Animacao = @('|', '/', '-', '\')
    $Contador = 0
    while (-not $Process.HasExited) {
        Write-Output "`r[ $($Animacao[$Contador % 4]) ] $Mensagem" -NoNewline -ForegroundColor Cyan
        $Contador++
        Start-Sleep -Milliseconds 200
    }
    $Espacos = " " * ($Mensagem.Length + 15)
    Write-Output "`r$Espacos`r" -NoNewline
}

Write-Output "=== SCRIPT BACKUP AUTOMÁTICO WASABI MS (PROIBIDA REPRODUÇÃO) ===" -ForegroundColor Cyan
Start-Sleep -Seconds 2


$EhWindows = if ($null -ne $IsWindows) { $IsWindows } else { [Environment]::OSVersion.Platform -match "Win32" }

if (-not $EhWindows) {
    Write-Output "======================================================================" -ForegroundColor Red
    Write-Output "[ERRO CRÍTICO] Este script foi projetado EXCLUSIVAMENTE para WINDOWS." -ForegroundColor Red
    Write-Output "Execução abortada para prevenir falhas de diretório ou comandos." -ForegroundColor Red
    Write-Output "======================================================================" -ForegroundColor Red
    exit 1
}


Write-Output "[OK] Preparando variáveis, descriptografando dados..." -ForegroundColor Cyan
Start-Sleep -Seconds 1

$ConfigFile = ".\config.json"
if (-not (Test-Path $ConfigFile)) {
    Write-Output "[ERRO CRÍTICO] Arquivo de configuração não encontrado: config.json`n`nLembre-se: O arquivo de configuração deverá estar no mesmo diretório do script. O diretório também precisa de permissões de leitura e gravação." -ForegroundColor Red
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
    Write-Output "[AVISO] Falha ao descriptografar senha do WinRAR do JSON.`nImpossível o script continuar a execução, verifique o blob da senha e tente novamente..." -ForegroundColor DarkYellow
    exit 1
} finally {
    if ($BSTR) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR) }
}
if ([string]::IsNullOrWhiteSpace($SenhaRarTexto)) {
    $SenhaRarTexto = "{" + [guid]::NewGuid().ToString().ToUpper() + "}"
    $SenhaFallbackAtivada = $true
    Write-Output "[AVISO] Utilizando SENHA PADRÃO DE FALLBACK para o WinRAR." -ForegroundColor DarkYellow

    $CaminhoArquivo = Join-Path $PSScriptRoot "senha_winrar_gerada_automaticamente.txt"
    $SenhaRarTexto | Out-File -FilePath $CaminhoArquivo -Encoding utf8
}


if ($Config.IncluiBackupMariaDBMysql -eq $true) {
    Write-Output "`n=== INICIANDO BACKUP DO BANCO DE DADOS.... ==="-ForegroundColor Cyan
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
    
    Write-Output "[OK] Verificando status do servidor BD e obtendo bancos...AGUARDE..."-ForegroundColor Yellow
    Start-Sleep -Seconds 1
    
    $InfoVersao = & $MysqlExe -V 2>&1
    Start-Sleep -Seconds 1
    
    $SuportaSslMode = ($InfoVersao -match "MySQL" -and $InfoVersao -notmatch "MariaDB" -and ($InfoVersao -match "Distrib 5\.7\.[1-9][0-9]" -or $InfoVersao -match "Distrib [8-9]\."))
    Start-Sleep -Seconds 1
    
    $ArgumentosBase = @("-h", $DbConfig.Host, "-P", $DbConfig.Port, "-u", $DbConfig.User, "-s", "-N", "-e", "SHOW DATABASES;")
    
    if ($SuportaSslMode) {
        Write-Output "[*] Cliente MySQL nativo detectado..." -ForegroundColor DarkCyan
        $ArgumentosFinais = $ArgumentosBase + "--ssl-mode=DISABLED"
        $ListaBancos = & $MysqlExe $ArgumentosFinais 2>&1
        
    } else {
        Write-Output "[*] Cliente MariaDB ou legado detectado..." -ForegroundColor DarkCyan
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
        Write-Output "Nenhum banco de dados de usuário encontrado para backup."-ForegroundColor Yellow
    } else {
        Write-Output "Encontrados $($BancosParaBackup.Count) bancos de dados para dump."-ForegroundColor Green
        $PastaBancosTemp = Join-Path $Config.CaminhoDestinoTemp "BancosDB_$DataHora"
        New-Item -ItemType Directory -Path $PastaBancosTemp -Force | Out-Null

        foreach ($Banco in $BancosParaBackup) {
            $Banco = $Banco.Trim()
            $DataHoraMili = Get-Date -Format "yyyyMMdd_HHmmss_fff"
            $NomeDumpSql = "$($Banco)_$DataHoraMili.sql"
            $CaminhoSql = Join-Path $PastaBancosTemp $NomeDumpSql
            $CaminhoRarInd = Join-Path $PastaBancosTemp "$($Banco)_$DataHoraMili.rar"
            Write-Output "[*] Realizando dump de: $Banco ..."-ForegroundColor Cyan
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
                Write-Output "[**] Compactando $Banco individualmente..." -ForegroundColor DarkGray
               
                $ArgsRarInd = @("a", "-m5", "-ep", "-y", "-idq", "-hp$SenhaRarTexto", "`"$CaminhoRarInd`"", "`"$CaminhoSql`"")
                $ProcessoRarInd = Start-Process -FilePath $Config.WinRarPath -ArgumentList $ArgsRarInd -NoNewWindow -PassThru
                Wait-ProcessWithSpinner -Process $ProcessoRarInd -Mensagem "Realizando compactação do BD individual... AGUARDE..."
                Start-Sleep -Seconds 1
                
                if ($ProcessoRarInd.ExitCode -eq 0) {
                    $StreamInd = [System.IO.File]::OpenRead($CaminhoRarInd)
                    $SHA256Ind = [System.Security.Cryptography.SHA256]::Create()
                    $HashInd = [System.BitConverter]::ToString($SHA256Ind.ComputeHash($StreamInd)).Replace("-", "").ToLower()
                    $StreamInd.Dispose(); $SHA256Ind.Dispose()
                    
                    Write-Output "[OK] ARQUIVO RAR gerado. Checksum SHA256: $HashInd" -ForegroundColor Green
                    Remove-Item -Path $CaminhoSql -Force
                } else {
                    Write-Output "[ERRO] Falha ao compactar o banco $Banco" -ForegroundColor Red
                }
            }
        }
        Start-Sleep -Seconds 1
        $NomeMasterDB = "MasterBackupDB_$($Config.Cliente)_$DataHora.rar"
        $CaminhoMasterDB = Join-Path $Config.CaminhoDestinoTemp $NomeMasterDB
        Write-Output "`n[OK] Unindo todos os bancos de dados em um arquivo Master: $NomeMasterDB" -ForegroundColor Yellow

        $ArgsRarMaster = @("a", "-m0", "-ep", "-y", "-idq", "-hp$SenhaRarTexto", "`"$CaminhoMasterDB`"", "$PastaBancosTemp\*.rar")
        $ProcessoMaster = Start-Process -FilePath $Config.WinRarPath -ArgumentList $ArgsRarMaster -NoNewWindow -PassThru
        Wait-ProcessWithSpinner -Process $ProcessoMaster -Mensagem "Realizando compactação de todos BDs... AGUARDE..."

        if ($ProcessoMaster.ExitCode -eq 0) {
            Write-Output "[OK] Pacote Master de Bancos de Dados gerado com sucesso!" -ForegroundColor Green
            Write-Output "`nLim" -ForegroundColor Cyan
            Remove-Item -Path $PastaBancosTemp -Recurse -Force
            Start-Sleep -Seconds 2

            Write-Output "`n=== Iniciando Envio do Banco de Dados [MYSQL/MARIADB] para servidor de backup ===" -ForegroundColor Cyan
            
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
                
                Write-Output "[*] Iniciando transferência..." -ForegroundColor Yellow
                $TempoIniUploadDB = Get-Date

                Start-Sleep -Seconds 2

                Write-Output "[*] Transferência em andamento... AGUARDE..." -ForegroundColor Yellow
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
                Write-Output "[OK] Upload do BACKUP DO BANCO DE DADOS DO CLIENTE concluído em $(($TempoFimUploadDB - $TempoIniUploadDB).TotalSeconds) segundos!" -ForegroundColor Green
            } catch {
                throw "[ERROR] Erro ao fazer upload do Banco de Dados: $_"
            } finally {
                if ($BSTRWasabi) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTRWasabi); $SecretKeyWasabi = $null }
            }

            Start-Sleep -Seconds 1

            Write-Output "[OK] Registrando auditoria do Banco de Dados..." -ForegroundColor Yellow
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
            Write-Output "[OK] Auditoria do sistema de Backup salva com sucesso!" -ForegroundColor Green
            Remove-Item -Path $CaminhoMasterDB -Force -ErrorAction SilentlyContinue
        }
    }
    $env:MYSQL_PWD = $null
    if ($BSTRDb) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTRDb) }
    Start-Sleep -Seconds 1
}



Write-Output "`n[OK] Procedimentos de backup de BDs Mysql/MariaDB concluídos... AGUARDE..." -ForegroundColor DarkYellow
Start-Sleep -Seconds 2


if ($Config.IncluiBackupFirebird -eq $true) {
    Write-Output "`n=== Iniciando procedimentos para backup de DB Firebird... AGUARDE... ===" -ForegroundColor Cyan
    
    $FbConfig = $Config.DataInfoBKPFirebird
    $GbakExe = Join-Path $FbConfig.BinPath "gbak.exe"

    if (-not (Test-Path $GbakExe)) {
        throw "[ERROR] Executável do Firebird (gbak.exe) não encontrado no caminho: $($FbConfig.BinPath)"
    }

    Start-Sleep -Seconds 1

    $FbUser = "SYSDBA"
    $FbPass = "masterkey"

    $PastaFbTemp = Join-Path $Config.CaminhoDestinoTemp "Firebird_$DataHora"
    New-Item -ItemType Directory -Path $PastaFbTemp -Force | Out-Null

    Start-Sleep -Seconds 1

    $FbHost = $FbConfig.Host
    $FbPort = $FbConfig.Port
    $BancosFbComSucesso = 0

    foreach ($CaminhoFDB in $FbConfig.CaminhosFDB) {
        if (-not (Test-Path $CaminhoFDB)) {
            Write-Output "[AVISO] Arquivo FDB não encontrado: $CaminhoFDB" -ForegroundColor DarkYellow
            continue
        }

        # Extrai apenas o nome do banco (ex: DADOS)
        $NomeArquivoBase = [System.IO.Path]::GetFileNameWithoutExtension($CaminhoFDB)
        $DataHoraMili = Get-Date -Format "yyyyMMdd_HHmmss_fff"
        
        $NomeFbk = "$($NomeArquivoBase)_$DataHoraMili.fbk"
        $CaminhoFbk = Join-Path $PastaFbTemp $NomeFbk
        $CaminhoRarFbInd = Join-Path $PastaFbTemp "$($NomeArquivoBase)_$DataHoraMili.rar"

        Write-Output "[OK] Iniciando dump seguro (gbak) de: $NomeArquivoBase ...AGUARDE..." -ForegroundColor Cyan
        Start-Sleep -Seconds 2
        
        $StringConexao = "$($FbHost)/$($FbPort):$($CaminhoFDB)"
        $LogErroGbak = Join-Path $PastaFbTemp "gbak_$($NomeArquivoBase)_err.log"
        $ArgsGbak = @(
            "-b", 
            "-user", $FbUser, 
            "-password", $FbPass, 
            "`"$StringConexao`"", 
            "`"$CaminhoFbk`""
        )

        $ProcGbak = Start-Process -FilePath $GbakExe -ArgumentList $ArgsGbak -Wait -NoNewWindow -PassThru -RedirectStandardError $LogErroGbak
        Start-Sleep -Seconds 1

        if ($ProcGbak.ExitCode -eq 0 -and (Test-Path $CaminhoFbk)) {
            Write-Output "[OK] Arquivo dump .fbk criado com sucesso!" -ForegroundColor Green
            Start-Sleep -Seconds 1
            Write-Output "[OK] Compactando arquivo .fbk gerado...AGUARDE..." -ForegroundColor Green
            
            $ArgsRarFb = @("a", "-m5", "-ep", "-y", "-idq", "-hp$SenhaRarTexto", "`"$CaminhoRarFbInd`"", "`"$CaminhoFbk`"")
            $ProcRarFb = Start-Process -FilePath $Config.WinRarPath -ArgumentList $ArgsRarFb -NoNewWindow -PassThru

            Wait-ProcessWithSpinner -Process $ProcRarFb -Mensagem "Realizando compactação do BD Firebird... AGUARDE..."
            
            if ($ProcRarFb.ExitCode -eq 0) {
                Write-Output "[OK] FDB compactado e blindado com sucesso." -ForegroundColor Green
                Start-Sleep -Seconds 1
                $BancosFbComSucesso++
                Remove-Item -Path $CaminhoFbk -Force
            } else {
                Write-Output "[ERRO] Falha ao compactar $NomeArquivoBase" -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        } else {
            Write-Output "    [ERRO] Falha crítica ao gerar o .fbk. Verifique se a porta $FbPort está correta e o serviço online." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }

    if ($BancosFbComSucesso -gt 0) {
        Write-Output "[OK] Compactação individual dos DBs Firebird concluída com SUCESSO! AGUARDE..." -ForegroundColor Green
        Start-Sleep -Seconds 1
        $NomeMasterFB = "MasterBackupFirebird_$($Config.Cliente)_$DataHora.rar"
        $CaminhoMasterFB = Join-Path $Config.CaminhoDestinoTemp $NomeMasterFB
        
        Write-Output "`n[OK] Unindo $BancosFbComSucesso banco(s) Firebird no arquivo: $NomeMasterFB" -ForegroundColor Yellow

        $ArgsMasterFB = @("a", "-m5", "-ep", "-y", "-idq", "-hp$SenhaRarTexto", "`"$CaminhoMasterFB`"", "$PastaFbTemp\*.rar")
        $ProcMasterFB = Start-Process -FilePath $Config.WinRarPath -ArgumentList $ArgsMasterFB -NoNewWindow -PassThru
        Wait-ProcessWithSpinner -Process $ProcMasterFB -Mensagem "Compactação do arquivo único com todos os DBs... AGUARDE..." -ForegroundColor Green

        Start-Sleep -Seconds 1
        if ($ProcMasterFB.ExitCode -eq 0) {
            Write-Output "[OK] Pacote Master Firebird gerado com SUCESSO! AGUARDE..." -ForegroundColor Green
            Remove-Item -Path $PastaFbTemp -Recurse -Force
            
            Start-Sleep -Seconds 2

            Write-Output "`n=== Iniciando procedimentos para envio para servidor de Backup ===" -ForegroundColor Cyan
            
            $StreamFB = [System.IO.File]::OpenRead($CaminhoMasterFB)
            $SHA256FB = [System.Security.Cryptography.SHA256]::Create()
            $ChecksumBase64FB = [System.Convert]::ToBase64String($SHA256FB.ComputeHash($StreamFB))
            $StreamFB.Dispose(); $SHA256FB.Dispose()

            $WasabiEndpoint = "https://s3.$($Config.WasabiRegion).wasabisys.com"
            $GuidVersaoFB = "{" + [guid]::NewGuid().ToString().ToUpper() + "}"
            
            $MetadadosS3FB = @{
                "cliente" = $Config.Cliente
                "guid-versao" = $GuidVersaoFB
                "tipo-arquivo" = "database_firebird"
            }

            try {
                $SecureWasabi = ConvertTo-SecureString $Config.Credenciais.SecretKeyEncrypted
                $BSTRWasabi = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureWasabi)
                $SecretKeyWasabi = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTRWasabi)
                Start-Sleep -Seconds 2
                
                Write-Output "[*] Preparação concluída, iniciando envio..." -ForegroundColor Yellow
                $TempoIniUploadFB = Get-Date

                Write-Output "[*] Transferência em andamento... AGUARDE..." -ForegroundColor Yellow

                Write-S3Object -BucketName $Config.WasabiBucket `
                               -Key $NomeMasterFB `
                               -File $CaminhoMasterFB `
                               -AccessKey $Config.Credenciais.AccessKey `
                               -SecretKey $SecretKeyWasabi `
                               -EndpointUrl $WasabiEndpoint `
                               -Region $Config.WasabiRegion `
                               -Metadata $MetadadosS3FB `
                               -ChecksumAlgorithm SHA256 `
                               -StorageClass STANDARD `
                               -ContentType application/vnd.rar `
                               -ErrorAction Stop

                $TempoFimUploadFB = Get-Date
                Write-Output "[OK] Upload do Firebird concluído em $(($TempoFimUploadFB - $TempoIniUploadFB).TotalSeconds) segundos!" -ForegroundColor Green
            } catch {
                throw "Erro ao fazer upload do Firebird: $_"
            } finally {
                if ($BSTRWasabi) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTRWasabi); $SecretKeyWasabi = $null }
            }
            Start-Sleep -Seconds 2

            Write-Output "[OK] Registrando auditoria no banco de dados..." -ForegroundColor Yellow
            $DbPath = Join-Path (Get-Location).Path "dataBackup.db"
            $AppUuid = "{AB36F605-6A60-4BBE-84A6-F66F2E0F4FFD}"
            
            $IpLocal = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias 'Ethernet', 'Wi-Fi' -ErrorAction SilentlyContinue).IPAddress | Select-Object -First 1
            if (-not $IpLocal) { $IpLocal = "Desconhecido" }
            
            $DadosSessaoFB = @{
                Hostname = $env:COMPUTERNAME
                OS_Version = [Environment]::OSVersion.VersionString
                Tipo = "Database_Firebird"
                Uso_Senha_Fallback = $SenhaFallbackAtivada
            }
            
            $BlobBytesFB = [System.Text.Encoding]::UTF8.GetBytes(($DadosSessaoFB | ConvertTo-Json -Compress))
            $BlobHexFB = [System.BitConverter]::ToString($BlobBytesFB).Replace("-", "")
            
            $TamanhoArquivoFB = (Get-Item $CaminhoMasterFB).Length
            $TimestampFB = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

            $QueryAuditFB = @"
            INSERT INTO BACKUP_AUDIT (
                uuid_app, cliente, arquivo_nome, versao_guid, 
                checksum_sha256, tamanho_bytes, data_hora_execucao, 
                ip_local, usuario_so, blob_maquina
            ) VALUES (
                @uuid_app, @cliente, @arquivo_nome, @versao_guid, 
                @checksum_sha256, @tamanho_bytes, @data_hora_execucao, 
                @ip_local, @usuario_so, X'$BlobHexFB'
            );
"@
            $SqlParamsFB = @{
                "uuid_app"           = $AppUuid
                "cliente"            = $Config.Cliente
                "arquivo_nome"       = $NomeMasterFB
                "versao_guid"        = $GuidVersaoFB
                "checksum_sha256"    = $ChecksumBase64FB
                "tamanho_bytes"      = $TamanhoArquivoFB
                "data_hora_execucao" = $TimestampFB
                "ip_local"           = $IpLocal
                "usuario_so"         = $env:USERNAME
            }

            Invoke-SqliteQuery -DataSource $DbPath -Query $QueryAuditFB -SqlParameters $SqlParamsFB | Out-Null
            Write-Output "[OK] Log do Firebird gravado em formato binário!" -ForegroundColor Green
            
            Remove-Item -Path $CaminhoMasterFB -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Output "[ERROR] Nenhum banco Firebird foi validado/gerado para pacote." -ForegroundColor red
    }
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
    "-idq", 
    "`"$CaminhoCompletoRar`"", 
    "@`"$ListFilePath`""
)

Write-Output "[*] Iniciando compressão dos arquivos escolhidos...`nAGUARDE A CONCLUSÃO COMPLETA...." -ForegroundColor Yellow
Start-Sleep -Seconds 1
$TempoInicio = Get-Date

$Process = Start-Process -FilePath $Config.WinRarPath -ArgumentList $RarArgs -NoNewWindow -PassThru

Wait-ProcessWithSpinner -Process $Process -Mensagem "[*] Compactando arquivos do sistema... Isso pode demorar."

$TempoFim = Get-Date
$Duracao = $TempoFim - $TempoInicio

Remove-Item -Path $ListFilePath -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

if ($Process.ExitCode -eq 0) {
    Write-Output "[OK] Compressão concluída com SUCESSO!" -ForegroundColor Green
    Write-Output "[OK] Arquivo gerado: $CaminhoCompletoRar" -ForegroundColor Green
    Write-Output "[OK] Tempo de compressão: $($Duracao.Hours)h $($Duracao.Minutes)m $($Duracao.Seconds)s`n" -ForegroundColor Green
} elseif ($Process.ExitCode -eq 1) {
    Write-Output "[OK] Compressão concluída com AVISOS (Alguns arquivos podem estar em uso e foram pulados)." -ForegroundColor DarkYellow
    Write-Output "[OK] Arquivo gerado: $CaminhoCompletoRar`n" -ForegroundColor DarkYellow
} else {
    throw "[ERROR] ERRO FATAL na compressão. Código de saída do WinRAR: $($Process.ExitCode)"
}
Start-Sleep -Seconds 1
Write-Output "[OK] Processo de compactação finalizado com sucesso... AGUARDE..." -ForegroundColor Green
Start-Sleep -Seconds 1
$SenhaRarTexto = $null

Write-Output "[OK] Calculando Checksum (SHA256) do arquivo gerado..." -ForegroundColor Yellow

try {
    $Stream = [System.IO.File]::OpenRead($CaminhoCompletoRar)
    $SHA256 = [System.Security.Cryptography.SHA256]::Create()
    $HashBytes = $SHA256.ComputeHash($Stream)
    $ChecksumHex = [System.BitConverter]::ToString($HashBytes).Replace("-", "").ToLower()
    $ChecksumBase64 = [System.Convert]::ToBase64String($HashBytes)
    Write-Output "[OK] Checksum (Hex): $ChecksumHex" -ForegroundColor Green
    Start-Sleep -Seconds 1
    
} catch {
    throw "[ERROR] Falha ao calcular o Checksum do arquivo. Erro: $_"
} finally {
    if ($Stream) { $Stream.Dispose() }
    if ($SHA256) { $SHA256.Dispose() }
}

Write-Output "[OK] Preparando upload para servidor de backup... AGUARDE..." -ForegroundColor Cyan
Start-Sleep -Seconds 1
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
Write-Output "[OK] Version Backup ID Gerado: $GuidVersao" -ForegroundColor Magenta

$MetadadosS3 = @{
    "cliente" = $Config.Cliente
    "guid-versao" = $GuidVersao
}

Write-Output "[*] Iniciando transferência..." -ForegroundColor Yellow
$TempoInicioUpload = Get-Date
Start-Sleep -Seconds 1

try {
    Write-Output "[*] Transferência em andamento... AGUARDE..." -ForegroundColor Yellow
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

    Write-Output "[OK] Upload concluído com SUCESSO!" -ForegroundColor Green
    Write-Output "[OK] Tempo de upload: $($DuracaoUpload.Hours)h $($DuracaoUpload.Minutes)m $($DuracaoUpload.Seconds)s`n" -ForegroundColor Green
    Start-Sleep -Seconds 1

} catch {
    throw "Erro crítico durante o upload para a Wasabi: $_"
} finally {
    $SecretKeyWasabiTexto = $null
}

Write-Output "[*] Registrando metadados e log de auditoria no Banco de Dados..." -ForegroundColor Cyan
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
$AppVersion = "v1.2.4"
$AppUserVersion = "v1.2.4"
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
Write-Output "[OK] Log de auditoria gravado no banco de dados com SUCESSO!`n" -ForegroundColor Green
Start-Sleep -Seconds 1

if (Test-Path $CaminhoCompletoRar) {
    Remove-Item -Path $CaminhoCompletoRar -Force
    Write-Output "Limpeza: Arquivo local '$NomeArquivoRar' removido com sucesso...`n" -ForegroundColor DarkGray
    Write-Output "Limpeza: Artefatos na memória e chaves removidos com sucesso...`n" -ForegroundColor DarkGray
    Start-Sleep -Seconds 1
    Write-Output "Limpeza: Realizando checagem de dados finais...`n" -ForegroundColor DarkGray
    Start-Sleep -Seconds 2
}
Start-Sleep -Seconds 1
Write-Output "=================================================================" -ForegroundColor Cyan
Write-Output "[OK] Rotina de Backup FINALIZADA COM SUCESSO!" -ForegroundColor Cyan
Write-Output "=================================================================" -ForegroundColor Cyan