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
        Write-Host "`r[ $($Animacao[$Contador % 4]) ]$Mensagem" -NoNewline -ForegroundColor Cyan
        $Contador++
        Start-Sleep -Milliseconds 200
    }
    $Process.WaitForExit()

    $Espacos = " " * ($Mensagem.Length + 15)
    Write-Host "`r$Espacos`r" -NoNewline
}
function Convert-ToUrlSlug {
    param (
        [string]$TextoEntrada
    )

    if ([string]::IsNullOrWhiteSpace($TextoEntrada)) {
        return ""
    }
    $Resultado = $TextoEntrada.ToLower()
    $Bytes = [System.Text.Encoding]::GetEncoding("Cyrillic").GetBytes($Resultado)
    $Resultado = [System.Text.Encoding]::ASCII.GetString($Bytes)
    $Resultado = $Resultado -replace '[^a-z0-9]', '-'

    return $Resultado
}

Write-Host "=== SCRIPT BACKUP AUTOMÁTICO WASABI MS (PROIBIDA REPRODUÇÃO) ===" -ForegroundColor Cyan
Start-Sleep -Seconds 2


$EhWindows = if ($null -ne $IsWindows) { $IsWindows } else { [Environment]::OSVersion.Platform -match "Win32" }

if (-not $EhWindows) {
    Write-Host "======================================================================" -ForegroundColor Red
    Write-Host "[ERRO CR�TICO] Este script foi projetado EXCLUSIVAMENTE para WINDOWS." -ForegroundColor Red
    Write-Host "Execu��o abortada para prevenir falhas de diretório ou comandos." -ForegroundColor Red
    Write-Host "======================================================================" -ForegroundColor Red
    exit 1
}


Write-Host "[OK] Preparando variáveis, descriptografando dados..." -ForegroundColor Cyan
Start-Sleep -Seconds 1


$DataHoraMili = Get-Date -Format "yyyyMMdd_HHmmss_fff"
$ConfigFile = ".\config.json"
if (-not (Test-Path $ConfigFile)) {
    Write-Host "[ERRO CR�TICO] Arquivo de configura��o n�o encontrado: config.json`n`nLembre-se: O arquivo de configuração deverá estar no mesmo diret�rio do script. O diretório também precisa de permissões de leitura e gravação." -ForegroundColor Red
    exit 1
}
$Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
Start-Sleep -Seconds 1

if (-not (Test-Path $Config.CaminhoDestinoTemp)) {
    New-Item -ItemType Directory -Path $Config.CaminhoDestinoTemp -Force | Out-Null
}

$PastaLogs = Join-Path $PSScriptRoot "logs"

if (-not (Test-Path $PastaLogs)) { 
    New-Item -ItemType Directory -Path $PastaLogs -Force | Out-Null 
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
    Write-Host "`n=== INICIANDO BACKUP DO BANCO DE DADOS [MARIADB/MYSQL].... ===" -ForegroundColor Cyan
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
    
    Write-Host "[OK] Verificando status do servidor BD e obtendo bancos...AGUARDE..."-ForegroundColor Yellow
    Start-Sleep -Seconds 1
    
    $InfoVersao = & $MysqlExe -V 2>&1
    $InfoVersaoString = $InfoVersao -join " "
    Start-Sleep -Seconds 1
    
    $IsMariaDB = $InfoVersaoString -match "MariaDB"
    $IsModernMySQL = $InfoVersaoString -match "(Ver|Distrib)\s+(5\.7|[8-9]\.)"
    
    $SuportaSslMode = (-not $IsMariaDB) -and $IsModernMySQL
    Start-Sleep -Seconds 1
    
    $ArgumentosBase = @("-h", $DbConfig.Host, "-P", $DbConfig.Port, "-u", $DbConfig.User, "-s", "-N", "-e", "SHOW DATABASES;")
    
    if ($SuportaSslMode) {
        Write-Host "[*] Cliente MySQL nativo detectado..." -ForegroundColor DarkCyan
        $ArgumentosFinais = $ArgumentosBase + "--ssl-mode=DISABLED"
        $ListaBancos = $(& $MysqlExe $ArgumentosFinais 2>&1) | Where-Object { 
            $_ -notmatch "Warning" -and -not ([string]::IsNullOrWhiteSpace($_))
        }
        
    } else {
        Write-Host "[*] Cliente MariaDB ou legado detectado..." -ForegroundColor DarkCyan
        $ArgumentosMariaDB = $ArgumentosBase + "--skip-ssl"
        $ListaBancos = $(& $MysqlExe $ArgumentosMariaDB 2>&1) | Where-Object { 
            $_ -notmatch "Warning" -and -not ([string]::IsNullOrWhiteSpace($_))
        }
    }

    Start-Sleep -Seconds 1

    if ($LASTEXITCODE -ne 0) {
        $env:MYSQL_PWD = $null
        throw "[ERROR] Erro Critico: Falha ao conectar no BD. Verifique se esta online e se as credenciais tem permissão. Detalhes: $ListaBancos"
    }

    $BancosSistema = @("information_schema", "mysql", "performance_schema", "sys")
    $BancosParaBackup = $ListaBancos -split "`n" | Where-Object { $_.Trim() -notin $BancosSistema -and $_.Trim() -ne "" }
    Start-Sleep -Seconds 1

    if ($BancosParaBackup.Count -eq 0) {
        Write-Host "[PASS] Nenhum banco de dados de usuário encontrado para backup." -ForegroundColor Yellow
    } else {
        $DataHoraMili = Get-Date -Format "yyyyMMdd_HHmmss_fff"
        Write-Host "[OK] Encontrados $($BancosParaBackup.Count) bancos de dados para dump." -ForegroundColor Green
        $PastaBancosTemp = Join-Path $Config.CaminhoDestinoTemp "BancosDB_$DataHoraMili"
        New-Item -ItemType Directory -Path $PastaBancosTemp -Force | Out-Null

        foreach ($Banco in $BancosParaBackup) {
            #$nm_bd_sanitizado = Convert-ToUrlSlug -TextoEntrada $Banco
            $nm_bd_sanitizado = $Banco
            $NomeDumpSql = "$($nm_bd_sanitizado)_$DataHoraMili.sql"
            $CaminhoSql = Join-Path $PastaBancosTemp $NomeDumpSql
            $CaminhoRarInd = Join-Path $PastaBancosTemp "$($nm_bd_sanitizado)_$DataHoraMili.rar"
            Write-Host "[*] Realizando dump de: $Banco ... AGUARDE..." -ForegroundColor Cyan

            $ArgumentosDump = @(
                "-h", $DbConfig.Host, 
                "-P", $DbConfig.Port, 
                "-u", $DbConfig.User, 
                "--single-transaction", 
                "--routines", 
                "--triggers"
            )

            if ($SuportaSslMode) {
                $ArgumentosDump += "--ssl-mode=DISABLED"
            } else {
                $ArgumentosDump += "--skip-ssl"
            }

            $ArgumentosDump += $Banco
            $ArgumentosDump += "--result-file=`"$CaminhoSql`""

            $CaminhoLogRedirDumpInd = Join-Path $PastaLogs "\Logs_Process_SQLDUMP_BDs_ind.txt"
            $CaminhoLogErrDumpInd = Join-Path $PastaLogs "\Logs_Errors_Process_SQLDUMP_BDs_ind.txt"

            $ProcessoMysqlDump = Start-Process -FilePath $MysqldumpExe -ArgumentList $ArgumentosDump -RedirectStandardOutput $CaminhoLogRedirDumpInd -RedirectStandardError $CaminhoLogErrDumpInd -Wait -NoNewWindow -PassThru
            Start-Sleep -Seconds 8

            if (Test-Path $CaminhoSql) {
                Write-Host "[OK] Dump do banco de dados realizado com sucesso!" -ForegroundColor Green
                Start-Sleep -Seconds 2
                Write-Host "[*] Iniciando compactação do Banco de Dados individual..." -ForegroundColor DarkGray

                $ArgsRarInd = "a -m5 -ep -y -idq -df `"$CaminhoRarInd`" `"$CaminhoSql`""

                Start-Sleep -Seconds 1
                $TempoInicio = Get-Date

                $CaminhoLogRedirInd = Join-Path $PastaLogs "\Logs_Process_Compactacao_BDs_ind.txt"
                $CaminhoLogErrInd = Join-Path $PastaLogs "\Logs_Errors_Process_Compactacao_BDs_ind.txt"

                $ProcessoRarInd = Start-Process -FilePath $Config.WinRarPath -ArgumentList $ArgsRarInd -RedirectStandardOutput $CaminhoLogRedirInd -RedirectStandardError $CaminhoLogErrInd -Wait -NoNewWindow -PassThru
               
                #$ArgsRarInd = "a -m5 -ep -y -idq `"-hp$SenhaRarTexto`" `"$CaminhoRarInd`" `"$CaminhoSql`""
                #$ProcessoRarInd = Start-Process -FilePath $Config.WinRarPath -ArgumentList $ArgsRarInd -NoNewWindow -PassThru
                #Wait-ProcessWithSpinner -Process $ProcessoRarInd -Mensagem "Compactação do Banco de Dados (Dump) individual em andamento... AGUARDE..."
                Start-Sleep -Seconds 2
                if ($ProcessoRarInd.ExitCode -eq 0) {
                    $StreamInd = [System.IO.File]::OpenRead($CaminhoRarInd)
                    $SHA256Ind = [System.Security.Cryptography.SHA256]::Create()
                    $HashInd = [System.BitConverter]::ToString($SHA256Ind.ComputeHash($StreamInd)).Replace("-", "").ToLower()
                    $StreamInd.Dispose(); $SHA256Ind.Dispose()
                    
                    Write-Host "[OK] ARQUIVO RAR gerado com sucesso! Checksum SHA256: $HashInd" -ForegroundColor Green
                } else {
                    Write-Host "[ERRO] Falha ao compactar o banco $Banco. (C�digo do Erro: $($ProcessoRarInd.ExitCode))" -ForegroundColor Red
                    exit 1
                }
            }
        }
        Start-Sleep -Seconds 1
        $NomeMasterDB = "MasterBackupDB_$($Config.Cliente)_$DataHoraMili.rar"
        $CaminhoMasterDB = Join-Path $Config.CaminhoDestinoTemp $NomeMasterDB
        Write-Host "`n[OK] Unindo todos os bancos de dados em um arquivo Master: $NomeMasterDB" -ForegroundColor Yellow

        $ArgsRarMaster = "a -m5 -ep -y -idq -df `"-hp$SenhaRarTexto`" `"$CaminhoMasterDB`" `"$PastaBancosTemp\*.rar`""
        $ProcessoMaster = Start-Process -FilePath $Config.WinRarPath -ArgumentList $ArgsRarMaster -NoNewWindow -PassThru
        Wait-ProcessWithSpinner -Process $ProcessoMaster -Mensagem "Realizando compactação de todos BDs em um único arquivo... AGUARDE..."

        if ($ProcessoMaster.ExitCode -eq 0) {
            Write-Host "[OK] Pacote Master de Bancos de Dados gerado com sucesso!" -ForegroundColor Green
            Write-Host "`nLim" -ForegroundColor Cyan
            Remove-Item -Path $PastaBancosTemp -Recurse -Force
            Start-Sleep -Seconds 2

            Write-Host "[*] Iniciando Envio do Banco de Dados [MYSQL/MARIADB] para servidor de backup..." -ForegroundColor Cyan
            
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
                Write-Host "[ERROR] Erro ao fazer upload do Banco de Dados: $_" -ForegroundColor Red
                Write-Host "[ERROR] Verifique se a Chave Secreta do Servidor de Backup está encriptada e corretamente inserida no arquivo config.json, remova espaços vazios e caracteres especiais se houver. Verifique se configurou corretamente as devidas permissões necessárias ao usuário criado para este perfil de backup." -ForegroundColor Red
                Write-Host "[ERROR] Script encerrado." -ForegroundColor Red
                exit 1
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

    Write-Host "`n[OK] Procedimentos de backup de BDs Mysql/MariaDB concluídos... AGUARDE..." -ForegroundColor DarkYellow
    Start-Sleep -Seconds 2
} else {
    Write-Host "`n=== IGNORANDO BACKUP DO BANCO DE DADOS [MARIADB/MYSQL].... ===" -ForegroundColor Cyan
    Start-Sleep -Seconds 2
    Write-Host "`n[OK] AGUARDE..." -ForegroundColor DarkYellow
}






if ($Config.IncluiBackupFirebird -eq $true) {
    Write-Host "`n=== Iniciando procedimentos para backup de DB Firebird... AGUARDE... ===" -ForegroundColor Cyan
    
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
            Write-Host "[AVISO] Arquivo FDB não encontrado: $CaminhoFDB" -ForegroundColor DarkYellow
            continue
        }
        $NomeArquivoBase = [System.IO.Path]::GetFileNameWithoutExtension($CaminhoFDB)
        
        $NomeFbk = "$($NomeArquivoBase)_$DataHoraMili.fbk"
        $CaminhoFbk = Join-Path $PastaFbTemp $NomeFbk
        $CaminhoRarFbInd = Join-Path $PastaFbTemp "$($NomeArquivoBase)_$DataHoraMili.rar"

        Write-Host "[OK] Iniciando dump seguro (gbak) de: $NomeArquivoBase ...AGUARDE..." -ForegroundColor Cyan
        Start-Sleep -Seconds 2
        
        $StringConexao = "$($FbHost)/$($FbPort):$($CaminhoFDB)"
        $LogErroGbak = Join-Path $PastaFbTemp "gbak_$($NomeArquivoBase)_$DataHoraMili-err.log"
        $ArgumentosGbak = @(
            "-b", 
            "-g",
            "-v",
            "-user", "SYSDBA", 
            "-password", "masterkey", 
            "-se", "$($FbHost)/$($FbPort):service_mgr",
            $CaminhoFDB, 
            $CaminhoFbk,
            "-y", $LogErroGbak
        )
        $ProcGbak = Start-Process -FilePath $GbakExe -ArgumentList $ArgumentosGbak -NoNewWindow -Wait -PassThru
        Wait-ProcessWithSpinner -Process $ProcGbak -Mensagem "Realizando Backup (Dump .FBK) seguro do Banco de dados Firebird... AGUARDE..."
        #$ArgCompactar = @("a", "-ep1", "-hp$SenhaRarTexto", $CaminhoDestinoRar, $CaminhoOrigemSql)

        Start-Sleep -Seconds 2

        if ($ProcGbak.ExitCode -eq 0 -and (Test-Path $CaminhoFbk)) {
            Write-Host "[OK] Arquivo dump .fbk criado com sucesso!" -ForegroundColor Green
            Start-Sleep -Seconds 1
            Write-Host "[OK] Compactando arquivo .fbk gerado...AGUARDE..." -ForegroundColor Green
            
            $ArgsRarFb = @("a", "-m5", "-ep", "-y", "-idq", "`"$CaminhoRarFbInd`"", "`"$CaminhoFbk`"")
            $ProcRarFb = Start-Process -FilePath $Config.WinRarPath -ArgumentList $ArgsRarFb -NoNewWindow -Wait -PassThru

            Wait-ProcessWithSpinner -Process $ProcRarFb -Mensagem "Realizando compactação do .FBK Firebird unitário... AGUARDE..."
            
            if ($ProcRarFb.ExitCode -eq 0) {
                Write-Host "[OK] .FBK compactado com sucesso." -ForegroundColor Green
                Start-Sleep -Seconds 1
                $BancosFbComSucesso++
                Remove-Item -Path $CaminhoFbk -Force
            } else {
                Write-Host "[ERRO] Falha ao compactar $NomeArquivoBase" -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        } else {
            Write-Host "[ERRO] Falha crítica ao gerar o .fbk. Verifique se a porta $FbPort está correta e o serviço está acessível. Se usa servidor remoto dedicado para o Firebird, verifique se possui algum firewall bloqueando o acesso." -ForegroundColor Red
            Start-Sleep -Seconds 1
            exit 1
        }
    }

    if ($BancosFbComSucesso -gt 0) {
        Write-Host "[OK] Compactação individual dos FBKs Firebird concluída com SUCESSO! AGUARDE..." -ForegroundColor Green
        Start-Sleep -Seconds 1
        $NomeMasterFB = "MasterBackupFirebird_$($Config.Cliente)_$DataHoraMili.rar"
        $CaminhoMasterFB = Join-Path $Config.CaminhoDestinoTemp $NomeMasterFB
        
        Write-Host "`n[OK] Unindo $BancosFbComSucesso banco(s) Firebird no arquivo: $NomeMasterFB" -ForegroundColor Yellow

        $ArgsMasterFB = @("a", "-m5", "-ep", "-y", "-idq", "-hp$SenhaRarTexto", "`"$CaminhoMasterFB`"", "$PastaFbTemp\*.rar")
        $ProcMasterFB = Start-Process -FilePath $Config.WinRarPath -ArgumentList $ArgsMasterFB -NoNewWindow -PassThru
        Wait-ProcessWithSpinner -Process $ProcMasterFB -Mensagem "Compactação do arquivo único com todos os DBs... AGUARDE..."

        Start-Sleep -Seconds 1
        if ($ProcMasterFB.ExitCode -eq 0) {
            Write-Host "[OK] Pacote Master Firebird gerado com SUCESSO! AGUARDE..." -ForegroundColor Green
            Remove-Item -Path $PastaFbTemp -Recurse -Force
            
            Start-Sleep -Seconds 2

            Write-Host "`n[*] Preparação para envio ao servidor de Backup..." -ForegroundColor Cyan
            
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
                
                Write-Host "[*] Preparação concluída com sucesso. Iniciando envio..." -ForegroundColor Yellow
                $TempoIniUploadFB = Get-Date

                Write-Host "[*] Transferência em andamento... AGUARDE..." -ForegroundColor Yellow

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
                Write-Host "[OK] Upload do arquivo concluído em $(($TempoFimUploadFB - $TempoIniUploadFB).TotalSeconds) segundos!" -ForegroundColor Green
            } catch {
                throw "Erro ao fazer upload do Firebird."
            } finally {
                if ($BSTRWasabi) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTRWasabi); $SecretKeyWasabi = $null }
            }
            Start-Sleep -Seconds 2

            Write-Host "[OK] Registrando auditoria no banco de dados..." -ForegroundColor Yellow
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
            Write-Host "[OK] Log do Firebird gravado em formato binário!" -ForegroundColor Green
            
            Remove-Item -Path $CaminhoMasterFB -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "[ERROR] Nenhum banco Firebird foi validado/gerado para pacote." -ForegroundColor red
    }
}

$DataHora = Get-Date -Format "yyyyMMdd_HHmmss"
$NomeArquivoRar = "Backup_$($Config.Cliente)_$DataHora.rar"
$CaminhoCompletoRar = Join-Path $Config.CaminhoDestinoTemp $NomeArquivoRar
$ListFilePath = Join-Path $Config.CaminhoDestinoTemp "bkp_lista_$DataHora.txt"
$Config.CaminhosOrigem | ForEach-Object { "`"$_`"" } | Out-File -FilePath $ListFilePath -Encoding UTF8

$RarArgs = "a -m5 -md128 -rr5p -ep3 -y -idq `"-hp$SenhaRarTexto`" `"$CaminhoCompletoRar`" @`"$ListFilePath`""

Write-Host "[*] Iniciando compressão dos arquivos escolhidos...`nAGUARDE A CONCLUSÃO COMPLETA...." -ForegroundColor Yellow
Start-Sleep -Seconds 1
$TempoInicio = Get-Date

$Process = Start-Process -FilePath $Config.WinRarPath -ArgumentList $RarArgs -RedirectStandardOutput ".\logs\out_process_winrar_filesall_$DataHora.txt" -RedirectStandardError ".\logs\err_process_winrar_filesall_$DataHora.txt" -Wait -NoNewWindow -PassThru

Wait-ProcessWithSpinner -Process $Process -Mensagem "[*] Compactando arquivos do sistema... Isso pode demorar."

$TempoFim = Get-Date
$Duracao = $TempoFim - $TempoInicio

Remove-Item -Path $ListFilePath -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

if ($Process.ExitCode -eq 0) {
    Write-Host "[OK] Compressão concluída com SUCESSO!" -ForegroundColor Green
    Write-Host "[OK] Arquivo gerado: $CaminhoCompletoRar" -ForegroundColor Green
    Write-Host "[OK] Tempo de compressão: $($Duracao.Hours)h $($Duracao.Minutes)m $($Duracao.Seconds)s`n" -ForegroundColor Green
} elseif ($Process.ExitCode -eq 1) {
    Write-Host "[OK] Compressão concluída com AVISOS (Alguns arquivos podem estar em uso e foram pulados)." -ForegroundColor DarkYellow
    Write-Host "[OK] Arquivo gerado: $CaminhoCompletoRar`n" -ForegroundColor DarkYellow
} else {
    Write-Host "[ERROR] ERRO FATAL na compressao. Codigo de sai�da do WinRAR: $($Process.ExitCode)" -ForegroundColor Red
    exit 1
}
Start-Sleep -Seconds 1
Write-Host "[OK] Processo de compactacao finalizado com sucesso... AGUARDE..." -ForegroundColor Green
Start-Sleep -Seconds 3
$SenhaRarTexto = $null

Write-Host "[OK] Calculando Checksum (SHA256) do arquivo gerado..." -ForegroundColor Yellow

try {
    $Stream = [System.IO.File]::OpenRead($CaminhoCompletoRar)
    $SHA256 = [System.Security.Cryptography.SHA256]::Create()
    $HashBytes = $SHA256.ComputeHash($Stream)
    $ChecksumHex = [System.BitConverter]::ToString($HashBytes).Replace("-", "").ToLower()
    $ChecksumBase64 = [System.Convert]::ToBase64String($HashBytes)
    Write-Host "[OK] Checksum (Hex): $ChecksumHex" -ForegroundColor Green
    Start-Sleep -Seconds 3
    
} catch {
    throw "[ERROR] Falha ao calcular o Checksum do arquivo. Erro: $_"
} finally {
    if ($Stream) { $Stream.Dispose() }
    if ($SHA256) { $SHA256.Dispose() }
}

Write-Host "[OK] Preparando upload para servidor de backup... AGUARDE..." -ForegroundColor Cyan
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
Write-Host "[OK] Version Backup ID Gerado: $GuidVersao" -ForegroundColor Magenta

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
Write-Host "[OK] Log de auditoria gravado no banco de dados com SUCESSO!`n" -ForegroundColor Green
Start-Sleep -Seconds 1

if (Test-Path $CaminhoCompletoRar) {
    Remove-Item -Path $CaminhoCompletoRar -Force
    Write-Host "Limpeza: Arquivo local '$NomeArquivoRar' removido com sucesso...`n" -ForegroundColor DarkGray
    Write-Host "Limpeza: Artefatos na memória e chaves removidos com sucesso...`n" -ForegroundColor DarkGray
    Start-Sleep -Seconds 1
    Write-Host "Limpeza: Realizando checagem de dados finais...`n" -ForegroundColor DarkGray
    Start-Sleep -Seconds 2
}
Start-Sleep -Seconds 1
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "[OK] Rotina de Backup FINALIZADA COM SUCESSO!" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan